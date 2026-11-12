import AVFoundation

func runPlaybackCoreTests() throws {
    func check(_ value: Bool, _ message: String) throws {
        guard value else { throw SounderError.message(message) }
        print("PASS: \(message)")
    }
    for capacity in [96, 1000, 1024, 4096, 32768] {
        let queue = PlaybackOutputQueue(capacity: capacity)
        let blocks = (0..<queue.blockCount).map { _ in queue.nextBlock() }
        try check(blocks.reduce(0, +) == capacity && blocks.count >= 3 && blocks.allSatisfy { (1...512).contains($0) }, "Shared output queue preserves exact capacity \(capacity)")
        let old = blocks.map { queue.register(frames: $0) }
        queue.consumed(old[0]) // Hardware consumption while the worker is blocked.
        try check(queue.fill.percent < 100 && queue.scheduled == blocks.count, "Consumption updates occupancy before worker completion")
        queue.reset()
        let current = queue.register(frames: blocks[0])
        let before = queue.fill.percent
        for ticket in old { queue.consumed(ticket); try check(!queue.complete(ticket), "Obsolete completion cannot refill a replacement queue") }
        try check(queue.scheduled == 1 && queue.fill.percent == before, "Old callbacks preserve new queue accounting")
        queue.consumed(current)
        try check(queue.complete(current) && queue.scheduled == 0 && queue.fill.percent == 0, "Current callback drains exactly its own queue")
    }
    try check(PlaybackOutputQueue.completionType(final: false, manual: false) == .dataConsumed &&
              PlaybackOutputQueue.completionType(final: true, manual: false) == .dataPlayedBack &&
              PlaybackOutputQueue.completionType(final: true, manual: true) == .dataRendered,
              "Only final boundaries wait for audible presentation")
    var clock = PlaybackClock()
    clock.renderedFrames = 1000
    clock.segments = [(0, ShuttleMotion(start: 2, direction: 1, end: 100, initialSpeed: 1, target: 1)),
                      (500, ShuttleMotion(start: 1, direction: 1, end: 100, initialSpeed: 1, target: 1))]
    clock.observe(400); clock.observe(nil); clock.observe(200)
    try check(clock.playedFrames == 400 && clock.position(at: 400, sampleRate: 1000, fallback: -1) == 2.4, "Missing or older stamps cannot move output time backward")
    clock.observe(9000)
    try check(clock.playedFrames == 1000 && clock.position(at: 1000, sampleRate: 1000, fallback: -1) == 1.5, "Clock bounds final output while mapping loop source time")
    clock.retainHistory(frames: 600)
    try check(clock.segments.count == 2, "Clock retains queued history for recording anchors")
    clock.reset()
    try check(clock.playedFrames == 0 && clock.renderedFrames == 0 && clock.segments.isEmpty, "Node restart resets the entire clock together")

    let meter = PlaybackMeterBuffer(), track = UUID()
    for frame in 0..<600 { meter.append(frame: frame, peaks: [track: StereoLevels(left: Float(frame), right: 0)]) }
    try check(meter.consume(through: 87).isEmpty && meter.consume(through: 100)[track]?.left == 100, "Meter ring retains bounded history in output order")
    try check(meter.consume(through: 599)[track]?.left == 599 && meter.consume(through: 600).isEmpty, "Meter ring emits every retained peak only once")
    meter.append(frame: 700, peaks: [track: StereoLevels(left: 1, right: 1)]); meter.clear()
    try check(meter.consume(through: 1000).isEmpty, "Meter reset discards stale transport peaks")

    var packets = RecordingPacketTimeline()
    try check(packets.place(offset: -100, frames: 64) == .init(padding: 0, skip: 64, remaining: 0), "Packet placement discards negative pre-roll")
    try check(packets.nextPacketFrame == -36 && packets.place(offset: -36, frames: 64) == .init(padding: 0, skip: 36, remaining: 28), "Untimestamped packet continues physical pre-roll interval")
    try check(packets.place(offset: 100, frames: 64) == .init(padding: 72, skip: 0, remaining: 64), "Packet gap inserts exact input-rate silence")
    try check(packets.place(offset: 140, frames: 64) == .init(padding: 0, skip: 24, remaining: 40), "Packet overlap retains each input frame once")

    let control = PlaybackTransportState()
    control.update { $0.intent = .pause }
    try check(control.snapshot.isPaused && control.snapshot.pausePosition == nil, "Pause intent precedes audible fade completion")
    control.update { $0.pause = .complete(3); $0.auditionPosition = 3 }
    control.update { $0.intent = .resume }
    try check(!control.snapshot.isPaused && control.snapshot.pausePosition == 3, "Resume intent preserves frozen time until queued boundary is ready")
    control.update { $0.stopping = true }
    try check(control.snapshot.stopping, "Stop cancellation is independent of the DSP worker")
    let cache = try ProcessedMixCache(channels: 2)
    let part = [Float](repeating: 0.25, count: 512 * 2)
    for index in 0..<8 { try cache.write(part, at: index * 512) }
    try check(cache.diskWrites == 1 && cache.frames == 4096, "Sequential cache blocks coalesce into one bounded disk write")
    try cache.write([0.5, -0.5], at: 5000)
    let latest = try cache.read(5000..<5001)
    try check(latest == [0.5, -0.5] && cache.cachedRegions(in: 4096..<5000).isEmpty, "Cache reads include staged PCM without marking skipped spans ready")
    try cache.write([0.75, -0.75], at: 0)
    let overwritten = try cache.read(0..<1)
    try check(overwritten == [0.75, -0.75], "Discontinuous cache writes replace exact absolute frames")
    try cache.write([1, 1], at: 10000); cache.invalidate()
    try cache.write([0.125, 0.125], at: 10000)
    let replacement = try cache.read(10000..<10001)
    try check(replacement == [0.125, 0.125] && cache.cachedRegions(in: 0..<10000).isEmpty, "Cache invalidation discards staged data and previous coverage")

}

