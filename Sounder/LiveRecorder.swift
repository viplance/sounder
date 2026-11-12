import Foundation
import AVFoundation

struct LoopRecordingUpdate {
    let startFrame: Int
    let cursorFrame: Int
    let frameCount: Int
    let resetWaveform: Bool
    let peakPatches: [Int: [Float]]
}

/// Sparse PCM pages are overwritten at their timeline positions. Completed
/// passes never accumulate, and an unfinished pass retains the preceding tail.
private final class LoopRecordingBuffer {
    let bounds: Range<Int>
    let initialStart: Int
    let channels: Int
    private let pageFrames = 4096
    private var pages: [Int: [[Float]]] = [:]
    private(set) var position: Int
    private var wrapped = false
    private let canWrap: Bool
    private let fadeFrames: Int
    private var replaced: [[Float]]
    private var dirty = Set<Int>()
    private var reset = false
    var start: Int { wrapped ? min(initialStart, bounds.lowerBound) : initialStart }
    var count: Int { wrapped ? bounds.upperBound - start : position - initialStart }
    var allocatedFrames: Int { pages.count * pageFrames }
    init(bounds: Range<Int>, start: Int, channels: Int, sampleRate: Double) {
        self.bounds = bounds; initialStart = start; position = start; self.channels = channels; canWrap = start <= bounds.upperBound
        fadeFrames = max(1, min(Int((sampleRate * 0.01).rounded()), bounds.count / 2))
        replaced = Array(repeating: Array(repeating: 0, count: fadeFrames), count: channels)
    }
    private var trailingFade: Range<Int> {
        guard wrapped, position > bounds.lowerBound else { return position..<position }
        return max(bounds.lowerBound, position - fadeFrames)..<position
    }
    private func mark(_ range: Range<Int>) {
        guard !range.isEmpty else { return }
        for index in max(0, (range.lowerBound - start) / 128)...max(0, (range.upperBound - 1 - start) / 128) { dirty.insert(index) }
    }
    func append(_ buffer: AVAudioPCMBuffer) {
        // Recompute the old moving seam too: once capture advances, those
        // samples become fully replaced instead of fading into the old tail.
        mark(trailingFade)
        var offset = 0
        while offset < Int(buffer.frameLength) {
            if canWrap && position == bounds.upperBound { wrap() }
            let page = position / pageFrames, local = position % pageFrames
            let n = min(Int(buffer.frameLength) - offset, pageFrames - local, canWrap ? bounds.upperBound - position : Int.max)
            if pages[page] == nil { pages[page] = Array(repeating: Array(repeating: 0, count: pageFrames), count: channels) }
            for channel in 0..<channels {
                pages[page]![channel].withUnsafeMutableBufferPointer { destination in
                    let input = buffer.floatChannelData![channel].advanced(by: offset)
                    if wrapped {
                        for i in 0..<n {
                            let frame = position + i, old = destination[local + i]
                            replaced[channel][frame % fadeFrames] = old
                            let gain = Float(min(1, Double(frame - bounds.lowerBound) / Double(max(1, fadeFrames - 1))))
                            destination[local + i] = old * (1 - gain) + input[i] * gain
                        }
                    } else { destination.baseAddress!.advanced(by: local).update(from: input, count: n) }
                }
            }
            mark(position..<(position + n)); position += n; offset += n
            if canWrap && position == bounds.upperBound { wrap() }
        }
        mark(trailingFade)
    }
    private func wrap() {
        if !wrapped {
            let oldStart = start
            wrapped = true
            if start != oldStart {
                reset = true; dirty.removeAll()
                for page in pages.keys {
                    mark(max(start, page * pageFrames)..<min(bounds.upperBound, (page + 1) * pageFrames))
                }
            }
        }
        position = bounds.lowerBound
    }
    func sample(channel: Int, frame: Int) -> Float {
        let value = pages[frame / pageFrames]?[channel][frame % pageFrames] ?? 0
        let seam = trailingFade
        guard seam.contains(frame) else { return value }
        let gain = Float(position - 1 - frame) / Float(max(1, seam.count - 1))
        return value * gain + replaced[channel][frame % fadeFrames] * (1 - gain)
    }
    func copy(to output: AVAudioPCMBuffer, offset: Int, count: Int) {
        var copied = 0
        while copied < count {
            let frame = start + offset + copied, local = frame % pageFrames
            let n = min(count - copied, pageFrames - local)
            let page = pages[frame / pageFrames]
            for channel in 0..<channels {
                let destination = output.floatChannelData![channel].advanced(by: copied)
                if let page {
                    page[channel].withUnsafeBufferPointer { destination.update(from: $0.baseAddress!.advanced(by: local), count: n) }
                } else { destination.initialize(repeating: 0, count: n) }
            }
            copied += n
        }
        let seam = trailingFade.clamped(to: (start + offset)..<(start + offset + count))
        for frame in seam { for channel in 0..<channels { output.floatChannelData![channel][frame - start - offset] = sample(channel: channel, frame: frame) } }
    }
    func takeUpdate() -> LoopRecordingUpdate {
        var patches: [Int: [Float]] = [:]
        for index in dirty where index * 128 < count {
            var peaks = [Float](repeating: 0, count: channels)
            let first = start + index * 128, last = min(start + count, first + 128)
            for frame in first..<last { for channel in 0..<channels { peaks[channel] = max(peaks[channel], abs(sample(channel: channel, frame: frame))) } }
            patches[index] = peaks
        }
        let update = LoopRecordingUpdate(startFrame: start, cursorFrame: position, frameCount: count, resetWaveform: reset, peakPatches: patches)
        dirty.removeAll(); reset = false
        return update
    }
}

