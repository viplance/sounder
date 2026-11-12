import AVFoundation

final class ShuttlePlayback {
    private let outputQueue: PlaybackOutputQueue
    var bufferFill: AudioBufferFill { outputQueue.fill }
    private var scheduled: Int { outputQueue.scheduled }
    func configureOutput(_ endpoint: AudioEndpoint) throws { try AudioDevices.configureOutput(endpoint, engine: engine, projectChannels: format.channels) }
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
    private var clock = PlaybackClock()
    private var requestedRevision = 0
    private var activeRevision = 0
    private var started = false
    var renderedPosition: Double { motion.position(at: Double(outputFrame - motionStartFrame) / format.sampleRate) }
    var renderedSpeed: Double { motion.speed(at: Double(outputFrame - motionStartFrame) / format.sampleRate) }
    var hasSettled: Bool { motion.settled(at: Double(outputFrame - motionStartFrame) / format.sampleRate) }
    var sourceTransitionComplete: Bool { hasSettled && outputFrame - sourceChangeFrame >= Int(format.sampleRate * 0.010) }
    var reachedEnd: Bool { terminal || motion.reachedBoundary(at: Double(outputFrame - motionStartFrame) / format.sampleRate) }
    var finished: ((Error?) -> Void)?
    private let cancellation = NSLock()
    private var cancelled = false
    private var outputFrame = 0
    private var terminal = false
    var isPlaying: Bool { node.isPlaying && engine.isRunning }
    private var isCancelled: Bool { cancellation.lock(); defer { cancellation.unlock() }; return cancelled }
    var currentTime: Double {
        let frame = PlaybackClock.playerFrame(node: node, sampleRate: format.sampleRate, rounding: .towardZero)
        motionLock.lock(); defer { motionLock.unlock() }
        clock.observe(frame)
        let result = clock.position(at: clock.playedFrames, sampleRate: format.sampleRate, fallback: clock.segments[0].motion.start)
        clock.retainHistory(frames: max(outputQueue.capacity, 512))
        return result
    }

    init(source: DryShuttleSource, start: Double, direction: Double, initialSpeed: Double = 0) {
        self.source = source; self.format = source.project.audioFormat
        outputQueue = PlaybackOutputQueue(capacity: source.project.playbackBufferSize)
        let format = source.project.audioFormat
        motion = ShuttleMotion(start: start, direction: direction < 0 ? -1 : 1, end: Double(source.frameCount) / format.sampleRate, initialSpeed: initialSpeed)
        clock.segments = [(0, motion)]
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
        motionLock.lock(); clock.renderedFrames = outputFrame; motionLock.unlock()
        return buffer
    }
    // Worker-only: re-anchor at the next unscheduled sample, preserving phase
    // and signed velocity across key release or a change of direction.
    func retarget(_ target: Double, revision: Int? = nil, end: Double? = nil) {
        let direction = target == 0 ? (renderedSpeed < 0 ? -1.0 : 1.0) : (target < 0 ? -1.0 : 1.0)
        let next = ShuttleMotion(start: renderedPosition, direction: direction, end: end ?? motion.end, initialSpeed: renderedSpeed, target: target)
        motion = next; motionStartFrame = outputFrame; terminal = false
        motionLock.lock()
        if let revision { activeRevision = revision } else { requestedRevision += 1; activeRevision = requestedRevision }
        clock.segments.append((outputFrame, next)); motionLock.unlock()
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
                for _ in 0..<self.outputQueue.blockCount { try self.enqueue() }
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
        let frames = outputQueue.nextBlock()
        guard let buffer = try render(frames: frames) else {
            if scheduled == 0 { report(nil) }
            return
        }
        guard !isCancelled else { return }
        outputQueue.schedule(buffer, on: node, worker: queue, final: reachedEnd, manual: engine.isInManualRenderingMode) { [weak self] in
            guard let self, !self.isCancelled else { return }
            do { try self.enqueue() } catch { self.report(error) }
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
        outputQueue.reset()
        cancellation.lock(); cancelled = true; cancellation.unlock()
        node.stop(); engine.stop()
        // Each gesture owns its source snapshot and no plug-ins. Cancellation
        // must not wait on a decoder or disk I/O on the main thread.
    }
    deinit { engine.stop() }
}
