import AVFoundation

/// A click derived from absolute timeline frames, independent of timer jitter.
enum MetronomeClick {
    static func sample(frame: Int64, sampleRate: Double, bpm: Double) -> Float {
        let beatPosition = Double(frame) * bpm / (60 * sampleRate)
        let beat = floor(beatPosition)
        let time = (beatPosition - beat) * 60 / bpm
        guard time >= 0 && time < 0.035 else { return 0 }
        let accent = Int64(beat) % 4 == 0
        let frequency = accent ? 1760.0 : 1320.0
        let envelope = min(1, time / 0.001) * exp(-time * 140) * (1 - time / 0.035)
        return Float(sin(time * 2 * .pi * frequency) * envelope * (accent ? 0.4 : 0.25))
    }
}

/// Recording monitor: this source connects to the output mixer, never the input tap.
final class MetronomeVoice {
    let sampleRate: Double
    private let lock = NSLock()
    private var bpm = 120.0
    private var enabled = false
    private var startFrame: Int64 = 0
    private var renderedFrames: Int64 = 0 // Accessed only by the audio render callback.
    init(sampleRate: Double) { self.sampleRate = sampleRate }
    func configure(bpm: Double, enabled: Bool, start: Double? = nil) {
        lock.lock(); defer { lock.unlock() }
        self.bpm = bpm; self.enabled = enabled
        if let start { startFrame = Int64((start * sampleRate).rounded()) }
    }
    func render(frames: AVAudioFrameCount, buffers: UnsafeMutablePointer<AudioBufferList>) {
        lock.lock(); let bpm = self.bpm, enabled = self.enabled, first = startFrame; lock.unlock()
        let output = UnsafeMutableAudioBufferListPointer(buffers)
        for frame in 0..<Int(frames) {
            let sample: Float = enabled ? MetronomeClick.sample(frame: first + renderedFrames + Int64(frame), sampleRate: sampleRate, bpm: bpm) : 0
            for buffer in output {
                guard let data = buffer.mData else { continue }
                data.assumingMemoryBound(to: Float.self)[frame] = sample
            }
        }
        renderedFrames += Int64(frames)
    }
    func source(format: AVAudioFormat) -> AVAudioSourceNode {
        AVAudioSourceNode(format: format) { [self] isSilence, _, frames, buffers in
            render(frames: frames, buffers: buffers); isSilence.pointee = false; return noErr
        }
    }
}

struct TempoTick {
    let time: Double
    let label: String
    let isBar: Bool
}
enum TempoGrid {
    static func ticks(from start: Double, to end: Double, zoom: Double, bpm: Double) -> [TempoTick] {
        guard end >= start, zoom > 0 else { return [] }
        let beat = 60 / bpm, bar = beat * 4
        let barStep = max(1, pow(2, ceil(log2(80 / (bar * zoom)))))
        let step = barStep == 1 && beat * zoom >= 20 ? beat : bar * barStep
        let first = max(0, floor(start / step) * step)
        return stride(from: first, through: end, by: step).map { time in
            let index = Int((time / beat).rounded())
            let isBar = index % 4 == 0
            let title = isBar || beat * zoom >= 65 ? "\(index / 4 + 1).\(index % 4 + 1)" : ""
            return TempoTick(time: time, label: title, isBar: isBar)
        }
    }
}