/// Shared DAC presentation instant of the recording trigger. Input writers
/// compare hardware sample timestamps against it, never callback arrival time.
final class RecordingHostClock {
    private let lock = NSLock()
    private var reference: Double?
    func set(hostTime: UInt64) {
        lock.lock(); reference = AVAudioTime.seconds(forHostTime: hostTime); lock.unlock()
    }
    func inputFrameOffset(hostTime: UInt64, latency: Double, sampleRate: Double) -> Int? {
        lock.lock(); let anchor = reference; lock.unlock()
        guard let anchor else { return nil }
        let seconds = AVAudioTime.seconds(forHostTime: hostTime) - max(0, latency) - anchor
        guard seconds.isFinite, abs(seconds * sampleRate) < Double(Int.max / 4) else { return nil }
        return Int((seconds * sampleRate).rounded())
    }
}

struct RecordingUpdate {
    let channelPeaks: [[Float]]
    let partialChannelPeaks: [Float?]
    var peaks: [Float] {
        (0..<(channelPeaks.first?.count ?? 0)).map { i in channelPeaks.reduce(Float(0)) { max($0, $1[i]) } }
    }
    var partialPeak: Float? { partialChannelPeaks.compactMap { $0 }.max() }
    let frames: Int
    let failure: Error?
    let loop: LoopRecordingUpdate?
}

/// Serializes disk writes and streaming conversion. The UI only drains newly
/// calculated peaks; it never re-reads an unfinished WAV or copies its history.
final class RecordingWriter {
    private let queue = DispatchQueue(label: "Sounder.recording.writer", qos: .userInitiated)
    private let gate = NSLock()
    private let publication = NSLock()
    private var accepting = true
    private let captureFormat: AVAudioFormat
    private let inputChannels: [Int]
    private let sourceFormat: AVAudioFormat
    private let converter: AVAudioConverter
    private let pull: AVAudioPCMBuffer
    private let output: AVAudioPCMBuffer
    private var file: AVAudioFile?
    private let url: URL
    let format: ProjectAudioFormat
    private var finished = false
    private var loopBuffer: LoopRecordingBuffer?
    private(set) var isLoopRecording = false
    private var publishedLoop: LoopRecordingUpdate?
    private var loopPatches: [Int: [Float]] = [:]
    private var loopReset = false
    private var failure: Error?
    private var frames = 0
    private var partialPeaks: [Float]
    private var partialFrames = 0
    private var pendingPeaks: [[Float]]
    private var publishedPartial: [Float?]
    private var publishedFrames = 0
    private var publishedFailure: Error?

