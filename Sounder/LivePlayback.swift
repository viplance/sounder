import AVFoundation

struct TrackLevelMeter {
    var level = 0.0
    var peak = 0.0
    private var peakTime = -Double.infinity
    private var updatedAt: Double?
    static func decibels(_ amplitude: Double) -> Double { amplitude > 0 ? 20 * log10(amplitude) : -.infinity }
    var fraction: Double { max(0, min(1, (Self.decibels(level) + 60) / 60)) }
    var peakText: String { peak > 0 ? String(format: "%.1f dB", Self.decibels(peak)) : "−∞ dB" }
    mutating func update(_ amplitude: Double, at time: Double) {
        let value = amplitude.isFinite ? max(0, amplitude) : 0
        let elapsed = max(0, time - (updatedAt ?? time))
        level = max(value, level * pow(10, -24 * elapsed / 20))
        if level < 0.001 { level = 0 }
        if value >= peak || time - peakTime >= 1 { peak = value; peakTime = time }
        updatedAt = time
    }
}

// Small snapshots follow scheduled audio time, rather than exposing render-ahead
// peaks early. The UI only takes a short lock, never waits on the audio worker.
final class PlaybackMeterBuffer {
    private let lock = NSLock()
    private var pending: [(frame: Int, peaks: [UUID: Float])] = []
    func append(frame: Int, peaks: [UUID: Float]) {
        lock.lock(); defer { lock.unlock() }
        pending.append((frame, peaks))
        if pending.count > 512 { pending.removeFirst(pending.count - 512) }
    }
    func consume(through frame: Int) -> [UUID: Float] {
        lock.lock(); defer { lock.unlock() }
        var result: [UUID: Float] = [:], count = 0
        for item in pending {
            guard item.frame <= frame else { break }
            for (id, peak) in item.peaks { result[id] = max(result[id] ?? 0, peak) }
            count += 1
        }
        pending.removeFirst(count)
        return result
    }
}

struct StreamingEffect {
    let latency: Int
    let tail: Int
    let process: ([Float]) throws -> [Float]
}

private final class SampleDelay {
    var storage: [Float]
    var position = 0
    init(frames: Int, channels: Int) { storage = Array(repeating: 0, count: frames * channels) }
    func apply(_ input: [Float]) -> [Float] {
        guard !storage.isEmpty else { return input }
        var output = input
        for i in input.indices {
            output[i] = storage[position]; storage[position] = input[i]
            position = (position + 1) % storage.count
        }
        return output
    }
}

