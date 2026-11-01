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
    func clear() { lock.lock(); pending.removeAll(); lock.unlock() }
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

// Retaining processed PCM lets shuttle reuse effects without running processors
// in reverse. A short I/O lock also covers overlapping cancelled/new shuttles.
final class ProcessedMixCache {
    let url: URL
    private let file: FileHandle
    private let lock = NSLock()
    let channels: Int
    private(set) var frames = 0
    init(channels: Int) throws {
        self.channels = channels
        url = FileManager.default.temporaryDirectory.appendingPathComponent("Sounder-mix-" + UUID().uuidString + ".pcm")
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw SounderError.message("Cannot create playback cache") }
        do {
            file = try FileHandle(forUpdating: url)
            // The open handle retains the data, but a crash or forced quit can
            // never leave a full-length temporary recording on disk.
            try FileManager.default.removeItem(at: url)
        }
        catch { try? FileManager.default.removeItem(at: url); throw error }
    }
    func append(_ samples: [Float]) throws {
        lock.lock(); defer { lock.unlock() }
        try file.seekToEnd()
        try samples.withUnsafeBytes { try file.write(contentsOf: $0) }
        frames += samples.count / channels
    }
    func read(_ range: Range<Int>) throws -> [Float] {
        lock.lock(); defer { lock.unlock() }
        guard !range.isEmpty else { return [] }
        precondition(range.lowerBound >= 0 && range.upperBound <= frames)
        try file.seek(toOffset: UInt64(range.lowerBound * channels * MemoryLayout<Float>.size))
        let count = range.count * channels * MemoryLayout<Float>.size
        var data = Data()
        while data.count < count {
            guard let next = try file.read(upToCount: count - data.count), !next.isEmpty else { throw SounderError.message("Incomplete playback cache") }
            data.append(next)
        }
        return data.withUnsafeBytes { bytes in
            (0..<(range.count * channels)).map { bytes.loadUnaligned(fromByteOffset: $0 * MemoryLayout<Float>.size, as: Float.self) }
        }
    }
    deinit { try? file.close(); try? FileManager.default.removeItem(at: url) }
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
    let outputCache: ProcessedMixCache
    private(set) var position = 0
    init(project: Project, store: AudioStore, dryGraph: StreamingGraph? = nil, makeEffect: (PluginEffect) throws -> StreamingEffect) throws {
        tracks = project.tracks
        parents = Dictionary(uniqueKeysWithValues: project.tracks.compactMap { track in track.parent.map { (track.id, $0) } })
        channels = project.audioFormat.channels
        outputCache = try ProcessedMixCache(channels: channels)
        let channelCount = channels
        var visited = Set<UUID>()
        var trackBuses: [UUID: Bus] = [:]
        func bus(_ track: Track) throws -> Bus {
            guard visited.insert(track.id).inserted else { throw SounderError.message("Invalid track hierarchy") }
            let dry: [Float]
            if let previous = dryGraph?.buses[track.id], previous.channels == channelCount {
                dry = previous.dry // Immutable PCM is shared; no full-project remix on release.
            } else {
                let raw = try store.renderAudio(project, onlyTrack: track.id)
                var samples = [Float](repeating: 0, count: raw.frameCount * channelCount)
                for frame in 0..<raw.frameCount { for ch in 0..<channelCount { samples[frame * channelCount + ch] = raw.channels[ch][frame] } }
                dry = samples
            }
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
        let output = mix.map { $0.isFinite ? min(1, max(-1, $0)) : 0 }
        try outputCache.append(output)
        return output
    }
}