    private var alignment: (clock: RecordingHostClock, latency: Double)?
    private var nextPacketFrame: Int?
    // Position in the input sample rate, before conversion or loop replacement.
    // Hardware timestamps place every packet; callback delivery is not a clock.
    private var nextInputFrame = 0
    func configureSynchronization(clock: RecordingHostClock, inputLatency: Double) {
        queue.sync { alignment = (clock, inputLatency) }
    }
    init(url: URL, format: ProjectAudioFormat, inputFormat: AVAudioFormat, inputChannels: [Int]? = nil) throws {
        try format.validate()
        self.url = url
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
              inputFormat.commonFormat == .pcmFormatFloat32, !inputFormat.isInterleaved else {
            throw SounderError.message("The audio input has no supported PCM format. Check the input device in System Settings → Sound.")
        }
        let selected = inputChannels ?? Array(0..<min(2, Int(inputFormat.channelCount)))
        guard !selected.isEmpty, selected.count <= 2, Set(selected).count == selected.count,
              selected.allSatisfy({ $0 >= 0 && $0 < Int(inputFormat.channelCount) }) else { throw SounderError.message("Invalid recording channels") }
        // Preserve a mono source in its take file; project channel expansion
        // belongs to playback/mixing, not capture. Rate and depth stay shared.
        var format = format
        format.channels = min(format.channels, selected.count)
        self.format = format
        captureFormat = inputFormat; self.inputChannels = selected
        sourceFormat = AVAudioFormat(standardFormatWithSampleRate: inputFormat.sampleRate, channels: AVAudioChannelCount(selected.count))!
        partialPeaks = Array(repeating: 0, count: format.channels)
        pendingPeaks = Array(repeating: [], count: format.channels)
        publishedPartial = Array(repeating: nil, count: format.channels)
        let target = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: AVAudioChannelCount(format.channels))!
        guard let converter = AVAudioConverter(from: sourceFormat, to: target),
              let pull = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: 4096),
              let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 4096) else {
            throw SounderError.message("Cannot configure recording conversion")
        }
        self.converter = converter; self.pull = pull; self.output = output
        converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        converter.primeMethod = .normal
        if sourceFormat.channelCount > format.channels { converter.downmix = true }
        // Open ordinary capture lazily on its first output buffer. Loop capture
        // does not create any audio file until its final Stop.
    }
    func configureLoop(_ range: Range<Double>, start: Double) throws {
        try queue.sync {
            guard frames == 0, file == nil, !finished else { throw SounderError.message("Configure loop recording before capture starts") }
            let rate = format.sampleRate
            guard range.lowerBound.isFinite, range.upperBound.isFinite, start.isFinite, start >= 0,
                  range.lowerBound >= 0, range.upperBound * rate < Double(Int.max / 4), start * rate < Double(Int.max / 4) else { throw SounderError.message("Invalid recording loop range") }
            let first = Int((range.lowerBound * rate).rounded()), last = Int((range.upperBound * rate).rounded()), origin = Int((start * rate).rounded())
            guard last > first else { return }
            loopBuffer = LoopRecordingBuffer(bounds: first..<last, start: origin, channels: format.channels, sampleRate: rate)
            isLoopRecording = true
        }
    }
    private func openFile() throws {
        if file == nil { file = try AVAudioFile(forWriting: url, settings: format.recordingSettings, commonFormat: .pcmFormatFloat32, interleaved: false) }
    }
    func append(_ buffer: AVAudioPCMBuffer, hostTime: UInt64? = nil) {
        guard buffer.frameLength > 0 else { return }
        // Capture fallback timing before queueing; a slow writer is not device latency.
        let stamp = hostTime ?? AVAudioTime.hostTime(forSeconds: max(0, AVAudioTime.seconds(forHostTime: mach_absolute_time()) - Double(buffer.frameLength) / buffer.format.sampleRate))
        // Audio taps may reuse their buffers after the callback returns.
        guard buffer.format == captureFormat, let source = buffer.floatChannelData,
              let copy = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: buffer.frameLength),
              let destination = copy.floatChannelData else {
            enqueueFailure(SounderError.message("Audio input format changed during recording")); return
        }
        copy.frameLength = buffer.frameLength
        for channel in 0..<Int(sourceFormat.channelCount) {
            destination[channel].update(from: source[inputChannels[channel]], count: Int(buffer.frameLength))
        }
        // Enqueue under the same gate used by finish, so Stop cannot overtake an
        // accepted buffer, including when a tap callback is already in flight.
        gate.lock(); defer { gate.unlock() }
        guard accepting else { return }
        queue.async { [self] in
            guard failure == nil else { return }
            do {
                if let alignment {
                    // Without a hardware timestamp, only the first packet may
                    // use the arrival-time fallback. Later callbacks can jitter.
                    let offset: Int
                    if hostTime != nil || nextPacketFrame == nil {
                        guard let frame = alignment.clock.inputFrameOffset(hostTime: stamp, latency: alignment.latency, sampleRate: sourceFormat.sampleRate) else { return }
                        offset = frame
                    } else { offset = nextPacketFrame! }
                    // Keep the physical packet end even when pre-roll is
                    // discarded. A following untimestamped packet continues
                    // that input interval, rather than jumping to take zero.
                    nextPacketFrame = offset + Int(copy.frameLength)
                    if offset > nextInputFrame { try padInput(frames: offset - nextInputFrame); nextInputFrame = offset }
                    let skip = min(max(0, nextInputFrame - offset), Int(copy.frameLength))
                    let remaining = Int(copy.frameLength) - skip
                    guard remaining > 0 else { return }
                    if skip > 0 {
                        for channel in 0..<Int(copy.format.channelCount) {
                            memmove(copy.floatChannelData![channel], copy.floatChannelData![channel].advanced(by: skip), remaining * MemoryLayout<Float>.size)
                        }
                        copy.frameLength = AVAudioFrameCount(remaining)
                    }
                    nextInputFrame += remaining
                }
                try convert(copy, ending: false)
            }
            catch { fail(error) }
        }
    }
    private func padInput(frames: Int) throws {
        let silence = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: 4096)!
        for channel in 0..<Int(sourceFormat.channelCount) { silence.floatChannelData![channel].initialize(repeating: 0, count: 4096) }
        var remaining = frames
        while remaining > 0 {
            silence.frameLength = AVAudioFrameCount(min(remaining, 4096))
            try convert(silence, ending: false); remaining -= Int(silence.frameLength)
        }
    }
    func inputFailed(_ status: OSStatus) { enqueueFailure(SounderError.message("Audio input failed (audio error \(status)).")) }
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
                if let loopBuffer { publishLoop(output, buffer: loopBuffer) }
                else { try openFile(); try file!.write(from: output); publish(output) }
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
    private func publishLoop(_ input: AVAudioPCMBuffer, buffer: LoopRecordingBuffer) {
        buffer.append(input)
        let update = buffer.takeUpdate()
        var levels = [Float](repeating: 0, count: format.channels)
        for channel in levels.indices { for frame in 0..<Int(input.frameLength) { levels[channel] = max(levels[channel], abs(input.floatChannelData![channel][frame])) } }
        frames += Int(input.frameLength)
        publication.lock()
        if update.resetWaveform { loopPatches.removeAll(); loopReset = true }
        loopPatches.merge(update.peakPatches) { _, newest in newest }
        publishedLoop = update; publishedFrames = frames
        for channel in levels.indices { publishedPartial[channel] = max(publishedPartial[channel] ?? 0, levels[channel]) }
        publication.unlock()
    }
    func consumeUpdate() -> RecordingUpdate {
        publication.lock(); defer { publication.unlock() }
        let loop = publishedLoop.map { LoopRecordingUpdate(startFrame: $0.startFrame, cursorFrame: $0.cursorFrame, frameCount: $0.frameCount, resetWaveform: loopReset, peakPatches: loopPatches) }
        let result = RecordingUpdate(channelPeaks: pendingPeaks, partialChannelPeaks: publishedPartial, frames: publishedFrames, failure: publishedFailure, loop: loop)
        if isLoopRecording { publishedPartial = Array(repeating: nil, count: publishedPartial.count); loopPatches.removeAll(); loopReset = false }
        pendingPeaks = Array(repeating: [], count: pendingPeaks.count); return result
    }
    /// Used by deterministic stream tests; normal recording never blocks the UI
    /// waiting for individual buffers. Stop drains all accepted buffers once.
    func waitForPendingWrites() { queue.sync {} }
    var retainedLoopFrames: Int { queue.sync { loopBuffer?.allocatedFrames ?? 0 } }
    @discardableResult func finish(save: Bool = true) -> Error? {
        gate.lock(); accepting = false; gate.unlock()
        return queue.sync {
            guard !finished else { return failure }
            if save, failure == nil {
                do { try convert(nil, ending: true) } catch { fail(error) }
            }
            if save {
                do {
                    try openFile()
                    if let loopBuffer {
                        for offset in stride(from: 0, to: loopBuffer.count, by: Int(output.frameCapacity)) {
                            let count = min(Int(output.frameCapacity), loopBuffer.count - offset)
                            output.frameLength = AVAudioFrameCount(count)
                            loopBuffer.copy(to: output, offset: offset, count: count)
                            try file!.write(from: output)
                        }
                    }
                } catch { fail(error) }
            }
            file = nil; finished = true // Finalize the sole WAV before the editor reads it.
            if failure == nil || !save { loopBuffer = nil }
            return failure
        }
    }
}