/// Runs on the playback worker. Each parent processes its children exactly once.
final class StreamingGraph {
    private final class Bus {
        var muted: Bool
        var soloDry = true
        var soloBus = true
        var peak: Float = 0
        var meterDelay: SampleDelay?
        let dry: [Float]
        let children: [Bus]
        let effects: [StreamingEffect]
        let channels: Int
        let latency: Int
        let tail: Int
        let dryDelay: SampleDelay
        let childDelays: [SampleDelay]
        init(dry: [Float], children: [Bus], effects: [StreamingEffect], channels: Int, muted: Bool) {
            self.muted = muted
            self.dry = dry; self.children = children; self.effects = effects; self.channels = channels
            let childLatency = children.map(\.latency).max() ?? 0
            latency = childLatency + effects.reduce(0) { $0 + $1.latency }
            tail = (children.map(\.tail).max() ?? 0) + effects.reduce(0) { $0 + $1.tail }
            dryDelay = SampleDelay(frames: childLatency, channels: channels)
            childDelays = children.map { SampleDelay(frames: childLatency - $0.latency, channels: channels) }
        }
        func render(position: Int, frames: Int) throws -> [Float] {
            var input = [Float](repeating: 0, count: frames * channels)
            let first = position * channels
            if soloDry && first < dry.count {
                let count = min(input.count, dry.count - first)
                input.replaceSubrange(0..<count, with: dry[first..<(first + count)])
            }
            input = dryDelay.apply(input)
            for (index, child) in children.enumerated() {
                let signal = childDelays[index].apply(try child.render(position: position, frames: frames))
                for i in input.indices { input[i] += signal[i] }
            }
            for effect in effects { input = try effect.process(input) }
            let output = muted || !soloBus ? [Float](repeating: 0, count: input.count) : input
            let metered = meterDelay?.apply(output) ?? output
            peak = metered.reduce(Float(0)) { $1.isFinite ? max($0, abs($1)) : $0 }
            return output
        }
    }
    private var buses: [UUID: Bus] = [:]
    private let tracks: [Track]
    private let parents: [UUID: UUID]
    private(set) var trackPeaks: [UUID: Float] = [:]
    private let roots: [Bus]
    private let delays: [SampleDelay]
    let channels: Int
    let latency: Int
    let totalFrames: Int
    private(set) var position = 0
    init(project: Project, store: AudioStore, makeEffect: (PluginEffect) throws -> StreamingEffect) throws {
        tracks = project.tracks
        parents = Dictionary(uniqueKeysWithValues: project.tracks.compactMap { track in track.parent.map { (track.id, $0) } })
        channels = project.audioFormat.channels
        let channelCount = channels
        var visited = Set<UUID>()
        var trackBuses: [UUID: Bus] = [:]
        func bus(_ track: Track) throws -> Bus {
            guard visited.insert(track.id).inserted else { throw SounderError.message("Invalid track hierarchy") }
            let raw = try store.renderAudio(project, onlyTrack: track.id)
            var dry = [Float](repeating: 0, count: raw.frameCount * channelCount)
            for frame in 0..<raw.frameCount { for ch in 0..<channelCount { dry[frame * channelCount + ch] = raw.channels[ch][frame] } }
            let children = try project.tracks.filter { $0.parent == track.id }.map { try bus($0) }
            let effects = try track.effects.filter { !$0.bypassed }.map(makeEffect)
            let result = Bus(dry: dry, children: children, effects: effects, channels: channelCount, muted: track.muted)
            trackBuses[track.id] = result
            return result
        }
        roots = try project.tracks.filter { $0.parent == nil }.map { try bus($0) }
        buses = trackBuses
        latency = roots.map(\.latency).max() ?? 0
        for bus in buses.values { bus.meterDelay = SampleDelay(frames: max(0, latency - bus.latency), channels: channelCount) }
        let masterLatency = latency
        delays = roots.map { SampleDelay(frames: masterLatency - $0.latency, channels: channelCount) }
        let end = project.tracks.flatMap(\.clips).map(\.end).max() ?? 0
        totalFrames = Int(end * project.audioFormat.sampleRate) + (roots.map(\.tail).max() ?? 0)
        setSolo(Set(project.tracks.filter(\.solo).map(\.id)))
    }
    // Call on the playback worker, alongside render, to preserve processor state.
    func setMuted(_ muted: Bool, trackID: UUID) { buses[trackID]?.muted = muted }
    func setSolo(_ ids: Set<UUID>) {
        let routing = TrackSoloRouting(tracks: tracks, soloIDs: ids)
        for (id, bus) in buses { bus.soloDry = routing.dry.contains(id); bus.soloBus = routing.buses.contains(id) }
    }
    func render(frames: Int) throws -> [Float] {
        precondition(frames > 0 && frames <= 512)
        var mix = [Float](repeating: 0, count: frames * channels)
        for (index, root) in roots.enumerated() {
            let output = delays[index].apply(try root.render(position: position, frames: frames))
            for i in mix.indices { mix[i] += output[i] }
        }
        for (id, bus) in buses {
            var ancestor: UUID? = id, audible = true
            while let current = ancestor {
                if let node = buses[current], node.muted || !node.soloBus { audible = false; break }
                ancestor = parents[current]
            }
            trackPeaks[id] = audible ? bus.peak : 0
        }
        position += frames
        return mix.map { $0.isFinite ? min(1, max(-1, $0)) : 0 }
    }
}

