import AVFoundation

/// A source position and its DAC instant from the same render timestamp.
struct RecordingPlaybackAnchor {
    let sourceTime: Double
    let hostTime: UInt64
}

/// Keep a short render-ahead queue, replenished when buffers are consumed.
/// Device presentation callbacks are reserved for the final buffer: they arrive
/// too late to drive a continuous stream on outputs with presentation latency.
final class LivePlayback {
    private let outputQueue = PlaybackOutputQueue(capacity: PlaybackBufferSize.initialFrames)
    var bufferFill: AudioBufferFill { outputQueue.fill }
    var bufferFrameCount: Int { outputQueue.capacity }
    private var bufferBlockCount: Int { outputQueue.blockCount }
    private var scheduled: Int { outputQueue.scheduled }
    func configureBufferSize(_ frames: Int) throws {
        precondition(!running, "Configure the buffer before starting playback")
        try outputQueue.configure(capacity: frames)
    }
    func configureOutput(_ endpoint: AudioEndpoint) throws { try AudioDevices.configureOutput(endpoint, engine: engine, projectChannels: format.channels) }
    let engine = AVAudioEngine()
    let node = AVAudioPlayerNode()
    private(set) var graph: StreamingGraph
    let format: ProjectAudioFormat
    let queue = DispatchQueue(label: "Sounder.playback", qos: .userInteractive)
    private let meterBuffer = PlaybackMeterBuffer()
    private var phase: PlaybackRenderPhase = .inactive
    private let control = PlaybackTransportState()
    private var running: Bool { phase.active }
    private var effectsOnly: Bool { phase == .idleEffects }
    private var pausing: Bool { phase == .fadingOut }
    private var effectHosts: [SNPluginHost] = []
    var continuesEffectsWhenPaused = false
    var isAuditioningEffects: Bool { control.snapshot.auditionPosition != nil }
    var isProcessingLiveEffects: Bool { isAuditioningEffects && engine.isRunning && node.isPlaying }
    private var pauseFadeFrames = 0
    private var pauseFadeFrame = 0
    private var resumeFadeFrame: Int?
    private var resumeSourcePrerollFrames = 0
    var isPaused: Bool { control.snapshot.isPaused }
    var pauseComplete: Bool { control.snapshot.pausePosition != nil }
    var pausePosition: Double { control.snapshot.pauseTarget }
    var didPause: ((Double) -> Void)?
    var didResume: (() -> Void)?
    private var tempo = 120.0
    private var metronomeEnabled = false
    private var nextFrame: Int
    private var outputFrames = 0
    private var shuttleRenderer: ShuttlePlayback?
    private var renderingNormal = true
    private var recordingPlayback = false
    private var loopFrames: Range<Int>?
    private var loopArmed = false
    private var loopHasWrapped = false
    private var metronomeFadeStart = 0
    private let returnQueue = DispatchQueue(label: "Sounder.return-to-play", qos: .userInitiated)
    private let returnLock = NSLock()
    private var returnToken: UUID?
    var returnReady: Bool { control.snapshot.returnReady }
    var restored: ((StreamingGraph) -> Void)?
    var snapshotGraph: StreamingGraph { queue.sync { graph } }
    private func cancelReturn() { returnLock.lock(); returnToken = nil; returnLock.unlock() }
    private func isCurrentReturn(_ token: UUID) -> Bool { returnLock.lock(); defer { returnLock.unlock() }; return returnToken == token }
    func completeReturn() { control.update { $0.isShuttling = false; $0.returnReady = false }; cancelReturn() }
    private let transportLock = NSLock()
    private var isStopping: Bool { control.snapshot.stopping }
    private var clock = PlaybackClock()
    var isShuttling: Bool { control.snapshot.isShuttling }
    var shuttleUsesProcessedCache: Bool { control.snapshot.shuttleUsesProcessedCache }
    private(set) var start: Double
    private var seekRequest: (id: UUID, time: Double, outputFrame: Int?)?
    private var seekFade: [Float] = []
    private var seekFadeFrame = 0
    var seekPosition: Double {
        let audible = currentTime
        transportLock.lock(); defer { transportLock.unlock() }
        if let request = seekRequest, request.outputFrame == nil || clock.playedFrames < request.outputFrame! { return request.time }
        return audible
    }
    var finished: ((Error?) -> Void)?
    private var firstFrame: Int
    var isPlaying: Bool {
        let state = control.snapshot
        return !state.stopping && state.auditionPosition == nil && !state.isPaused && engine.isRunning && (node.isPlaying || state.intent == .resume)
    }
    var renderedFrames: Int { queue.sync { graph.position } }
    var currentTime: Double {
        let state = control.snapshot
        if let frozen = state.auditionPosition ?? state.pausePosition { return frozen }
        let renderedClock = PlaybackClock.playerFrame(node: node, sampleRate: format.sampleRate)
        transportLock.lock(); defer { transportLock.unlock() }
        clock.observe(renderedClock)
        let position = sourceTimeLocked(at: clock.playedFrames)
        // Retain the queued window's history too: a recording snapshot can
        // straddle a very short loop wrap relative to the UI's last clock read.
        clock.retainHistory(frames: max(bufferFrameCount, 512))
        return position
    }
    /// Caller holds transportLock. Rendered PCM, cursor and recording all use
    /// this mapping from monotonic output frames to the source timeline.
    private func sourceTimeLocked(at frame: Int) -> Double {
        clock.position(at: frame, sampleRate: format.sampleRate,
                       fallback: Double(recordingPlayback ? firstFrame + frame : min(graph.totalFrames, firstFrame + frame)) / format.sampleRate)
    }
    var currentSpeed: Double {
        _ = currentTime
        transportLock.lock(); defer { transportLock.unlock() }
        return clock.speed(sampleRate: format.sampleRate)
    }