final class LiveRecorder {
    let url: URL
    let format: ProjectAudioFormat
    let writer: RecordingWriter
    let metronome: MetronomeVoice
    private var capture: HardwareAudioCapture?
    var usesHardwareClock: Bool { capture != nil }
    private var stopped = false
    private var started = false
    private var lastFailure: Error?
    /// Supplying an input format creates a stream-only session for automated
    /// tests; microphone sessions always take the actual device's PCM format.
    init(url: URL, format: ProjectAudioFormat, inputFormat: AVAudioFormat? = nil, input: AudioEndpoint = AudioEndpoint()) throws {
        self.url = url
        metronome = MetronomeVoice(sampleRate: format.sampleRate)
        if let inputFormat { writer = try RecordingWriter(url: url, format: format, inputFormat: inputFormat, inputChannels: input.channels) }
        else {
            let capture = try HardwareAudioCapture(input: input)
            writer = try RecordingWriter(url: url, format: format, inputFormat: capture.format, inputChannels: input.channels)
            capture.received = { [writer] buffer, hostTime in writer.append(buffer, hostTime: hostTime) }
            capture.failed = { [writer] in writer.inputFailed($0) }
            self.capture = capture
        }
        self.format = writer.format
    }
    func configureSynchronization(clock: RecordingHostClock) {
        guard let capture else { return }
        writer.configureSynchronization(clock: clock, inputLatency: capture.presentationLatency)
    }
    func start() throws {
        guard !started, !stopped else { return }
        started = true
        do { try capture?.start() }
        catch { _ = stop(save: false); throw error }
    }
    func configureLoop(_ range: Range<Double>, start: Double) throws { try writer.configureLoop(range, start: start) }
    @discardableResult func stop(save: Bool = true) -> Error? {
        guard !stopped else { return lastFailure }
        stopped = true
        capture?.stop()
        lastFailure = writer.finish(save: save); capture = nil
        return lastFailure
    }
    deinit { _ = stop(save: started) }
}