/// Keep a short render-ahead queue, replenished when buffers are consumed.
/// Device presentation callbacks are reserved for the final buffer: they arrive
/// too late to drive a continuous stream on outputs with presentation latency.
final class LivePlayback {
    let engine = AVAudioEngine()
    let node = AVAudioPlayerNode()
    let graph: StreamingGraph
    let format: ProjectAudioFormat
    let queue = DispatchQueue(label: "Sounder.playback", qos: .userInteractive)
    private let meterBuffer = PlaybackMeterBuffer()
    private var running = false
    private var scheduled = 0
    private var tempo = 120.0
    private var metronomeEnabled = false
    private var nextFrame: Int
    let start: Double
    var finished: ((Error?) -> Void)?
    private let firstFrame: Int
    private var lastKnownFrame = 0
    var isPlaying: Bool { node.isPlaying && engine.isRunning }
    var renderedFrames: Int { queue.sync { graph.position } }
    var currentTime: Double {
        if let time = node.lastRenderTime, time.isSampleTimeValid || time.isHostTimeValid,
           let played = node.playerTime(forNodeTime: time),
           played.isSampleTimeValid, played.sampleRate > 0 {
            let frames = Int((Double(played.sampleTime) * format.sampleRate / played.sampleRate).rounded())
            lastKnownFrame = max(lastKnownFrame, frames)
        }
        // A temporarily unavailable render timestamp must not move the UI backwards.
        return Double(min(graph.totalFrames, firstFrame + lastKnownFrame)) / format.sampleRate
    }
    init(graph: StreamingGraph, format: ProjectAudioFormat, start: Double) {
        self.graph = graph; self.format = format
        firstFrame = max(0, Int((start * format.sampleRate).rounded()))
        self.start = Double(firstFrame) / format.sampleRate; nextFrame = firstFrame
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: AVAudioChannelCount(format.channels))!)
    }
    func startPlayback() throws {
        let pcmFormat = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: AVAudioChannelCount(format.channels))!
        // Warm effects from project zero and discard compensated latency when seeking.
        try queue.sync {
            let skip = nextFrame + graph.latency
            while graph.position < skip { _ = try graph.render(frames: min(512, skip - graph.position)) }
            running = true
            for _ in 0..<8 { try enqueue(format: pcmFormat) }
        }
        engine.prepare(); try engine.start(); node.play()
    }
    private func enqueue(format pcmFormat: AVAudioFormat) throws {
        guard running else { return }
        let frames = min(512, graph.totalFrames - nextFrame)
        guard frames > 0 else {
            if scheduled == 0 { running = false; DispatchQueue.main.async { [weak self] in self?.finished?(nil) } }
            return
        }
        let samples = try graph.render(frames: frames)
        let buffer = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        let scale: Float = format.bitDepth == 16 ? 32768 : 8388608
        for frame in 0..<frames { for channel in 0..<format.channels {
            let click = metronomeEnabled ? MetronomeClick.sample(frame: Int64(nextFrame + frame), sampleRate: format.sampleRate, bpm: tempo) : 0
            let value = min(1, max(-1, samples[frame * format.channels + channel] + click))
            buffer.floatChannelData![channel][frame] = format.bitDepth == 32 ? value : min(scale - 1, (value * scale).rounded()) / scale
        } }
        meterBuffer.append(frame: nextFrame + frames, peaks: graph.trackPeaks)
        nextFrame += frames; scheduled += 1
        let isLast = nextFrame == graph.totalFrames
        let completionType: AVAudioPlayerNodeCompletionCallbackType = isLast
            ? (engine.isInManualRenderingMode ? .dataRendered : .dataPlayedBack)
            : .dataConsumed
        node.scheduleBuffer(buffer, completionCallbackType: completionType) { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                guard self.running else { return }
                self.scheduled -= 1
                do { try self.enqueue(format: pcmFormat) }
                catch { self.running = false; DispatchQueue.main.async { self.finished?(error) } }
            }
        }
    }
    func consumeTrackPeaks(at time: Double) -> [UUID: Float] {
        meterBuffer.consume(through: Int(time * format.sampleRate))
    }
    func setMetronome(tempo: Double, enabled: Bool) {
        queue.async { self.tempo = tempo; self.metronomeEnabled = enabled }
    }
    func setMuted(_ muted: Bool, trackID: UUID) {
        queue.async { self.graph.setMuted(muted, trackID: trackID) }
    }
    func setSolo(_ ids: Set<UUID>) { queue.async { self.graph.setSolo(ids) } }
    func stop() { queue.sync { running = false }; node.stop(); engine.stop() }
    deinit { engine.stop() }
}

