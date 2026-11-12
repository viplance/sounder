import AVFoundation

/// Value state owned by the transport's short clock lock. Both ordinary
/// playback and shuttle map monotonic output frames through these segments.
struct PlaybackClock {
    var renderedFrames = 0
    private(set) var playedFrames = 0
    var segments: [(frame: Int, motion: ShuttleMotion)] = []

    mutating func observe(_ frame: Int?) {
        if let frame { playedFrames = max(playedFrames, min(renderedFrames, frame)) }
    }
    func position(at frame: Int, sampleRate: Double, fallback: Double) -> Double {
        guard let segment = segments.last(where: { $0.frame <= frame }) else { return fallback }
        return segment.motion.position(at: Double(frame - segment.frame) / sampleRate)
    }
    func speed(sampleRate: Double) -> Double {
        guard let segment = segments.last(where: { $0.frame <= playedFrames }) else { return 1 }
        return segment.motion.speed(at: Double(playedFrames - segment.frame) / sampleRate)
    }
    mutating func retainHistory(frames: Int) {
        if let index = segments.lastIndex(where: { $0.frame <= playedFrames - frames }), index > 0 {
            segments.removeFirst(index)
        }
    }
    mutating func reset() { self = PlaybackClock() }

    static func playerFrame(node: AVAudioPlayerNode, sampleRate: Double, rounding: FloatingPointRoundingRule = .toNearestOrAwayFromZero) -> Int? {
        guard let stamp = node.lastRenderTime, stamp.isSampleTimeValid || stamp.isHostTimeValid,
              let played = node.playerTime(forNodeTime: stamp), played.isSampleTimeValid, played.sampleRate > 0 else { return nil }
        return Int((Double(played.sampleTime) * sampleRate / played.sampleRate).rounded(rounding))
    }
}
