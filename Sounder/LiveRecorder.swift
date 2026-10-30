import Foundation
import AVFoundation

struct RecordingUpdate {
    let channelPeaks: [[Float]]
    let partialChannelPeaks: [Float?]
    var peaks: [Float] {
        (0..<(channelPeaks.first?.count ?? 0)).map { i in channelPeaks.reduce(Float(0)) { max($0, $1[i]) } }
    }
    var partialPeak: Float? { partialChannelPeaks.compactMap { $0 }.max() }
    let frames: Int
    let failure: Error?
}

/// Serializes disk writes and streaming conversion. The UI only drains newly
/// calculated peaks; it never re-reads an unfinished WAV or copies its history.
final class RecordingWriter {
    private let queue = DispatchQueue(label: "Sounder.recording.writer", qos: .userInitiated)
    private let gate = NSLock()
    private let publication = NSLock()
    private var accepting = true
    private let sourceFormat: AVAudioFormat
    private let converter: AVAudioConverter
    private let pull: AVAudioPCMBuffer
    private let output: AVAudioPCMBuffer
    private var file: AVAudioFile?
    private var failure: Error?
    private var frames = 0
    private var partialPeaks: [Float]
    private var partialFrames = 0
    private var pendingPeaks: [[Float]]
    private var publishedPartial: [Float?]
    private var publishedFrames = 0
    private var publishedFailure: Error?

    init(url: URL, format: ProjectAudioFormat, inputFormat: AVAudioFormat) throws {
        try format.validate()
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
              inputFormat.commonFormat == .pcmFormatFloat32, !inputFormat.isInterleaved else {
            throw SounderError.message("The audio input has no supported PCM format. Check the input device in System Settings → Sound.")
        }
        sourceFormat = inputFormat
        partialPeaks = Array(repeating: 0, count: format.channels)
        pendingPeaks = Array(repeating: [], count: format.channels)
        publishedPartial = Array(repeating: nil, count: format.channels)
        let target = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: AVAudioChannelCount(format.channels))!
        guard let converter = AVAudioConverter(from: inputFormat, to: target),
              let pull = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: 4096),
              let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 4096) else {
            throw SounderError.message("Cannot configure recording conversion")
        }
        self.converter = converter; self.pull = pull; self.output = output
        converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        converter.primeMethod = .normal
        if inputFormat.channelCount == 1 && format.channels == 2 { converter.channelMap = [0, 0] }
        else if inputFormat.channelCount > format.channels { converter.downmix = true }
        file = try AVAudioFile(forWriting: url, settings: format.recordingSettings, commonFormat: .pcmFormatFloat32, interleaved: false)
    }
    func append(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0 else { return }
        // Audio taps may reuse their buffers after the callback returns.
        guard buffer.format == sourceFormat, let source = buffer.floatChannelData,
              let copy = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: buffer.frameLength),
              let destination = copy.floatChannelData else {
            enqueueFailure(SounderError.message("Audio input format changed during recording")); return
        }
        copy.frameLength = buffer.frameLength
        for channel in 0..<Int(sourceFormat.channelCount) {
            destination[channel].update(from: source[channel], count: Int(buffer.frameLength))
        }
        // Enqueue under the same gate used by finish, so Stop cannot overtake an
        // accepted buffer, including when a tap callback is already in flight.
        gate.lock(); defer { gate.unlock() }
        guard accepting else { return }
        queue.async { [self] in
            guard failure == nil else { return }
            do { try convert(copy, ending: false) }
            catch { fail(error) }
        }
    }
    private func enqueueFailure(_ error: Error) {
        gate.lock(); defer { gate.unlock() }
        guard accepting else { return }
        queue.async { [self] in fail(error) }
    }
    private func fail(_ error: Error) {
        if failure == nil { failure = error }
        publication.lock(); publishedFailure = failure; publication.unlock()
    }
    private func convert(_ input: AVAudioPCMBuffer?, ending: Bool) throws {
        var offset: AVAudioFrameCount = 0
        while true {
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { [self] requested, status in
                guard let input, offset < input.frameLength else {
                    status.pointee = ending ? .endOfStream : .noDataNow; return nil
                }
                let count = min(pull.frameCapacity, max(1, requested), input.frameLength - offset)
                pull.frameLength = count
                for channel in 0..<Int(sourceFormat.channelCount) {
                    pull.floatChannelData![channel].update(from: input.floatChannelData![channel].advanced(by: Int(offset)), count: Int(count))
                }
                offset += count; status.pointee = .haveData; return pull
            }
            if let error { throw error }
            if status == .error { throw SounderError.message("Recording conversion failed") }
            if output.frameLength > 0 {
                try file?.write(from: output)
                publish(output)
            }
            if status == .endOfStream || status == .inputRanDry { return }
            if output.frameLength == 0 { throw SounderError.message("Recording converter stopped producing audio") }
        }
    }
    private func publish(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData else { return }
        var completed = [[Float]](repeating: [], count: partialPeaks.count)
        for frame in 0..<Int(buffer.frameLength) {
            for channel in 0..<Int(buffer.format.channelCount) {
                partialPeaks[channel] = max(partialPeaks[channel], abs(channels[channel][frame]))
            }
            partialFrames += 1
            if partialFrames == 128 {
                for channel in partialPeaks.indices { completed[channel].append(partialPeaks[channel]); partialPeaks[channel] = 0 }
                partialFrames = 0
            }
        }
        frames += Int(buffer.frameLength)
        publication.lock()
        for channel in completed.indices { pendingPeaks[channel].append(contentsOf: completed[channel]) }
        publishedPartial = partialPeaks.map { partialFrames > 0 ? $0 : nil }
        publishedFrames = frames
        publication.unlock()
    }
    func consumeUpdate() -> RecordingUpdate {
        publication.lock(); defer { publication.unlock() }
        let result = RecordingUpdate(channelPeaks: pendingPeaks, partialChannelPeaks: publishedPartial, frames: publishedFrames, failure: publishedFailure)
        pendingPeaks = Array(repeating: [], count: pendingPeaks.count); return result
    }
    /// Used by deterministic stream tests; normal recording never blocks the UI
    /// waiting for individual buffers. Stop drains all accepted buffers once.
    func waitForPendingWrites() { queue.sync {} }
    @discardableResult func finish() -> Error? {
        gate.lock(); accepting = false; gate.unlock()
        return queue.sync {
            guard file != nil else { return failure }
            if failure == nil {
                do { try convert(nil, ending: true) } catch { fail(error) }
            }
            file = nil // Finalize the WAV header before the editor reads it.
            return failure
        }
    }
}