/// Command sequences deliberately leave main-queue notifications pending.
/// They must not acquire ownership of a newer or stopped transport.
func runPlaybackTransitionTests() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SounderTransitions-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try AudioStore(directory: directory), source = store.freshURL()
    try store.write([Float](repeating: 0.2, count: 192000), to: source)
    let format = ProjectAudioFormat(bitDepth: 32)
    let project = Project(tracks: [Track(name: "Sequence", clips: [Clip(name: "Signal", source: source.path, start: 0, duration: 4, order: 1)])], audioFormat: format)
    for capacity in [96, 1000, 32768] {
        let graph = try StreamingGraph(project: project, store: store) { _ in fatalError("No effects") }
        let playback = LivePlayback(graph: graph, format: format, start: 0)
        try playback.configureBufferSize(capacity)
        let pcm = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        try playback.engine.enableManualRenderingMode(.offline, format: pcm, maximumFrameCount: 512)
        let buffer = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: 512)!
        let quantum = min(512, capacity / 3)
        try playback.startPlayback()
        var resumes = 0, pauses = 0
        playback.didResume = { resumes += 1 }; playback.didPause = { _ in pauses += 1 }
        try playback.pause()
        playback.seek(to: 1.25)
        playback.queue.sync {}
        try playback.resume(to: 1.25)
        // Supersede both callback generations before the main loop delivers them.
        try playback.pause()
        try playback.resume(to: 2)
        playback.stop()
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        guard resumes == 0, pauses == 0, !playback.isPlaying, playback.bufferFill.percent == 0 else {
            throw SounderError.message("Obsolete pause/resume notification survives Stop (queue \(capacity))")
        }
        let replacement = LivePlayback(graph: graph, format: format, start: 2)
        try replacement.configureBufferSize(capacity)
        try replacement.engine.enableManualRenderingMode(.offline, format: pcm, maximumFrameCount: 512)
        try replacement.startPlayback(continueEffects: true)
        defer { replacement.stop() }
        var peak: Float = 0
        for _ in 0..<12 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.002)); replacement.queue.sync {}
            guard try replacement.engine.renderOffline(AVAudioFrameCount(quantum), to: buffer) == .success else {
                throw SounderError.message("Replacement transport cannot render")
            }
            for i in 0..<quantum { peak = max(peak, abs(buffer.floatChannelData![0][i])) }
        }
        guard replacement.isPlaying, replacement.currentTime >= 2, peak > 0.1 else {
            throw SounderError.message("Stop/Play replacement loses source or clock")
        }
        print("PASS: Pause/Seek/Resume/Stop/Play rejects obsolete notifications and preserves new PCM/clock (\(capacity))")
    }
    let graph = try StreamingGraph(project: project, store: store) { _ in fatalError("No effects") }
    let playback = LivePlayback(graph: graph, format: format, start: 1)
    let pcm = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
    try playback.engine.enableManualRenderingMode(.offline, format: pcm, maximumFrameCount: 512)
    try playback.startPlayback()
    playback.beginShuttle(source: DryShuttleSource(project: project, store: store, processed: graph.outputCache, latency: graph.latency), direction: -1)
    playback.queue.sync {}
    let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), stopped = DispatchSemaphore(value: 0)
    var restored = false
    playback.restored = { _ in restored = true }
    playback.releaseShuttle { _ in entered.signal(); release.wait(); return graph }
    guard entered.wait(timeout: .now() + 2) == .success else { playback.stop(); throw SounderError.message("Shuttle return did not reach gate") }
    DispatchQueue.global(qos: .userInitiated).async { playback.stop(); stopped.signal() }
    let deadline = Date().addingTimeInterval(0.2)
    while playback.node.isPlaying && Date() < deadline { Thread.sleep(forTimeInterval: 0.001) }
    let silenced = !playback.node.isPlaying
    release.signal()
    guard stopped.wait(timeout: .now() + 2) == .success else { throw SounderError.message("Stop did not join cancelled shuttle return") }
    RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    guard silenced, !restored, !playback.returnReady, !playback.engine.isRunning else {
        throw SounderError.message("Cancelled shuttle return restarted or replaced stopped playback")
    }
    print("PASS: Stop silences immediately and rejects a blocked shuttle return")

}