/// Keep a short render-ahead queue, replenished when buffers are consumed.
/// Device presentation callbacks are reserved for the final buffer: they arrive
/// too late to drive a continuous stream on outputs with presentation latency.
final class LivePlayback {
    let engine = AVAudioEngine()
    let node = AVAudioPlayerNode()
    private(set) var graph: StreamingGraph
    let format: ProjectAudioFormat
    let queue = DispatchQueue(label: "Sounder.playback", qos: .userInteractive)
    private let meterBuffer = PlaybackMeterBuffer()
    private var running = false
    private var scheduled = 0
    private var tempo = 120.0
    private var metronomeEnabled = false
    private var nextFrame: Int
    private var outputFrames = 0
    private var shuttleRenderer: ShuttlePlayback?
    private var renderingNormal = true
    private var metronomeFadeStart = 0
    private let returnQueue = DispatchQueue(label: "Sounder.return-to-play", qos: .userInitiated)
    private let returnLock = NSLock()
    private var returnToken: UUID?
    private(set) var returnReady = false
    var restored: ((StreamingGraph) -> Void)?
    var snapshotGraph: StreamingGraph { queue.sync { graph } }
    private func cancelReturn() { returnLock.lock(); returnToken = nil; returnLock.unlock() }
    private func isCurrentReturn(_ token: UUID) -> Bool { returnLock.lock(); defer { returnLock.unlock() }; return returnToken == token }
    func completeReturn() { isShuttling = false; returnReady = false; cancelReturn() }
    private let transportLock = NSLock()
    private var transportMotions: [(frame: Int, motion: ShuttleMotion)] = []
    private(set) var isShuttling = false
    private(set) var shuttleUsesProcessedCache = false
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
        // Output time stays monotonic; source time may reverse smoothly.
        transportLock.lock(); defer { transportLock.unlock() }
        if let segment = transportMotions.last(where: { $0.frame <= lastKnownFrame }) {
            return segment.motion.position(at: Double(lastKnownFrame - segment.frame) / format.sampleRate)
        }
        return Double(min(graph.totalFrames, firstFrame + lastKnownFrame)) / format.sampleRate
    }
    var currentSpeed: Double {
        _ = currentTime
        transportLock.lock(); defer { transportLock.unlock() }
        guard let segment = transportMotions.last(where: { $0.frame <= lastKnownFrame }) else { return 1 }
        return segment.motion.speed(at: Double(lastKnownFrame - segment.frame) / format.sampleRate)
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
    func beginShuttle(source: DryShuttleSource, direction: Double) {
        cancelReturn(); returnReady = false
        isShuttling = true; shuttleUsesProcessedCache = source.processed != nil
        queue.async {
            guard self.running else { return }
            do {
                let position = self.shuttleRenderer?.renderedPosition ?? Double(self.nextFrame) / self.format.sampleRate
                let speed = self.shuttleRenderer?.renderedSpeed ?? 1
                // Keep a short wet continuation beyond the queued normal audio,
                // then fade to dry if the remaining mix has not been processed.
                if self.renderingNormal {
                    let needed = Int(position * self.format.sampleRate) + self.graph.latency + 512
                    while self.graph.position < needed { _ = try self.graph.render(frames: min(512, needed - self.graph.position)) }
                }
                self.renderingNormal = false; self.meterBuffer.clear()
                let entry = DryShuttleSource(project: source.project, store: source.store, processed: source.processed ?? self.graph.outputCache, latency: source.processed == nil ? self.graph.latency : source.latency, cachedStart: source.processed == nil ? max(0, Int(position * self.format.sampleRate) - 64) : source.cachedStart, frameCount: max(source.frameCount, self.graph.totalFrames))
                let renderer = ShuttlePlayback(source: entry, start: position, direction: direction, initialSpeed: speed)
                self.shuttleRenderer = renderer
                self.transportLock.lock(); self.transportMotions.append((self.outputFrames, renderer.motion)); self.transportLock.unlock()
            } catch { self.running = false; DispatchQueue.main.async { self.finished?(error) } }
        }
    }
    func releaseShuttle(makeGraph: @escaping (@escaping () -> Bool) throws -> StreamingGraph) {
        cancelReturn(); returnReady = false
        let token = UUID()
        returnLock.lock(); returnToken = token; returnLock.unlock()
        queue.async {
            guard self.running, let renderer = self.shuttleRenderer else { return }
            renderer.retarget(1)
            self.transportLock.lock(); self.transportMotions.append((self.outputFrames, renderer.motion)); self.transportLock.unlock()
            self.returnQueue.async {
                do {
                    let cancelled = { !self.isCurrentReturn(token) }
                    guard !cancelled() else { return }
                    let graph = try makeGraph(cancelled)
                    while !cancelled() {
                        let target: Int? = self.queue.sync {
                            guard self.running, self.isCurrentReturn(token), self.shuttleRenderer === renderer else { return nil }
                            return renderer.hasSettled ? Int(renderer.renderedPosition * self.format.sampleRate) + graph.latency : -1
                        }
                        guard let target else { return }
                        if target < 0 { Thread.sleep(forTimeInterval: 0.005); continue }
                        while graph.position < max(0, target - 512) {
                            if cancelled() { return }
                            _ = try graph.render(frames: min(512, max(0, target - 512) - graph.position))
                        }
                        let installed: Bool = try self.queue.sync {
                            guard self.running, self.isCurrentReturn(token), self.shuttleRenderer === renderer else { return true }
                            let frame = Int(renderer.renderedPosition * self.format.sampleRate)
                            let needed = frame + graph.latency
                            guard needed - graph.position <= 1024 else { return false }
                            while graph.position < needed { _ = try graph.render(frames: min(512, needed - graph.position)) }
                            let source = DryShuttleSource(project: renderer.source.project, store: renderer.source.store, processed: graph.outputCache, latency: graph.latency, frameCount: graph.totalFrames, liveGraph: graph)
                            self.graph = graph; renderer.replaceSource(source)
                            self.renderingNormal = true; self.metronomeFadeStart = self.outputFrames; self.meterBuffer.clear()
                            DispatchQueue.main.async {
                                guard self.isCurrentReturn(token) else { return }
                                self.returnReady = true; self.restored?(graph)
                            }
                            return true
                        }
                        if installed { return }
                    }
                } catch {
                    guard self.isCurrentReturn(token) else { return }
                    DispatchQueue.main.async { if self.isCurrentReturn(token) { self.finished?(error) } }
                }
            }
        }
    }
    private func enqueue(format pcmFormat: AVAudioFormat) throws {
        guard running else { return }
        if let renderer = shuttleRenderer {
            guard let buffer = try renderer.render(frames: 512) else {
                if scheduled == 0 { running = false; DispatchQueue.main.async { [weak self] in self?.finished?(nil) } }
                return
            }
            if renderingNormal {
                let first = renderer.renderedPosition - Double(buffer.frameLength) / format.sampleRate
                let scale: Float = format.bitDepth == 16 ? 32768 : 8388608
                for i in 0..<Int(buffer.frameLength) {
                    let fade = min(1, Double(outputFrames + i - metronomeFadeStart) / (0.010 * format.sampleRate))
                    let click = metronomeEnabled ? MetronomeClick.sample(frame: Int64(first * format.sampleRate) + Int64(i), sampleRate: format.sampleRate, bpm: tempo) * Float(fade) : 0
                    for ch in 0..<format.channels {
                        let value = min(1, max(-1, buffer.floatChannelData![ch][i] + click))
                        buffer.floatChannelData![ch][i] = format.bitDepth == 32 ? value : min(scale - 1, (value * scale).rounded()) / scale
                    }
                }
                meterBuffer.append(frame: Int(renderer.renderedPosition * format.sampleRate), peaks: graph.trackPeaks)
            }
            outputFrames += Int(buffer.frameLength); scheduled += 1
            schedule(buffer, last: renderer.reachedEnd, format: pcmFormat)
            return
        }
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
        nextFrame += frames; outputFrames += frames; scheduled += 1
        schedule(buffer, last: nextFrame == graph.totalFrames, format: pcmFormat)
    }
    private func schedule(_ buffer: AVAudioPCMBuffer, last: Bool, format pcmFormat: AVAudioFormat) {
        let completionType: AVAudioPlayerNodeCompletionCallbackType = last
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
    func stop() {
        cancelReturn(); queue.sync { running = false }
        node.stop(); engine.stop()
        // Releasing hands processors to this worker. Drain a cancelled block
        // before another Play can begin using those same plug-in instances.
        returnQueue.sync {}
    }
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

/// Audio-clock-based shuttle: both audible sampling and the cursor use this
/// same integral, independent of keyboard repeat settings and UI timer jitter.
struct ShuttleMotion {
    static let maximumRate = 8.0
    static let releaseDuration = 0.5
    let start: Double
    let direction: Double
    let end: Double
    var initialSpeed = 0.0
    var target: Double? = nil
    var targetSpeed: Double { target ?? direction * Self.maximumRate }
    var settlingDuration: Double { rampTime }
    func settled(at time: Double) -> Bool { time >= rampTime }
    private var isRelease: Bool { target == 0 || target == 1 }
    private var acceleration: Double {
        isRelease ? abs(targetSpeed - initialSpeed) / (Self.releaseDuration * Self.releaseDuration) : 4
    }
    private var rampTime: Double {
        guard targetSpeed != initialSpeed else { return 0 }
        return isRelease ? Self.releaseDuration : sqrt(abs(targetSpeed - initialSpeed) / acceleration)
    }
    func speed(at time: Double) -> Double {
        let sign = targetSpeed >= initialSpeed ? 1.0 : -1.0
        if time >= rampTime { return targetSpeed }
        let t = max(0, time)
        return initialSpeed + sign * acceleration * t * t
    }
    func distance(at time: Double) -> Double {
        let t = max(0, time), a = min(t, rampTime)
        let sign = targetSpeed >= initialSpeed ? 1.0 : -1.0
        return initialSpeed * a + sign * acceleration * a * a * a / 3 + targetSpeed * max(0, t - rampTime)
    }
    func position(at time: Double) -> Double {
        if initialSpeed * targetSpeed < 0 {
            let turn = sqrt(abs(initialSpeed) / acceleration)
            if time >= turn {
                let pivot = min(end, max(0, start + distance(at: turn)))
                return min(end, max(0, pivot + distance(at: time) - distance(at: turn)))
            }
        }
        return min(end, max(0, start + distance(at: time)))
    }
    func reachedBoundary(at time: Double) -> Bool {
        if targetSpeed == 0 && settled(at: time) { return true }
        return direction < 0 ? position(at: time) <= 0 : position(at: time) >= end
    }
}

// A private source/cache snapshot avoids decoding on the UI thread. Read only
// the small window needed by the next output block; never instantiate plug-ins
// or prepare a full-project mix just to move the cursor.
final class DryShuttleSource {
    let project: Project
    let store: AudioStore
    let frameCount: Int
    private let tracks: [Track]
    let processed: ProcessedMixCache?
    let latency: Int
    let cachedStart: Int
    let liveGraph: StreamingGraph?
    init(project: Project, store: AudioStore, processed: ProcessedMixCache? = nil, latency: Int = 0, cachedStart: Int = 0, frameCount: Int? = nil, liveGraph: StreamingGraph? = nil) {
        self.project = project; self.store = store; self.processed = processed; self.latency = latency; self.cachedStart = cachedStart; self.liveGraph = liveGraph
        self.frameCount = max(frameCount ?? 0, Int((project.tracks.flatMap(\.clips).map(\.end).max() ?? 0) * project.audioFormat.sampleRate))
        let routing = TrackSoloRouting(tracks: project.tracks)
        let parents = Dictionary(uniqueKeysWithValues: project.tracks.map { ($0.id, $0) })
        tracks = project.tracks.filter { track in
            guard routing.dry.contains(track.id) else { return false }
            var ancestor: Track? = track
            var visited = Set<UUID>()
            while let current = ancestor {
                if current.muted || !visited.insert(current.id).inserted { return false }
                ancestor = current.parent.flatMap { parents[$0] }
            }
            return true
        }
    }
    func read(_ range: Range<Int>) throws -> [Float] {
        let channels = project.audioFormat.channels, rate = project.audioFormat.sampleRate
        if let graph = liveGraph {
            let upper = range.upperBound + graph.latency
            while graph.position < upper { _ = try graph.render(frames: min(512, upper - graph.position)) }
            return try graph.outputCache.read((range.lowerBound + graph.latency)..<upper)
        }
        let cachedEnd = min(frameCount, max(0, (processed?.frames ?? latency) - latency))
        let fade = cachedEnd == frameCount ? 0 : Int(rate * 0.010)
        if range.lowerBound >= cachedStart + (cachedStart > 0 ? 64 : 0), range.upperBound <= cachedEnd - fade, let processed { return try processed.read((range.lowerBound + latency)..<(range.upperBound + latency)) }
        var output = [Float](repeating: 0, count: range.count * channels)
        for track in tracks {
            let signal = try store.renderAudio(project, onlyTrack: track.id, sourceFrames: range)
            for frame in 0..<min(signal.frameCount, range.count) {
                for ch in 0..<channels { output[frame * channels + ch] += signal.channels[ch][frame] }
            }
        }
        if let processed, max(range.lowerBound, cachedStart) < min(range.upperBound, cachedEnd) {
            let first = max(range.lowerBound, cachedStart), last = min(range.upperBound, cachedEnd)
            let wet = try processed.read((first + latency)..<(last + latency))
            for frame in first..<last {
                let incoming = cachedStart == 0 ? 1 : min(1, Double(frame - cachedStart) / 64)
                let blend = min(incoming, fade == 0 ? 1 : min(1, Double(cachedEnd - frame) / Double(fade)))
                for ch in 0..<channels {
                    let i = (frame - range.lowerBound) * channels + ch
                    output[i] = Float(Double(wet[(frame - first) * channels + ch]) * blend + Double(output[i]) * (1 - blend))
                }
            }
        }
        return output.map { $0.isFinite ? min(1, max(-1, $0)) : 0 }
    }
}

final class ShuttlePlayback {
    let engine = AVAudioEngine()
    let node = AVAudioPlayerNode()
    let queue = DispatchQueue(label: "Sounder.shuttle", qos: .userInteractive)
    private(set) var source: DryShuttleSource
    private var previousSource: DryShuttleSource?
    private var sourceChangeFrame = 0
    let format: ProjectAudioFormat
    private(set) var motion: ShuttleMotion
    private var motionStartFrame = 0
    private let motionLock = NSLock()
    private var motions: [(frame: Int, motion: ShuttleMotion)] = []
    private var requestedRevision = 0
    private var activeRevision = 0
    private var started = false
    var renderedPosition: Double { motion.position(at: Double(outputFrame - motionStartFrame) / format.sampleRate) }
    var renderedSpeed: Double { motion.speed(at: Double(outputFrame - motionStartFrame) / format.sampleRate) }
    var hasSettled: Bool { motion.settled(at: Double(outputFrame - motionStartFrame) / format.sampleRate) }
    var reachedEnd: Bool { terminal || motion.reachedBoundary(at: Double(outputFrame - motionStartFrame) / format.sampleRate) }
    var finished: ((Error?) -> Void)?
    private let cancellation = NSLock()
    private var cancelled = false
    private var outputFrame = 0
    private var playedFrames = 0
    private var scheduled = 0
    private var terminal = false
    var isPlaying: Bool { node.isPlaying && engine.isRunning }
    private var isCancelled: Bool { cancellation.lock(); defer { cancellation.unlock() }; return cancelled }
    var currentTime: Double {
        if let time = node.lastRenderTime, let played = node.playerTime(forNodeTime: time), played.isSampleTimeValid, played.sampleRate > 0 {
            playedFrames = max(playedFrames, Int(Double(played.sampleTime) * format.sampleRate / played.sampleRate))
        }
        motionLock.lock(); defer { motionLock.unlock() }
        let segment = motions.last(where: { $0.frame <= playedFrames }) ?? motions[0]
        return segment.motion.position(at: Double(playedFrames - segment.frame) / format.sampleRate)
    }
    init(source: DryShuttleSource, start: Double, direction: Double, initialSpeed: Double = 0) {
        self.source = source; self.format = source.project.audioFormat
        let format = source.project.audioFormat
        motion = ShuttleMotion(start: start, direction: direction < 0 ? -1 : 1, end: Double(source.frameCount) / format.sampleRate, initialSpeed: initialSpeed)
        motions = [(0, motion)]
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: AVAudioChannelCount(format.channels))!)
    }
    // Called only on the worker. Used by the audio device and offline tests.
    func render(frames requested: Int) throws -> AVAudioPCMBuffer? {
        guard !isCancelled, !terminal else { return nil }
        let rate = format.sampleRate
        var positions: [Double] = []
        let timeAtStart = Double(outputFrame - motionStartFrame) / rate
        let steady = motion.settled(at: timeAtStart) && motion.targetSpeed == 1
        let firstPosition = motion.position(at: timeAtStart) * rate
        for i in 0..<requested {
            let time = Double(outputFrame + i - motionStartFrame) / rate
            if motion.reachedBoundary(at: time) { terminal = true; break }
            positions.append(steady ? firstPosition + Double(i) : motion.position(at: time) * rate)
        }
        guard let minimum = positions.min(), let maximum = positions.max() else { return nil }
        // Windowed-sinc interpolation also low-pass filters accelerated audio.
        let radius = 32
        let phase = firstPosition - floor(firstPosition)
        let kernel: [Double]? = steady ? ((-radius + 1)...radius).map { offset in
            let delta = phase - Double(offset), x = Double.pi * delta
            return (abs(x) < 1e-10 ? 1 : sin(x) / x) * (0.5 + 0.5 * cos(Double.pi * delta / Double(radius)))
        } : nil
        let lower = max(0, Int(minimum.rounded(.down)) - radius)
        let upper = min(source.frameCount, Int(maximum.rounded(.down)) + radius + 2)
        let samples = try source.read(lower..<upper)
        let fadeFrames = max(1, Int(rate * 0.010))
        if outputFrame - sourceChangeFrame >= fadeFrames { previousSource = nil }
        let previous = try previousSource?.read(lower..<upper)
        guard !isCancelled else { return nil }
        let pcm = AVAudioFormat(standardFormatWithSampleRate: rate, channels: AVAudioChannelCount(format.channels))!
        let buffer = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: AVAudioFrameCount(positions.count))!
        buffer.frameLength = AVAudioFrameCount(positions.count)
        for (index, position) in positions.enumerated() {
            let center = Int(position.rounded(.down))
            let time = Double(outputFrame + index - motionStartFrame) / rate
            let velocity = motion.speed(at: time)
            let cutoff = 1 / max(1, abs(velocity))
            var sums = [Double](repeating: 0, count: format.channels), weightSum = 0.0
            for frame in max(lower, center - radius + 1)..<min(upper, center + radius + 1) {
                let delta = position - Double(frame)
                let weight: Double
                if let kernel { weight = kernel[frame - center + radius - 1] }
                else {
                    let x = Double.pi * delta * cutoff
                    let sinc = abs(x) < 1e-10 ? 1 : sin(x) / x
                    weight = cutoff * sinc * (0.5 + 0.5 * cos(Double.pi * delta / Double(radius)))
                }
                weightSum += weight
                let blend = previous == nil ? 1 : min(1, Double(outputFrame + index - sourceChangeFrame) / Double(fadeFrames))
                for ch in 0..<format.channels {
                    let i = (frame - lower) * format.channels + ch
                    let value = Double(samples[i]) * blend + Double(previous?[i] ?? 0) * (1 - blend)
                    sums[ch] += value * weight
                }
            }
            let edgeDistance = velocity < 0 ? motion.position(at: time) : motion.end - motion.position(at: time)
            let onset = abs(motion.initialSpeed) < 0.01 ? min(1, time / 0.005) : 1
            let stopFade = motion.targetSpeed == 0 ? min(1, max(0, (motion.settlingDuration - time) / 0.005)) : 1
            let envelope = min(onset, abs(velocity) / 0.02, edgeDistance / (0.005 * max(0.02, abs(velocity)))) * stopFade
            let scale = format.bitDepth == 16 ? 32768.0 : 8388608.0
            for ch in 0..<format.channels {
                let value = min(1, max(-1, sums[ch] / max(1e-9, weightSum))) * envelope
                buffer.floatChannelData![ch][index] = Float(format.bitDepth == 32 || source.liveGraph != nil ? value : min(scale - 1, (value * scale).rounded()) / scale)
            }
        }
        outputFrame += positions.count
        return buffer
    }
    // Worker-only: re-anchor at the next unscheduled sample, preserving phase
    // and signed velocity across key release or a change of direction.
    func retarget(_ target: Double, revision: Int? = nil) {
        let direction = target == 0 ? (renderedSpeed < 0 ? -1.0 : 1.0) : (target < 0 ? -1.0 : 1.0)
        let next = ShuttleMotion(start: renderedPosition, direction: direction, end: motion.end, initialSpeed: renderedSpeed, target: target)
        motion = next; motionStartFrame = outputFrame; terminal = false
        motionLock.lock()
        if let revision { activeRevision = revision } else { requestedRevision += 1; activeRevision = requestedRevision }
        motions.append((outputFrame, next)); motionLock.unlock()
    }
    func replaceSource(_ source: DryShuttleSource) {
        previousSource = self.source; self.source = source; sourceChangeFrame = outputFrame
    }
    private func requestTarget(_ target: Double) {
        motionLock.lock(); requestedRevision += 1; let revision = requestedRevision; motionLock.unlock()
        queue.async {
            guard !self.isCancelled else { return }
            self.retarget(target, revision: revision)
            if self.started && self.scheduled == 0 {
                do { try self.enqueue() } catch { self.report(error) }
            }
        }
    }
    func changeDirection(_ direction: Double) { requestTarget(direction < 0 ? -8 : 8) }
    func release() { requestTarget(0) }
    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            do {
                self.started = true
                for _ in 0..<8 { try self.enqueue() }
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.isCancelled else { return }
                    do { self.engine.prepare(); try self.engine.start(); self.node.play() }
                    catch { self.finished?(error) }
                }
            } catch { self.report(error) }
        }
    }
    private func enqueue() throws {
        guard !isCancelled else { return }
        guard let buffer = try render(frames: 512) else {
            if scheduled == 0 { report(nil) }
            return
        }
        scheduled += 1
        let last = reachedEnd
        let completion: AVAudioPlayerNodeCompletionCallbackType = last ? (engine.isInManualRenderingMode ? .dataRendered : .dataPlayedBack) : .dataConsumed
        node.scheduleBuffer(buffer, completionCallbackType: completion) { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                guard !self.isCancelled else { return }
                self.scheduled -= 1
                do { try self.enqueue() } catch { self.report(error) }
            }
        }
    }
    private func report(_ error: Error?) {
        let revision = activeRevision
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isCancelled else { return }
            self.motionLock.lock(); let current = self.requestedRevision; self.motionLock.unlock()
            guard error != nil || current == revision else { return }
            self.finished?(error)
        }
    }
    func stop() {
        cancellation.lock(); cancelled = true; cancellation.unlock()
        node.stop(); engine.stop()
        // Each gesture owns its source snapshot and no plug-ins. Cancellation
        // must not wait on a decoder or disk I/O on the main thread.
    }
    deinit { engine.stop() }
}