final class LiveRecorder {
    let url: URL
    let format: ProjectAudioFormat
    let writer: RecordingWriter
    let metronome: MetronomeVoice
    private var engine: AVAudioEngine?
    private var stopped = false
    private var started = false
    private var lastFailure: Error?
    /// Supplying an input format creates a stream-only session for automated
    /// tests; microphone sessions always take the actual device's PCM format.
    init(url: URL, format: ProjectAudioFormat, inputFormat: AVAudioFormat? = nil) throws {
        self.url = url; self.format = format
        metronome = MetronomeVoice(sampleRate: format.sampleRate)
        if let inputFormat { writer = try RecordingWriter(url: url, format: format, inputFormat: inputFormat) }
        else {
            let engine = AVAudioEngine()
            writer = try RecordingWriter(url: url, format: format, inputFormat: engine.inputNode.outputFormat(forBus: 0))
            let outputFormat = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: AVAudioChannelCount(format.channels))!
            let source = metronome.source(format: outputFormat)
            engine.attach(source); engine.connect(source, to: engine.mainMixerNode, format: outputFormat)
            self.engine = engine
        }
    }
    func start() throws {
        guard !started, !stopped else { return }
        if let engine {
            let input = engine.inputNode
            input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { [weak self] buffer, _ in self?.writer.append(buffer) }
            started = true
            do { engine.prepare(); try engine.start() }
            catch { _ = stop(); throw error }
        } else { started = true }
    }
    @discardableResult func stop() -> Error? {
        guard !stopped else { return lastFailure }
        stopped = true
        if let engine, started { engine.inputNode.removeTap(onBus: 0); engine.stop() }
        lastFailure = writer.finish(); engine = nil
        return lastFailure
    }
    deinit { _ = stop() }
}