    init(graph: StreamingGraph, format: ProjectAudioFormat, start: Double) {
        self.graph = graph; self.format = format
        firstFrame = max(0, Int((start * format.sampleRate).rounded()))
        self.start = Double(firstFrame) / format.sampleRate; nextFrame = firstFrame
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: AVAudioChannelCount(format.channels))!)
    }
    // Capture may outlast existing material. Keep output and its metronome
    // clock running through silence, without changing the saved project length.
    func prepareForRecording() throws {
        try queue.sync {
            transportLock.lock(); recordingPlayback = true; transportLock.unlock()
            // The final buffer can have drained while its completion is still
            // waiting on the main queue. Record takes ownership of transport.
            if !running && engine.isRunning && node.isPlaying { phase = .timeline }
            let end = Double(Int.max / 4) / format.sampleRate
            if let renderer = shuttleRenderer {
                let source = DryShuttleSource(project: renderer.source.project, store: renderer.source.store, processed: graph.outputCache, latency: graph.latency, frameCount: Int.max / 4, liveGraph: graph)
                renderer.replaceSource(source); renderer.retarget(1, end: end)
                transportLock.lock(); clock.segments.append((outputFrames, renderer.motion)); transportLock.unlock()
            } else {
                let motion = ShuttleMotion(start: Double(nextFrame) / format.sampleRate, direction: 1, end: end, initialSpeed: 1, target: 1)
                transportLock.lock(); clock.segments.append((outputFrames, motion)); transportLock.unlock()
            }
            if running {
                let pcm = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: AVAudioChannelCount(format.channels))!
                while scheduled < bufferBlockCount { try enqueue(format: pcm) }
            }
        }
    }
    func cancelRecordingPreparation() {
        queue.sync {
            transportLock.lock(); recordingPlayback = false; transportLock.unlock()
            if let renderer = shuttleRenderer {
                let source = DryShuttleSource(project: renderer.source.project, store: renderer.source.store, processed: graph.outputCache, latency: graph.latency, frameCount: graph.totalFrames, liveGraph: graph)
                renderer.replaceSource(source); renderer.retarget(1, end: Double(graph.totalFrames) / format.sampleRate)
                transportLock.lock(); clock.segments.append((outputFrames, renderer.motion)); transportLock.unlock()
            }
        }
    }
    func startPlayback(playImmediately: Bool = true, continueEffects: Bool = false, cancelled: () -> Bool = { false }, progress: (Int) -> Void = { _ in }) throws {
        let pcmFormat = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: AVAudioChannelCount(format.channels))!
        // Warm effects from project zero and discard compensated latency when seeking.
        try queue.sync {
            resetLoopPosition(nextFrame)
            let skip = nextFrame + graph.latency
            if continueEffects || !graph.needsHistory { try graph.seek(to: nextFrame) }
            while graph.position < skip {
                if cancelled() { throw CancellationError() }
                let count = min(512, skip - graph.position)
                _ = try graph.render(frames: count); progress(count)
            }
            phase = .timeline
            let buffers = bufferBlockCount
            for _ in 0..<buffers {
                if cancelled() { throw CancellationError() }
                let before = outputFrames
                try enqueue(format: pcmFormat)
                progress(outputFrames - before)
            }
        }
        engine.prepare(); try engine.start()
        if playImmediately { node.play() }
    }
    func beginPreparedPlayback(at hostTime: UInt64? = nil) {
        if let hostTime { node.play(at: AVAudioTime(hostTime: hostTime)) } else { node.play() }
    }
    var recordingOutputLatency: Double { engine.isInManualRenderingMode ? 0 : max(0, node.outputPresentationLatency) }
    /// Map the recording trigger to the DAC clock without changing the existing
    /// transport clock. Render-ahead PCM and declared FX latency are already
    /// accounted for by the player timeline and must not be subtracted again.
    func recordingPresentationHostTime(at sourceTime: Double) -> UInt64? {
        recordingAnchor(at: sourceTime)?.hostTime
    }
    func recordingAnchor(at sourceTime: Double? = nil) -> RecordingPlaybackAnchor? {
        guard !engine.isInManualRenderingMode, let stamp = node.lastRenderTime, stamp.isHostTimeValid,
              let played = node.playerTime(forNodeTime: stamp), played.isSampleTimeValid, played.sampleRate > 0 else { return nil }
        return recordingAnchor(at: sourceTime, renderTime: stamp, playerTime: played, outputLatency: recordingOutputLatency)
    }
    // Explicit clock pair also allows deterministic DAC/ADC synchronization
    // tests without substituting callback wall time or requiring a microphone.
    func recordingAnchor(at sourceTime: Double? = nil, renderTime stamp: AVAudioTime, playerTime played: AVAudioTime, outputLatency: Double) -> RecordingPlaybackAnchor? {
        guard stamp.isHostTimeValid, played.isSampleTimeValid, played.sampleRate > 0 else { return nil }
        let frame = Int((Double(played.sampleTime) * format.sampleRate / played.sampleRate).rounded())
        transportLock.lock()
        // Device time can advance through an output underrun while DSP is
        // blocked. Clamping only its sample coordinate would move the paired
        // host time into the past and pad the new take with fictitious silence.
        // There is no trustworthy source/DAC pair beyond scheduled output.
        guard frame >= 0, frame <= clock.renderedFrames else { transportLock.unlock(); return nil }
        let boundedFrame = frame
        let origin = sourceTime ?? sourceTimeLocked(at: boundedFrame)
        let targetFrame: Double
        if let seekRequest, abs(seekRequest.time - origin) < 0.5 / format.sampleRate, sourceTime != nil {
            // Enter can restart a take while its seek is still queued for output.
            guard let boundary = seekRequest.outputFrame else { transportLock.unlock(); return nil }
            targetFrame = Double(boundary)
        } else {
            targetFrame = Double(boundedFrame) + (origin - sourceTimeLocked(at: boundedFrame)) * format.sampleRate
        }
        transportLock.unlock()
        let seconds = AVAudioTime.seconds(forHostTime: stamp.hostTime) + (targetFrame - Double(frame)) / format.sampleRate + max(0, outputLatency)
        guard seconds.isFinite, seconds >= 0 else { return nil }
        return RecordingPlaybackAnchor(sourceTime: origin, hostTime: AVAudioTime.hostTime(forSeconds: seconds))
    }
    // Only the player pauses. Keep the engine, decoded PCM and live processors
    // ready, and finish the short fade at its audible completion, not consumption.
    func pause() throws {
        cancelReturn()
        control.update { $0.intent = .pause }
        try queue.sync {
            if pausing { return }
            let wasRunning = running
            phase = .fadingOut; control.update { $0.pause = .pending }
            let position = shuttleRenderer.map { Int(($0.renderedPosition * format.sampleRate).rounded()) } ?? nextFrame
            pauseFadeFrames = loopArmed && loopFrames != nil && !recordingPlayback ? Int(format.sampleRate * 0.010) : min(Int(format.sampleRate * 0.010), max(0, graph.totalFrames - position))
            pauseFadeFrame = 0
            let target = Double(position + pauseFadeFrames) / format.sampleRate
            control.update { $0.pauseTarget = target }
            guard wasRunning else { try finishPause(); return }
            if pauseFadeFrames == 0 {
                if scheduled == 0 { try finishPause() }
                return
            }
            let pcm = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: AVAudioChannelCount(format.channels))!
            while pauseFadeFrame < pauseFadeFrames {
                let before = pauseFadeFrame
                try enqueue(format: pcm)
                if pauseFadeFrame == before { break }
            }
        }
    }
    func resume(to time: Double) throws {
        start = max(0, (time * format.sampleRate).rounded()) / format.sampleRate
        control.update { $0.intent = .resume }
        try queue.sync {
            let frame = Int((start * format.sampleRate).rounded())
            if effectsOnly {
                phase = .timeline
                let stationary = ShuttleMotion(start: start, direction: 1, end: Double(Int.max / 4) / format.sampleRate, initialSpeed: 0, target: 0)
                control.update { $0.auditionPosition = nil }
                transportLock.lock(); clock.segments = [(clock.playedFrames, stationary)]; transportLock.unlock()
                for host in effectHosts { host.setTransportPlaying(true, position: Int64(frame), tempo: tempo) }
                try resumeAtQueuedBoundary(at: frame, restoringTimeline: true)
            } else if pausing { try resumeAtQueuedBoundary(at: frame) }
            else { try restartPausedNode(at: frame) }
        }
    }
    private func finishPause() throws {
        if continuesEffectsWhenPaused && graph.hasEffects {
            try configureEffects(position: pausePosition, hosts: effectHosts, tempo: tempo, drainTimeline: true)
        } else { node.pause(); phase = .inactive }
        control.update { $0.pause = .complete($0.pauseTarget) }
        let position = pausePosition, generation = outputQueue.revision
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isPaused, self.outputQueue.revision == generation else { return }
            self.didPause?(position)
        }
    }
    private func resumeAtQueuedBoundary(at frame: Int, restoringTimeline: Bool = false) throws {
        // A quick second Space can arrive before the fade-out is audible.
        // Queue the fade-in immediately after it; do not wait for presentation
        // and restart the node, which would introduce a gap or lose the seek.
        outputQueue.reset(); phase = .timeline; control.update { $0.pause = .pending }
        // Idle FX have consumed silence even when graph.position still matches
        // the paused cursor. Refill plug-in and routing latency before exposing
        // timeline motion, just as a live seek does, without resetting hosts.
        resumeSourcePrerollFrames = restoringTimeline ? graph.latency : 0
        if restoringTimeline {
            try graph.seek(to: frame, fadeInFrames: Int(format.sampleRate * 0.010))
        } else if shuttleRenderer != nil || graph.position != frame + graph.latency { try graph.seek(to: frame) }
        shuttleRenderer = nil; renderingNormal = true; nextFrame = frame
        resetLoopPosition(frame)
        seekFade = []; seekFadeFrame = 0; resumeFadeFrame = 0; meterBuffer.clear()
        let motion = ShuttleMotion(start: Double(frame) / format.sampleRate, direction: 1, end: Double(graph.totalFrames) / format.sampleRate, initialSpeed: 1, target: 1)
        transportLock.lock(); clock.segments.append((outputFrames, motion)); seekRequest = nil; transportLock.unlock()
        let pcm = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: AVAudioChannelCount(format.channels))!
        for _ in 0..<bufferBlockCount { try enqueue(format: pcm) }
        // A rapid resume retains the queued 10 ms fade. Complete its partial
        // render quantum with real PCM so a short queue cannot run dry inside
        // that quantum before consumed callbacks replenish it. This one-off
        // bridge drains without increasing the steady-state queue capacity.
        let bridge = (PlaybackBufferSize.blockFrames - outputFrames % PlaybackBufferSize.blockFrames) % PlaybackBufferSize.blockFrames
        if bridge > 0 { try enqueue(format: pcm, bridgeFrames: bridge) }
        control.update { $0.intent = .play }
        notifyResumed()
    }
    private func restartPausedNode(at frame: Int) throws {
        // A genuine pause has already reached silence. Flush obsolete queued
        // callbacks and reset the node clock, without restarting audio hardware.
        outputQueue.reset(); control.update { $0.pause = .pending }
        node.stop()
        if shuttleRenderer != nil || graph.position != frame + graph.latency { try graph.seek(to: frame) }
        shuttleRenderer = nil; renderingNormal = true
        nextFrame = frame; outputFrames = 0
        resetLoopPosition(frame)
        transportLock.lock()
        firstFrame = frame; clock.reset(); seekRequest = nil
        transportLock.unlock()
        seekFade = []; seekFadeFrame = 0; resumeFadeFrame = 0; resumeSourcePrerollFrames = 0
        meterBuffer.clear(); phase = .timeline
        let pcm = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: AVAudioChannelCount(format.channels))!
        for _ in 0..<bufferBlockCount { try enqueue(format: pcm) }
        node.play(); control.update { $0.intent = .play }
        notifyResumed()
    }
    private func reportCompletion(_ error: Error?) {
        phase = .inactive
        let revision = outputQueue.revision
        DispatchQueue.main.async { [weak self] in
            guard let self, self.outputQueue.isCurrent(revision), !self.isStopping else { return }
            if error == nil && (self.isPaused || self.isAuditioningEffects) { return }
            self.finished?(error)
        }
    }
    private func notifyResumed() {
        let revision = outputQueue.revision
        DispatchQueue.main.async { [weak self] in
            guard let self, self.outputQueue.isCurrent(revision), !self.isStopping,
                  !self.isPaused, !self.isAuditioningEffects else { return }
            self.didResume?()
        }
    }
    private func transportGain(at frame: Int) -> Float {
        if pausing { return Float(max(0, 1 - Double(pauseFadeFrame + frame) / Double(max(1, pauseFadeFrames - 1)))) }
        if let first = resumeFadeFrame { return Float(min(1, Double(first + frame) / Double(max(1, Int(format.sampleRate * 0.010) - 1)))) }
        return 1
    }
    private func advanceTransportFade(frames: Int) -> Bool {
        if pausing { pauseFadeFrame += frames; return pauseFadeFrame >= pauseFadeFrames }
        if let first = resumeFadeFrame {
            resumeFadeFrame = first + frames >= Int(format.sampleRate * 0.010) ? nil : first + frames
        }
        return false
    }
    func seek(to time: Double) {
        cancelReturn(); control.update { $0.returnReady = false }
        let target = max(0, Int((time * format.sampleRate).rounded()))
        let id = UUID()
        start = Double(target) / format.sampleRate
        transportLock.lock(); seekRequest = (id, start, nil); transportLock.unlock()
        queue.async {
            self.transportLock.lock(); let current = self.seekRequest?.id == id; self.transportLock.unlock()
            guard self.running, current else { return }
            do {
                let fadePending = self.seekFadeFrame == 0 && !self.seekFade.isEmpty
                let previousFade = self.seekFade
                let previousFadeFrame = self.seekFadeFrame
                let count = self.recordingPlayback ? Int(self.format.sampleRate * 0.010) : min(Int(self.format.sampleRate * 0.010), max(0, self.graph.totalFrames - self.nextFrame))
                let oldPosition: Double
                if fadePending {
                    // No target samples have been queued yet: keep the audible
                    // outgoing side, rather than fading from an unheard seek.
                    oldPosition = 0
                } else if let renderer = self.shuttleRenderer {
                    oldPosition = renderer.renderedPosition
                    if let buffer = try renderer.render(frames: max(1, count)) {
                        self.seekFade = (0..<Int(buffer.frameLength)).flatMap { i in (0..<self.format.channels).map { buffer.floatChannelData![$0][i] } }
                    } else { self.seekFade = [] }
                } else {
                    oldPosition = Double(self.nextFrame) / self.format.sampleRate
                    self.seekFade = []
                    var remaining = count
                    while remaining > 0 {
                        let frames = min(512, remaining)
                        self.seekFade += try self.graph.render(frames: frames); remaining -= frames
                    }
                }
                if !fadePending, self.metronomeEnabled {
                    for i in 0..<(self.seekFade.count / self.format.channels) {
                        let click = MetronomeClick.sample(frame: Int64(oldPosition * self.format.sampleRate) + Int64(i), sampleRate: self.format.sampleRate, bpm: self.tempo)
                        for ch in 0..<self.format.channels { self.seekFade[i * self.format.channels + ch] += click }
                    }
                }
                if !fadePending, previousFadeFrame < previousFade.count / self.format.channels {
                    for i in 0..<min(self.seekFade.count / self.format.channels, previousFade.count / self.format.channels - previousFadeFrame) {
                        let blend = Float(previousFadeFrame + i) / Float(max(1, previousFade.count / self.format.channels - 1))
                        for ch in 0..<self.format.channels {
                            let index = i * self.format.channels + ch
                            self.seekFade[index] = previousFade[(previousFadeFrame + i) * self.format.channels + ch] * (1 - blend) + self.seekFade[index] * blend
                        }
                    }
                }
                self.seekFade = Array(self.seekFade.prefix(max(0, self.graph.totalFrames - target) * self.format.channels))
                self.seekFadeFrame = 0
                try self.graph.seek(to: target)
                self.shuttleRenderer = nil; self.renderingNormal = true; self.nextFrame = target
                self.resetLoopPosition(target)
                self.meterBuffer.clear()
                let motion = ShuttleMotion(start: Double(target) / self.format.sampleRate, direction: 1, end: Double(self.recordingPlayback ? Int.max / 4 : self.graph.totalFrames) / self.format.sampleRate, initialSpeed: 1, target: 1)
                self.transportLock.lock()
                self.clock.segments.append((self.outputFrames, motion))
                if self.seekRequest?.id == id { self.seekRequest?.outputFrame = self.outputFrames }
                self.transportLock.unlock()
            } catch { self.reportCompletion(error) }
        }
    }
    func beginShuttle(source: DryShuttleSource, direction: Double) {
        cancelReturn(); control.update { $0.returnReady = false }
        control.update { $0.isShuttling = true; $0.shuttleUsesProcessedCache = source.processed != nil }
        queue.async {
            guard self.running else { return }
            do {
                if self.shuttleRenderer == nil {
                    let pcm = AVAudioFormat(standardFormatWithSampleRate: self.format.sampleRate, channels: AVAudioChannelCount(self.format.channels))!
                    while !self.seekFade.isEmpty && self.nextFrame < self.graph.totalFrames { try self.enqueue(format: pcm) }
                }
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
                self.transportLock.lock(); self.clock.segments.append((self.outputFrames, renderer.motion)); self.transportLock.unlock()
            } catch { self.reportCompletion(error) }
        }
    }
    func releaseShuttle(makeGraph: @escaping (@escaping () -> Bool) throws -> StreamingGraph) {
        cancelReturn(); control.update { $0.returnReady = false }
        let token = UUID()
        returnLock.lock(); returnToken = token; returnLock.unlock()
        queue.async {
            guard self.running, let renderer = self.shuttleRenderer else { return }
            renderer.retarget(1)
            self.transportLock.lock(); self.clock.segments.append((self.outputFrames, renderer.motion)); self.transportLock.unlock()
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
                                self.control.update { $0.returnReady = true }; self.restored?(graph)
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
    private func enqueue(format pcmFormat: AVAudioFormat, bridgeFrames: Int? = nil) throws {
        guard running, !isStopping else { return }
        // Stop closes the source immediately, before this worker has finished
        // its current DSP block. Old consumption callbacks must not refill it.
        guard effectsOnly || !isAuditioningEffects else { return }
        if effectsOnly { try enqueueIdleEffects(format: pcmFormat); return }
        guard !pausing || pauseFadeFrame < pauseFadeFrames else { return }
        let blockFrames = bridgeFrames ?? outputQueue.nextBlock()
        let requestedFrames = pausing ? min(blockFrames, pauseFadeFrames - pauseFadeFrame) : blockFrames
        guard requestedFrames > 0 else { return }
        if let renderer = shuttleRenderer, renderingNormal, !isShuttling, loopFrames != nil, renderer.sourceTransitionComplete {
            nextFrame = max(0, Int((renderer.renderedPosition * format.sampleRate).rounded()))
            seekFade = []; seekFadeFrame = 0
            if let loopFrames, loopFrames.contains(nextFrame),
               let continuation = try renderer.render(frames: min(Int(format.sampleRate * 0.010), loopFrames.upperBound - nextFrame)) {
                seekFade = (0..<Int(continuation.frameLength)).flatMap { i in (0..<format.channels).map { continuation.floatChannelData![$0][i] } }
            }
            try graph.seek(to: nextFrame)
            shuttleRenderer = nil; resetLoopPosition(nextFrame); appendLoopPosition(nextFrame)
        }
        if let renderer = shuttleRenderer {
            try enqueueShuttle(renderer, frames: requestedFrames, format: pcmFormat, replenishes: bridgeFrames == nil)
        } else {
            try enqueueTimeline(frames: requestedFrames, format: pcmFormat, replenishes: bridgeFrames == nil)
        }
    }
    private func enqueueIdleEffects(format pcmFormat: AVAudioFormat) throws {
        let count = outputQueue.nextBlock()
        let values = try graph.render(frames: count, mode: .idleEffects)
        let buffer = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: AVAudioFrameCount(count))!
        buffer.frameLength = AVAudioFrameCount(count)
        let encoding = PlaybackPCMEncoding(bitDepth: format.bitDepth)
        for frame in 0..<count { for channel in 0..<format.channels {
            let value = values[frame * format.channels + channel]
            buffer.floatChannelData![channel][frame] = encoding.sample(value)
        } }
        meterBuffer.append(frame: outputFrames + count, peaks: graph.trackPeaks)
        outputFrames += count
        schedule(buffer, last: false, format: pcmFormat)
    }
    private func enqueueShuttle(_ renderer: ShuttlePlayback, frames requestedFrames: Int, format pcmFormat: AVAudioFormat, replenishes: Bool) throws {
        guard let buffer = try renderer.render(frames: requestedFrames) else {
            if scheduled == 0 { reportCompletion(nil) }
            return
        }
        if renderingNormal {
            let first = renderer.renderedPosition - Double(buffer.frameLength) / format.sampleRate
            let encoding = PlaybackPCMEncoding(bitDepth: format.bitDepth)
            for i in 0..<Int(buffer.frameLength) {
                let fade = min(1, Double(outputFrames + i - metronomeFadeStart) / (0.010 * format.sampleRate))
                let click = metronomeEnabled ? MetronomeClick.sample(frame: Int64(first * format.sampleRate) + Int64(i), sampleRate: format.sampleRate, bpm: tempo) * Float(fade) : 0
                for ch in 0..<format.channels {
                    let value = min(1, max(-1, (buffer.floatChannelData![ch][i] + click) * transportGain(at: i)))
                    buffer.floatChannelData![ch][i] = encoding.sample(value)
                }
            }
            meterBuffer.append(frame: outputFrames + Int(buffer.frameLength), peaks: graph.trackPeaks)
        }
        outputFrames += Int(buffer.frameLength)
        let pauseFinal = advanceTransportFade(frames: Int(buffer.frameLength))
        schedule(buffer, last: renderer.reachedEnd, format: pcmFormat, pauseFinal: pauseFinal, replenishes: replenishes)
    }
    private func enqueueTimeline(frames requestedFrames: Int, format pcmFormat: AVAudioFormat, replenishes: Bool) throws {
        let loop = !isShuttling && loopArmed ? loopFrames : nil
        let frames = recordingPlayback || loop != nil ? requestedFrames : min(requestedFrames, graph.totalFrames - nextFrame)
        guard frames > 0 else {
            if scheduled == 0 { reportCompletion(nil) }
            return
        }
        if loop != nil { appendLoopPosition(nextFrame) }
        var samples: [Float] = [], positions: [Int] = []
        var loopGains = [Float](repeating: 1, count: frames)
        samples.reserveCapacity(frames * format.channels); positions.reserveCapacity(frames)
        while positions.count < frames {
            if let loop, nextFrame >= loop.upperBound {
                try graph.seek(to: loop.lowerBound)
                nextFrame = loop.lowerBound; loopHasWrapped = true; seekFade = []; seekFadeFrame = 0
                appendLoopPosition(nextFrame, at: outputFrames + positions.count)
            }
            let count = min(frames - positions.count, loop.map { $0.upperBound - nextFrame } ?? frames)
            if pausing && continuesEffectsWhenPaused && graph.hasEffects {
                samples.append(contentsOf: try graph.render(frames: count,
                    mode: .fadeOut(remaining: pauseFadeFrames - pauseFadeFrame - positions.count, length: pauseFadeFrames)))
            } else if let first = resumeFadeFrame, continuesEffectsWhenPaused && graph.hasEffects {
                samples.append(contentsOf: try graph.render(frames: count,
                    mode: .fadeIn(frame: resumeSourcePrerollFrames + first + positions.count, length: Int(format.sampleRate * 0.010))))
            } else { samples.append(contentsOf: try graph.render(frames: count)) }
            if let loop {
                let fade = Double(max(1, min(Int(format.sampleRate * 0.010), loop.count / 2)))
                for i in 0..<count {
                    // The first pass may begin before the selected period. Do
                    // not silence that lead-in or dip on entering its left edge.
                    let outgoing = Double(loop.upperBound - 1 - nextFrame - i) / fade
                    let incoming = loopHasWrapped ? Double(nextFrame + i - loop.lowerBound) / fade : 1
                    loopGains[positions.count + i] = Float(min(1, max(0, min(incoming, outgoing))))
                }
            }
            positions.append(contentsOf: nextFrame..<(nextFrame + count))
            meterBuffer.append(frame: outputFrames + positions.count, peaks: graph.trackPeaks)
            nextFrame += count
        }
        let buffer = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        let encoding = PlaybackPCMEncoding(bitDepth: format.bitDepth)
        for frame in 0..<frames { for channel in 0..<format.channels {
            let click = metronomeEnabled ? MetronomeClick.sample(frame: Int64(positions[frame]), sampleRate: format.sampleRate, bpm: tempo) : 0
            var value = samples[frame * format.channels + channel] + click
            let fadeFrame = seekFadeFrame + frame
            if fadeFrame < seekFade.count / format.channels {
                let blend = Float(fadeFrame) / Float(max(1, seekFade.count / format.channels - 1))
                value = seekFade[fadeFrame * format.channels + channel] * (1 - blend) + value * blend
            }
            let transport = transportGain(at: frame)
            if (pausing || resumeFadeFrame != nil) && continuesEffectsWhenPaused && graph.hasEffects {
                // Fade only dry timeline audio; existing voices and FX tails
                // must not dip and then jump back up when idle DSP takes over.
                value -= click * (1 - transport)
                value = min(1, max(-1, value * loopGains[frame]))
            } else { value = min(1, max(-1, value * transport * loopGains[frame])) }
            buffer.floatChannelData![channel][frame] = encoding.sample(value)
        } }
        seekFadeFrame += frames
        if seekFadeFrame >= seekFade.count / format.channels { seekFade = [] }
        outputFrames += frames
        if pausing, loop != nil {
            let target = Double(nextFrame) / format.sampleRate
            control.update { $0.pauseTarget = target }
        }
        let pauseFinal = advanceTransportFade(frames: frames)
        schedule(buffer, last: !recordingPlayback && loop == nil && nextFrame == graph.totalFrames, format: pcmFormat, pauseFinal: pauseFinal, replenishes: replenishes)
    }
    private func schedule(_ buffer: AVAudioPCMBuffer, last: Bool, format pcmFormat: AVAudioFormat, pauseFinal: Bool = false, replenishes: Bool = true) {
        // Stop may arrive while this buffer's DSP is blocked. Do not publish
        // that obsolete PCM or give its callback ownership of the new queue.
        guard !isStopping, effectsOnly || !isAuditioningEffects else { return }
        transportLock.lock(); clock.renderedFrames = outputFrames; transportLock.unlock()
        outputQueue.schedule(buffer, on: node, worker: queue, final: last || pauseFinal, manual: engine.isInManualRenderingMode) { [weak self] in
            guard let self, self.running else { return }
            do {
                if self.pausing {
                    if pauseFinal || self.scheduled == 0 { try self.finishPause() }
                } else if replenishes || last { try self.enqueue(format: pcmFormat) }
            } catch { self.reportCompletion(error) }
        }
    }

    func consumeTrackPeaks(at time: Double) -> [UUID: StereoLevels] {
        _ = currentTime
        transportLock.lock(); let frame = clock.playedFrames; transportLock.unlock()
        return meterBuffer.consume(through: frame)
    }
    private func resetLoopPosition(_ frame: Int) {
        loopArmed = loopFrames.map { frame <= $0.upperBound } ?? false
        loopHasWrapped = loopFrames.map { frame == $0.lowerBound } ?? false
    }
    private func appendLoopPosition(_ frame: Int, at outputFrame: Int? = nil) {
        let motion = ShuttleMotion(start: Double(frame) / format.sampleRate, direction: 1, end: Double(Int.max / 4) / format.sampleRate, initialSpeed: 1, target: 1)
        transportLock.lock(); clock.segments.append((outputFrame ?? outputFrames, motion)); transportLock.unlock()
    }
    func setLoop(_ range: Range<Double>?) {
        let frames: Range<Int>? = range.flatMap {
            guard $0.lowerBound.isFinite, $0.upperBound.isFinite, $0.lowerBound >= 0,
                  $0.upperBound * format.sampleRate < Double(Int.max / 4) else { return nil }
            let first = Int(($0.lowerBound * format.sampleRate).rounded()), last = Int(($0.upperBound * format.sampleRate).rounded())
            return last > first ? first..<last : nil
        }
        queue.async {
            self.loopFrames = frames
            self.resetLoopPosition(self.nextFrame)
            // Top up a near-end queue immediately when Loop is enabled live.
            if frames != nil, self.running, !self.isPaused, self.engine.isRunning {
                let pcm = AVAudioFormat(standardFormatWithSampleRate: self.format.sampleRate, channels: AVAudioChannelCount(self.format.channels))!
                do {
                    while self.scheduled < self.bufferBlockCount {
                        let before = self.scheduled
                        try self.enqueue(format: pcm)
                        if self.scheduled == before { break }
                    }
                } catch { self.reportCompletion(error) }
            }
        }
    }
    func setMetronome(tempo: Double, enabled: Bool) {
        queue.async { self.tempo = tempo; self.metronomeEnabled = enabled }
    }
    func setMuted(_ muted: Bool, trackID: UUID) {
        queue.async { self.graph.setMuted(muted, trackID: trackID) }
    }
    func setSolo(_ ids: Set<UUID>) { queue.async { self.graph.setSolo(ids) } }
    func setTrackMix(_ track: Track) { queue.async { self.graph.setTrackMix(track) } }
    func configureLiveHosts(_ hosts: [SNPluginHost]) { queue.async { [self] in effectHosts = hosts } }
    private func configureEffects(position: Double, hosts: [SNPluginHost], tempo: Double, drainTimeline: Bool = false) throws {
        meterBuffer.clear()
        phase = .idleEffects; effectHosts = hosts
        // Stateful processors can flush/fade their lookahead on the playing
        // edge. Publish that edge before consuming their buffered timeline.
        for host in hosts { host.setTransportPlaying(false, position: Int64((position * format.sampleRate).rounded()), tempo: tempo) }
        graph.clearRoutingDelays()
        if drainTimeline { try graph.drainTimelineLatency() }
        metronomeEnabled = false; shuttleRenderer = nil
        outputQueue.reset()
        let stationary = ShuttleMotion(start: position, direction: 1, end: Double(Int.max / 4) / format.sampleRate, initialSpeed: 0, target: 0)
        control.update { $0.auditionPosition = position }
        transportLock.lock(); seekRequest = nil
        clock.segments.append((outputFrames, stationary)); transportLock.unlock()
        let pcm = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: AVAudioChannelCount(format.channels))!
        for _ in 0..<bufferBlockCount { try enqueue(format: pcm) }
        control.update { $0.effectsMetersReady = true }
    }
    func auditionEffects(at position: Double, hosts: [SNPluginHost], tempo: Double) {
        control.update { $0.auditionPosition = position; $0.effectsMetersReady = false }
        cancelReturn()
        // Flush already scheduled timeline PCM now, without waiting behind a
        // heavy plug-in block. Keep the hardware engine and processors alive.
        node.stop()
        queue.async { [self] in
            do {
                // An in-flight block may have scheduled once after the first
                // flush. The stopped node cannot play it; discard it here too.
                node.stop(); outputFrames = 0; meterBuffer.clear()
                transportLock.lock(); clock.reset(); transportLock.unlock()
                try configureEffects(position: position, hosts: hosts, tempo: tempo, drainTimeline: true)
                node.play()
            } catch { reportCompletion(error) }
        }
    }
    /// Called only by the preparation worker, with private/new graph ownership.
    func startEffects(at position: Double, hosts: [SNPluginHost], tempo: Double) throws {
        try queue.sync { try configureEffects(position: position, hosts: hosts, tempo: tempo) }
        engine.prepare(); try engine.start(); node.play()
    }
    func replaceEffectsGraph(_ graph: StreamingGraph, at position: Double, hosts: [SNPluginHost], tempo: Double) {
        queue.async { [self] in
            self.graph = graph; effectHosts = hosts
            control.update { $0.auditionPosition = position }
            for host in hosts { host.setTransportPlaying(false, position: Int64((position * format.sampleRate).rounded()), tempo: tempo) }
        }
    }
    func setEffectsPosition(_ position: Double, tempo: Double) {
        control.update { $0.auditionPosition = position }
        queue.async { [self] in
            for host in effectHosts { host.setTransportPlaying(false, position: Int64((position * format.sampleRate).rounded()), tempo: tempo) }
        }
    }
    func consumeEffectsPeaks() -> [UUID: StereoLevels] {
        let ready = control.snapshot.effectsMetersReady
        guard ready, node.isPlaying else { return [:] }
        guard let stamp = node.lastRenderTime, stamp.isSampleTimeValid || stamp.isHostTimeValid,
              let played = node.playerTime(forNodeTime: stamp), played.isSampleTimeValid, played.sampleRate > 0 else { return [:] }
        return meterBuffer.consume(through: Int((Double(played.sampleTime) * format.sampleRate / played.sampleRate).rounded()))
    }
    func stop() {
        control.update { $0.stopping = true }
        // Silence the node before waiting for a slow DSP block. Drain the
        // worker before the final flush/reset, so it cannot refill after Stop.
        cancelReturn(); node.stop()
        queue.sync { phase = .inactive; outputQueue.reset() }
        node.stop(); engine.stop()
        // Releasing hands processors to this worker. Drain a cancelled block
        // before another Play can begin using those same plug-in instances.
        returnQueue.sync {}
    }
    deinit { engine.stop() }
}