func runStreamingGraphTests() throws {
    func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw SounderError.message(message) }; print("PASS: \(message)")
    }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SounderStreaming-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try AudioStore(directory: directory)
    let url = store.freshURL()
    let signal = AudioSignal(channels: [Array(repeating: Float(0.2), count: 2048), Array(repeating: Float(0.1), count: 2048)])
    try store.write(signal, to: url)
    let clip = Clip(name: "Source", source: url.path, start: 0, duration: 2048 / sampleRate, order: 1)
    let effect = PluginEffect(name: "Gain", path: "test", classID: "gain")
    let parent = Track(name: "Parent", clips: [clip], effects: [effect])
    let child = Track(name: "Child", parent: parent.id, clips: [clip], effects: [effect])
    let sibling = Track(name: "Sibling", clips: [clip])
    var gain: Float = 0.5
    let graph = try StreamingGraph(project: Project(tracks: [parent, child, sibling]), store: store) { _ in
        StreamingEffect(latency: 0, tail: 0) { $0.map { $0 * gain } }
    }
    let first = try graph.render(frames: 512)
    try check(abs(first[1000] - 0.35) < 0.000001 && abs(first[1001] - 0.175) < 0.000001, "Streaming graph applies child and parent effects once, with independent stereo and sibling tracks")
    try check(abs((graph.trackPeaks[parent.id] ?? 0) - 0.15) < 1e-6 && abs((graph.trackPeaks[child.id] ?? 0) - 0.1) < 1e-6 && abs((graph.trackPeaks[sibling.id] ?? 0) - 0.2) < 1e-6, "Per-track meters measure post-effect stereo peaks including child-to-parent routing")
    gain = 0.25
    let next = try graph.render(frames: 512)
    try check(abs(next[0] - 0.2625) < 0.000001, "Changing a live parameter changes the very next block without rebuilding the mix")
    graph.setMuted(true, trackID: parent.id)
    try check(abs(try graph.render(frames: 128)[0] - 0.2) < 0.000001, "Live parent mute silences its subtree while siblings keep playing")
    try check(graph.trackPeaks[parent.id] == 0 && graph.trackPeaks[child.id] == 0 && graph.trackPeaks[sibling.id] == 0.2, "Parent mute suppresses both its own and descendant meters while sibling meters remain live")
    graph.setMuted(false, trackID: parent.id); graph.setMuted(true, trackID: child.id)
    try check(abs(try graph.render(frames: 128)[0] - 0.25) < 0.000001, "Live child mute preserves its parent and siblings")
    graph.setMuted(false, trackID: child.id)
    try check(abs(try graph.render(frames: 128)[0] - 0.2625) < 0.000001, "Live unmute restores routed audio without rebuilding the graph")
    let delayedGraph = try StreamingGraph(project: Project(tracks: [parent, child, sibling]), store: store) { _ in
        let delay = SampleDelay(frames: 37, channels: 2)
        return StreamingEffect(latency: 37, tail: 0) { delay.apply($0) }
    }
    let delayed = try delayedGraph.render(frames: 512)
    let delayedInterior = try delayedGraph.render(frames: 512)
    try check(delayedGraph.latency == 74 && delayed.prefix(148).allSatisfy { $0 == 0 } && abs(delayedInterior[84] - 0.6) < 0.000001, "Streaming latency compensation aligns dry, child and root buses")
    var mutedParent = parent; mutedParent.muted = true
    let muted = try StreamingGraph(project: Project(tracks: [mutedParent, child]), store: store) { _ in
        StreamingEffect(latency: 0, tail: 0) { $0 }
    }
    try check(try muted.render(frames: 512).allSatisfy { $0 == 0 }, "Streaming mute silences the entire subtree")
    muted.setMuted(false, trackID: parent.id)
    try check(abs(try muted.render(frames: 32)[0] - 0.4) < 0.000001, "A track muted before Play can be unmuted in the same stream")
    var newerSilence = clip; newerSilence.id = UUID(); newerSilence.order = 2; newerSilence.source = store.freshURL().path
    try store.write(AudioSignal(channels: [[Float](repeating: 0, count: 2048), [Float](repeating: 0, count: 2048)]), to: URL(fileURLWithPath: newerSilence.source))
    let overlap = try StreamingGraph(project: Project(tracks: [Track(name: "Overlap", clips: [clip, newerSilence])]), store: store) { _ in fatalError() }
    _ = try overlap.render(frames: 512)
    try check(try overlap.render(frames: 128).allSatisfy { $0 == 0 }, "Streaming playback preserves newer silent takes after their edge crossfade")
}
