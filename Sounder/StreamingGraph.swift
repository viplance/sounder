import AVFoundation

struct StreamingEffect {
    let latency: Int
    let tail: Int
    let process: ([Float]) throws -> [Float]
}

final class SampleDelay {
    var storage: [Float]
    var position = 0
    init(frames: Int, channels: Int) { storage = Array(repeating: 0, count: frames * channels) }
    func reset() { for i in storage.indices { storage[i] = 0 }; position = 0 }
    func apply(_ input: [Float]) -> [Float] {
        guard !storage.isEmpty else { return input }
        var output = input
        for i in input.indices {
            output[i] = storage[position]; storage[position] = input[i]
            position += 1
            if position == storage.count { position = 0 }
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
        var peak = StereoLevels()
        var meterDelay: SampleDelay?
        let dry: [Float]
        let children: [Bus]
        let effects: [StreamingEffect]
        let channels: Int
        let latency: Int
        let tail: Int
        let dryDelay: SampleDelay
        let childDelays: [SampleDelay]
        var gains: [Double]
        var targetGains: [Double]
        var rampRemaining = 0
        let rampLength: Int
        func setMix(_ track: Track) {
            targetGains = (0..<channels).map { track.outputGain(channel: $0, channels: channels) }
            rampRemaining = rampLength
        }
        init(dry: [Float], children: [Bus], effects: [StreamingEffect], channels: Int, track: Track, sampleRate: Double) {
            self.muted = track.muted
            gains = (0..<channels).map { track.outputGain(channel: $0, channels: channels) }
            targetGains = gains; rampLength = max(1, Int(sampleRate * 0.010))
            self.dry = dry; self.children = children; self.effects = effects; self.channels = channels
            let childLatency = children.map(\.latency).max() ?? 0
            latency = childLatency + effects.reduce(0) { $0 + $1.latency }
            tail = (children.map(\.tail).max() ?? 0) + effects.reduce(0) { $0 + $1.tail }
            dryDelay = SampleDelay(frames: childLatency, channels: channels)
            childDelays = children.map { SampleDelay(frames: childLatency - $0.latency, channels: channels) }
        }
        func resetDelays() {
            dryDelay.reset(); childDelays.forEach { $0.reset() }; meterDelay?.reset()
            children.forEach { $0.resetDelays() }
        }
        var output: [Float] = []
        func render(position: Int, frames: Int, mode: RenderMode) throws -> [Float] {
            let sourceFadeRemaining = mode.fadeRemaining, sourceFadeLength = mode.fadeLength
            let sourceFadeInFrame = mode.fadeFrame
            var input = [Float](repeating: 0, count: frames * channels)
            let first = position * channels
            if mode.includesSource && soloDry && first < dry.count {
                let count = min(input.count, dry.count - first)
                input.replaceSubrange(0..<count, with: dry[first..<(first + count)])
            }
            if sourceFadeRemaining > 0 {
                for frame in 0..<frames {
                    let gain = Float(max(0, sourceFadeRemaining - frame)) / Float(max(1, sourceFadeLength))
                    for channel in 0..<channels { input[frame * channels + channel] *= gain }
                }
            }
            if let first = sourceFadeInFrame {
                for frame in 0..<frames {
                    let gain = Float(min(1, Double(first + frame) / Double(max(1, sourceFadeLength - 1))))
                    for channel in 0..<channels { input[frame * channels + channel] *= gain }
                }
            }
            if mode.includesSource { input = dryDelay.apply(input) }
            for (index, child) in children.enumerated() {
                let signal = mode.includesSource ? childDelays[index].apply(child.output) : child.output
                for i in input.indices { input[i] += signal[i] }
            }
            for effect in effects { input = try effect.process(input) }
            for frame in 0..<frames {
                for channel in 0..<channels {
                    if rampRemaining > 0 { gains[channel] += (targetGains[channel] - gains[channel]) / Double(rampRemaining) }
                    input[frame * channels + channel] *= Float(gains[channel])
                }
                if rampRemaining > 0 { rampRemaining -= 1 }
            }
            let output = muted || !soloBus ? [Float](repeating: 0, count: input.count) : input
            let metered = mode.includesSource ? (meterDelay?.apply(output) ?? output) : output
            peak = StereoLevels()
            for frame in 0..<frames {
                let l = metered[frame * channels], r = metered[frame * channels + (channels > 1 ? 1 : 0)]
                if l.isFinite { peak.left = max(peak.left, abs(l)) }
                if r.isFinite { peak.right = max(peak.right, abs(r)) }
            }
            return output
        }
    }
    private var buses: [UUID: Bus] = [:]
    private let tracks: [Track]
    private let renderPlan: AudioRenderPlan
    private let orderedBuses: [Bus]
    private let parents: [UUID: UUID]
    private(set) var trackPeaks: [UUID: StereoLevels] = [:]
    private let roots: [Bus]
    private let delays: [SampleDelay]
    let channels: Int
    let latency: Int
    let totalFrames: Int
    let outputCache: ProcessedMixCache
    var needsHistory: Bool { tracks.contains { $0.effects.contains { !$0.bypassed } } }
    private(set) var position = 0
    init(project: Project, store: AudioStore, dryGraph: StreamingGraph? = nil, processedCache: ProcessedMixCache? = nil, preparationProgress: (Int) -> Void = { _ in }, cancelled: () -> Bool = { false }, parallel: Bool = true, includeAudioSources: Bool = true, makeEffect: (PluginEffect) throws -> StreamingEffect) throws {
        let processingTracks = project.processingTracks
        tracks = processingTracks
        parents = Dictionary(uniqueKeysWithValues: processingTracks.compactMap { track in track.parent.map { (track.id, $0) } })
        channels = project.audioFormat.channels
        outputCache = try processedCache ?? ProcessedMixCache(channels: channels)
        let channelCount = channels
        // Source preparation has no graph dependencies. Give each track its own
        // store so mutable decode caches never cross worker boundaries.
        let sourceTracks = project.tracks
        for path in includeAudioSources ? Set(sourceTracks.flatMap(\.clips).filter { !$0.muted }.map(\.source)) : [] {
            if cancelled() { throw CancellationError() }
            if dryGraph == nil { _ = try store.load(path) }
        }
        let sources = store.cache
        let dryResults = sourceTracks.map { _ in AudioRenderResult<[Float]>([]) }
        let sourcePlan = try AudioRenderPlan(tracks: sourceTracks.map { track in
            var independent = track; independent.parent = nil; return independent
        }, parallel: parallel, minimumCost: 0.001)
        try sourcePlan.perform { index in
            guard includeAudioSources else { return }
            if cancelled() { throw CancellationError() }
            let track = sourcePlan.tracks[index]
            if let previous = dryGraph?.buses[track.id], previous.channels == channelCount {
                dryResults[index].value = previous.dry
                return
            }
            let local = try AudioStore(directory: store.directory)
            local.configure(project.audioFormat); local.cache = sources
            let raw = try local.renderAudio(project, onlyTrack: track.id, preparationProgress: preparationProgress, cancelled: cancelled)
            var samples = [Float](repeating: 0, count: raw.frameCount * channelCount)
            for frame in 0..<raw.frameCount {
                if frame % 4096 == 0 {
                    if cancelled() { throw CancellationError() }
                    if frame > 0 { preparationProgress(4096) }
                }
                for ch in 0..<channelCount { samples[frame * channelCount + ch] = raw.channels[ch][frame] }
            }
            if raw.frameCount > 0 { preparationProgress((raw.frameCount - 1) % 4096 + 1) }
            dryResults[index].value = samples
        }
        let dryByID = Dictionary(uniqueKeysWithValues: sourcePlan.tracks.enumerated().map { ($0.element.id, dryResults[$0.offset].value) })
        // A single FX path cannot run concurrently with itself. Avoid pool
        // handoffs altogether for the common one-track / one-chain project.
        let fxTracks = processingTracks.filter { $0.id != Project.masterID && $0.effects.contains { !$0.bypassed } }.count
        renderPlan = try AudioRenderPlan(tracks: processingTracks, parallel: parallel && (fxTracks > 1 || project.tracks.count >= 8))
        var prepared: [Bus] = []
        for (index, track) in renderPlan.tracks.enumerated() {
            if cancelled() { throw CancellationError() }
            let children = renderPlan.children[index].map { prepared[$0] }
            let effects = try track.effects.filter { !$0.bypassed }.map(makeEffect)
            prepared.append(Bus(dry: dryByID[track.id] ?? [], children: children, effects: effects, channels: channelCount, track: track, sampleRate: project.audioFormat.sampleRate))
        }
        orderedBuses = prepared
        roots = renderPlan.roots.map { prepared[$0] }
        buses = Dictionary(uniqueKeysWithValues: renderPlan.tracks.enumerated().map { ($0.element.id, prepared[$0.offset]) })
        latency = roots.map(\.latency).max() ?? 0
        if let processedCache, dryGraph?.latency != latency { processedCache.invalidate() }
        for bus in buses.values { bus.meterDelay = SampleDelay(frames: max(0, latency - bus.latency), channels: channelCount) }
        let masterLatency = latency
        delays = roots.map { SampleDelay(frames: masterLatency - $0.latency, channels: channelCount) }
        let end = project.tracks.flatMap(\.clips).map(\.end).max() ?? 0
        totalFrames = Int(end * project.audioFormat.sampleRate) + (roots.map(\.tail).max() ?? 0)
        setSolo(Set(project.tracks.filter(\.solo).map(\.id)))
    }
    // Call on the playback worker, alongside render, to preserve processor state.
    func setMuted(_ muted: Bool, trackID: UUID) { buses[trackID]?.muted = muted }
    func setTrackMix(_ track: Track) { buses[track.id]?.setMix(track); outputCache.invalidate() }
    func setSolo(_ ids: Set<UUID>) {
        let routing = TrackSoloRouting(tracks: tracks, soloIDs: ids)
        for (id, bus) in buses { bus.soloDry = routing.dry.contains(id); bus.soloBus = routing.buses.contains(id) }
    }
    // Seeking is a discontinuity in source time, not in the output clock.
    // Keep live processors (including their tails), but flush routing delays.
    // Only the declared latency needs pre-roll; never replay project history.
    func seek(to frame: Int, fadeInFrames: Int? = nil) throws {
        position = max(0, frame)
        clearRoutingDelays()
        let target = position + latency
        while position < target {
            let count = min(512, target - position)
            if let fadeInFrames {
                // Prime the returning source, including its fade, before its
                // first audible sample. Keep transient fade PCM out of cache.
                _ = try render(frames: count, mode: .fadeIn(frame: position - frame, length: fadeInFrames))
            } else { _ = try render(frames: count) }
        }
    }
    // Routing queues contain timeline PCM, not plug-in state. Clear them at
    // Stop/Pause so latency compensation cannot replay old dry audio later.
    func clearRoutingDelays() {
        roots.forEach { $0.resetDelays() }; delays.forEach { $0.reset() }
    }
    var hasEffects: Bool { needsHistory }
    /// Discard timeline samples retained inside processors as well as host PDC.
    /// Preserve processor instances/voices; silence never enters the mix cache.
    func drainTimelineLatency() throws {
        clearRoutingDelays()
        // Drain each processor independently. Rendering the entire graph here
        // would feed discarded lookahead into downstream reverbs and advance
        // unrelated tails by the slowest branch's latency.
        for bus in orderedBuses {
            for effect in bus.effects {
                var remaining = effect.latency
                while remaining > 0 {
                    let count = min(512, remaining)
                    _ = try effect.process([Float](repeating: 0, count: count * channels))
                    remaining -= count
                }
            }
        }
    }
    /// Explicit policy keeps idle voices out of PDC, timeline time and cache.
    enum RenderMode {
        case timeline
        case idleEffects
        case fadeOut(remaining: Int, length: Int)
        case fadeIn(frame: Int, length: Int)

        var includesSource: Bool { if case .idleEffects = self { return false }; return true }
        var cachesOutput: Bool { if case .timeline = self { return true }; return false }
        var fadeRemaining: Int { if case let .fadeOut(remaining, _) = self { return remaining }; return 0 }
        var fadeFrame: Int? { if case let .fadeIn(frame, _) = self { return frame }; return nil }
        var fadeLength: Int {
            switch self { case let .fadeOut(_, length), let .fadeIn(_, length): return length; default: return 1 }
        }
        func advance(frames: Int) -> Int {
            switch self {
            case .idleEffects: return 0
            case let .fadeOut(remaining, _): return min(frames, remaining)
            default: return frames
            }
        }
    }
    func renderEffects(frames: Int, sourceFadeRemaining: Int = 0, sourceFadeLength: Int = 1, sourceFadeInFrame: Int? = nil) throws -> [Float] {
        let mode: RenderMode
        if let first = sourceFadeInFrame { mode = .fadeIn(frame: first, length: sourceFadeLength) }
        else if sourceFadeRemaining > 0 { mode = .fadeOut(remaining: sourceFadeRemaining, length: sourceFadeLength) }
        else { mode = .idleEffects }
        return try render(frames: frames, mode: mode)
    }
    func render(frames: Int, mode: RenderMode = .timeline) throws -> [Float] {
        precondition(frames > 0 && frames <= PlaybackBufferSize.blockFrames)
        var mix = [Float](repeating: 0, count: frames * channels)
        try renderPlan.perform { index in
            let bus = orderedBuses[index]
            bus.output = try bus.render(position: position, frames: frames, mode: mode)
        }
        for (index, root) in roots.enumerated() {
            let output = mode.includesSource ? delays[index].apply(root.output) : root.output
            for i in mix.indices { mix[i] += output[i] }
        }
        for (id, bus) in buses {
            var ancestor: UUID? = id, audible = true
            while let current = ancestor {
                if let node = buses[current], node.muted || !node.soloBus { audible = false; break }
                ancestor = parents[current]
            }
            trackPeaks[id] = audible ? bus.peak : StereoLevels()
        }
        let first = position
        position += mode.advance(frames: frames)
        // Mutate the unique mix buffer instead of allocating a second array.
        for i in mix.indices { mix[i] = mix[i].isFinite ? min(1, max(-1, mix[i])) : 0 }
        if mode.cachesOutput { try outputCache.write(mix, at: first) }
        return mix
    }

}

