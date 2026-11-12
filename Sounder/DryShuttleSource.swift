import AVFoundation

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
        let regions = processed?.cachedRegions(in: (range.lowerBound + latency)..<(range.upperBound + latency)).map { ($0.lowerBound - latency)..<($0.upperBound - latency) } ?? []
        let fade = Int(rate * 0.010)
        let complete = processed?.cachedRegions(in: 0..<max(processed?.frames ?? 0, 1)) ?? []
        if let processed, let bounds = complete.first(where: {
            let first = max(cachedStart, $0.lowerBound - latency), last = $0.upperBound - latency
            let leftFade = first <= 0 ? 0 : (first == cachedStart && cachedStart > 0 ? 64 : fade)
            return range.lowerBound >= first + leftFade && range.upperBound <= last - (last >= frameCount ? 0 : fade)
        }), bounds.lowerBound <= range.lowerBound + latency {
            return try processed.read((range.lowerBound + latency)..<(range.upperBound + latency))
        }
        var output = [Float](repeating: 0, count: range.count * channels)
        let ancestors = Dictionary(uniqueKeysWithValues: project.tracks.map { ($0.id, $0) })
        for track in tracks {
            var gains = [Double](repeating: pow(10, project.masterVolumeDB / 20), count: channels), current: Track? = track
            if project.masterVolumeDB <= -60 { gains = Array(repeating: 0, count: channels) }
            while let node = current {
                for channel in 0..<channels { gains[channel] *= node.outputGain(channel: channel, channels: channels) }
                current = node.parent.flatMap { ancestors[$0] }
            }
            let signal = try store.renderAudio(project, onlyTrack: track.id, sourceFrames: range)
            for frame in 0..<min(signal.frameCount, range.count) {
                for ch in 0..<channels { output[frame * channels + ch] += signal.channels[ch][frame] * Float(gains[ch]) }
            }
        }
        if let processed {
            // Query full boundaries so overlapping read windows have identical blends.
            for region in regions {
                let wet = try processed.read((region.lowerBound + latency)..<(region.upperBound + latency))
                let bounds = complete.first { $0.lowerBound <= region.lowerBound + latency && $0.upperBound >= region.upperBound + latency }!
                let first = max(cachedStart, bounds.lowerBound - latency), last = bounds.upperBound - latency
                for frame in region where frame >= first {
                    let incoming = first <= 0 ? 1 : min(1, Double(frame - first) / Double(first == cachedStart && cachedStart > 0 ? 64 : fade))
                    let outgoing = last >= frameCount ? 1 : min(1, Double(last - frame) / Double(fade))
                    let blend = min(incoming, outgoing)
                    for ch in 0..<channels {
                        let i = (frame - range.lowerBound) * channels + ch
                        output[i] = Float(Double(wet[(frame - region.lowerBound) * channels + ch]) * blend + Double(output[i]) * (1 - blend))
                    }
                }
            }
        }
        return output.map { $0.isFinite ? min(1, max(-1, $0)) : 0 }
    }
}

