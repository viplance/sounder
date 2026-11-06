import AppKit
import AVFoundation

func runPerformanceTests() throws {
    func check(_ value: Bool, _ message: String) throws {
        guard value else { throw SounderError.message(message) }; print("PASS: \(message)")
    }
    func wait(_ predicate: () -> Bool, timeout: Double = 8) throws {
        let end = Date().addingTimeInterval(timeout)
        while !predicate(), Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.005)) }
        guard predicate() else { throw SounderError.message("Background playback preparation timed out") }
    }
    var cpu = ProcessCPUSampler()
    try check(cpu.sample(wall: 1, cpu: 0) == 0 && cpu.sample(wall: 3, cpu: 1) == 50 && cpu.sample(wall: 4, cpu: 3) == 200, "CPU uses measured process time, including multicore usage")
    let fill = AudioBufferFill()
    try check(fill.percent == 0, "Unprepared playback buffer reports zero")
    fill.update(filled: 2, capacity: 4); try check(fill.percent == 50, "Buffer reports actual prepared queue occupancy")
    fill.update(filled: 8, capacity: 4); try check(fill.percent == 100, "Buffer percentage is capped at full capacity")
    fill.reset()
    let generation = fill.enqueue(frames: 512, capacity: 1536)
    fill.consumed(frames: 512, generation: generation)
    try check(fill.percent == 0, "Audio consumption updates BUFFER without waiting for a busy DSP worker")
    fill.reset(); _ = fill.enqueue(frames: 1536, capacity: 1536)
    fill.consumed(frames: 512, generation: generation)
    try check(fill.percent == 100, "A stale consumed buffer cannot drain a newly prepared stream")
    let progress = PlaybackPreparation()
    progress.plan(frames: 1000); progress.advance(frames: 250)
    try check(progress.bufferPercent == 10, "Preparation progress comes from completed PCM work, not an animated timer")
    progress.advance(frames: 500)
    try check(progress.bufferPercent == 30, "Preparation reports intermediate values before the first playback buffer")
    progress.beginRendering(frames: 1000); progress.advance(frames: 250)
    try check(progress.bufferPercent == 53.75, "Slow VST warm-up has its own measured progress instead of inheriting 99% from source preparation")
    progress.advance(frames: 750)
    try check(progress.bufferPercent == 95, "Output is not advertised as 100% before its transport is ready")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SounderPreparation-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try AudioStore(directory: directory), source = store.freshURL()
    try store.write(AudioSignal(channels: [Array(repeating: 0.01, count: 144_000), Array(repeating: -0.01, count: 144_000)]), to: source)
    let gate = DispatchSemaphore(value: 0), entered = DispatchSemaphore(value: 0)
    let lock = NSLock(); var shouldWait = true, factoryRanOnMain = false
    let editor = Editor(store: store, makePlayback: { graph, format, start in
        lock.lock(); let hold = shouldWait; factoryRanOnMain = factoryRanOnMain || Thread.isMainThread; lock.unlock()
        if hold { entered.signal(); gate.wait() }
        return LivePlayback(graph: graph, format: format, start: start)
    })
    editor.preparesPlaybackInBackground = true
    editor.project.tracks[0].clips = [Clip(name: "Prepared", source: source.path, start: 0, duration: 3, order: 1)]
    editor.cursor = 0.25
    defer { gate.signal(); editor.preparesPlaybackInBackground = false; editor.stop() }
    let started = ProcessInfo.processInfo.systemUptime
    editor.playPause()
    try check(ProcessInfo.processInfo.systemUptime - started < 0.1 && editor.isPreparingPlayback && editor.busy && editor.player == nil && editor.bufferPercent < 100 && !editor.canRecord, "Play returns immediately while DSP/source preparation runs in the background")
    var workerBlocked = false
    try wait {
        if !workerBlocked { workerBlocked = entered.wait(timeout: .now()) == .success }
        return workerBlocked
    }
    var ticks = 0
    let timer = Timer(timeInterval: 0.005, repeats: true) { _ in ticks += 1 }
    RunLoop.main.add(timer, forMode: .common)
    RunLoop.current.run(until: Date().addingTimeInterval(0.08)); timer.invalidate()
    try check(ticks > 0 && workerBlocked, "Main run loop and indicator sampling remain responsive during a blocked preparation worker")
    try check(editor.bufferPercent > 0 && editor.bufferPercent < 100, "BUFFER exposes completed track/decode preparation before the audio queue is filled")
    editor.stopAndReturnToStart()
    try check(!editor.isPreparingPlayback && !editor.busy && editor.player == nil, "Stop cancels preparation immediately without waiting for DSP")
    lock.lock(); shouldWait = false; lock.unlock(); gate.signal()
    editor.cursor = 0.5; editor.playPause()
    try wait { editor.isPlaying }
    try check(editor.player?.start == 0.5 && !editor.isPreparingPlayback && !factoryRanOnMain, "Only the newest prepared transport starts at the selected cursor")
    try wait { editor.bufferPercent > 0 }
    try check(editor.bufferPercent <= 100, "Running playback publishes real buffer fill through a short snapshot lock")
    let player = editor.player
    editor.playPause()
    try wait { player?.isPlaying == false }
    editor.playPause()
    try wait { editor.isPlaying }
    try check(editor.player === player, "Background preparation preserves running-engine Space resume")
    let cached = editor.player!.graph.outputCache
    editor.stopAndReturnToStart()
    try check(editor.bufferPercent > 0 && editor.bufferPercent <= 40, "Stop retains cached source audio without falsely advertising ready live VST processors")
    editor.seek(to: 2.5)
    try check(editor.bufferPercent > 0 && editor.bufferPercent < 100, "Moving to an uncached position retains previously calculated PCM instead of resetting BUFFER")
    editor.seek(to: 0.5); editor.playPause(); try wait { editor.isPlaying }
    try check(editor.player?.graph.outputCache === cached, "A new Play reuses prepared track PCM and processed cache from the unchanged project")
    editor.stopAndReturnToStart()
    editor.renameProject("Invalidate cache")
    try check(editor.bufferPercent == 0, "Project edits invalidate stale cached readiness")
    let mono = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
    let recorderEditor = Editor(store: store, makeRecorder: { url, format in try LiveRecorder(url: url, format: format, inputFormat: mono) })
    recorderEditor.preparesPlaybackInBackground = true
    recorderEditor.project = editor.project; recorderEditor.selectedTrack = recorderEditor.project.tracks[0].id; recorderEditor.cursor = 0.75
    defer { recorderEditor.preparesPlaybackInBackground = false; recorderEditor.stop() }
    try recorderEditor.startRecording()
    try check(recorderEditor.isPreparingPlayback && !recorderEditor.isRecording, "Record prepares the backing mix off the UI thread before opening capture")
    try wait { recorderEditor.isRecording }
    try check(recorderEditor.isPlaying && recorderEditor.recordingStart >= 0.75 && recorderEditor.recorder?.format.channels == 1, "Prepared backing playback and mono capture start together")
    recorderEditor.recorder?.writer.append(captureTestBuffer(format: mono, start: 0, frames: 4800))
    recorderEditor.stop()
    try check(recorderEditor.project.tracks[0].clips.count == 2, "Background capture preparation retains the existing backing fragment")
    let ahead = Editor(store: store)
    ahead.project = editor.project; ahead.selectedTrack = ahead.project.tracks[0].id
    ahead.preparesPlaybackInBackground = true; ahead.update()
    defer { ahead.preparesPlaybackInBackground = false; ahead.stop() }
    try wait { ahead.standbyPlayer?.start == 0 }
    guard let ready = ahead.standbyPlayer else { throw SounderError.message("Idle prebuffer is missing") }
    let retained = ready.graph.outputCache
    try check(!ahead.isPlaying && !ahead.busy && ahead.canRecord && ahead.bufferPercent == 100, "Stopped project prebuffers silently without disabling editing or Record")
    let click = ProcessInfo.processInfo.systemUptime
    ahead.playPause()
    try check(ahead.player === ready && ahead.isPlaying && !ahead.isPreparingPlayback && ProcessInfo.processInfo.systemUptime - click < 0.1, "Play consumes the already prepared engine and buffers without rebuilding DSP")
    ahead.stopAndReturnToStart(); ahead.seek(to: 2)
    try check(ahead.bufferPercent > 0, "Stop and moving the playhead preserve previously cached audio")
    try wait { ahead.standbyPlayer?.start == 2 }
    try check(ahead.standbyPlayer?.graph.outputCache === retained && ahead.bufferPercent == 100, "Moving while stopped proactively prepares the new position while retaining earlier cache regions")
    ahead.seek(to: 0); try wait { ahead.standbyPlayer?.start == 0 }
    try check(!retained.cachedRegions(in: 0..<1536).isEmpty && !retained.cachedRegions(in: 96_000..<97_536).isEmpty, "Both visited positions remain in the same processed PCM cache")
    _ = ahead.setTrackMix(ahead.project.tracks[0].id, volumeDB: -6)
    try wait { ahead.standbyPlayer?.start == 0 }
    guard let edited = ahead.standbyPlayer else { throw SounderError.message("Edited prebuffer is missing") }
    let mixed = try edited.graph.outputCache.read(1000..<1001)
    try check(edited.graph.outputCache !== retained && abs(mixed[0] - Float(0.01 * pow(10, -6.0 / 20))) < 0.00001 && !ahead.busy,
              "Editing proactively rebuilds the buffer with the new actual gain, without autoplay or stale cache reuse")
    ahead.undo(); try wait { ahead.standbyPlayer?.start == 0 }
    ahead.seek(to: 0.25); ahead.seek(to: 1.5); ahead.seek(to: 2.25)
    try wait { ahead.standbyPlayer?.start == 2.25 }
    let stopped = ahead.standbyPlayer; ahead.stop()
    try check(ahead.standbyPlayer === stopped && ahead.bufferPercent == 100 && !ahead.isPlaying, "Rapid stopped seeks prepare only the latest cursor and Stop preserves a ready standby buffer")
    let idleGate = DispatchSemaphore(value: 0), idleEntered = DispatchSemaphore(value: 0)
    var factoryCalls = 0
    let promoted = Editor(store: store, makePlayback: { graph, format, start in
        lock.lock(); factoryCalls += 1; lock.unlock()
        idleEntered.signal(); idleGate.wait()
        return LivePlayback(graph: graph, format: format, start: start)
    })
    promoted.project = editor.project; promoted.preparesPlaybackInBackground = true; promoted.update()
    defer { idleGate.signal(); promoted.preparesPlaybackInBackground = false; promoted.stop() }
    var blocked = false
    try wait { if !blocked { blocked = idleEntered.wait(timeout: .now()) == .success }; return blocked }
    try check(promoted.isPrebuffering && !promoted.busy, "Speculative buffer calculation leaves editor actions available")
    promoted.playPause()
    try check(promoted.isPreparingPlayback, "Play promotes an in-flight speculative calculation instead of restarting it")
    idleGate.signal(); try wait { promoted.isPlaying }
    lock.lock(); let calls = factoryCalls; lock.unlock()
    try check(calls == 1, "Promotion starts exactly one prepared transport")
    let dspGate = DispatchSemaphore(value: 0), dspEntered = DispatchSemaphore(value: 0)
    var blockDSP = false, heavyFactories = 0
    let heavySources = store.cache
    let expensive = Editor(store: store, makePlayback: { _, format, start in
        lock.lock(); heavyFactories += 1; lock.unlock()
        var snapshot = editor.project
        snapshot.tracks[0].effects = [PluginEffect(name: "Heavy test DSP", path: "synthetic.vst3", classID: "test")]
        let heavyStore = try AudioStore(directory: directory); heavyStore.configure(format); heavyStore.cache = heavySources
        let graph = try StreamingGraph(project: snapshot, store: heavyStore) { _ in
            StreamingEffect(latency: 1024, tail: 0) { samples in
                lock.lock(); let hold = blockDSP; blockDSP = false; lock.unlock()
                if hold { dspEntered.signal(); dspGate.wait() }
                return samples
            }
        }
        return LivePlayback(graph: graph, format: format, start: start)
    })
    expensive.project = editor.project; expensive.preparesPlaybackInBackground = true; expensive.update()
    defer { dspGate.signal(); expensive.preparesPlaybackInBackground = false; expensive.stop() }
    try wait { expensive.standbyPlayer != nil }
    lock.lock(); blockDSP = true; lock.unlock()
    expensive.seek(to: 1.5)
    var dspBlocked = false
    try wait { if !dspBlocked { dspBlocked = dspEntered.wait(timeout: .now()) == .success }; return dspBlocked }
    try check(expensive.bufferPercent <= 40 && expensive.bufferPercent > 0 && expensive.standbyPlayer == nil,
              "Previously cached PCM cannot mask a blocked heavy VST warm-up with 99% or 100% readiness")
    expensive.playPause()
    try check(expensive.isPreparingPlayback && !expensive.isPlaying && expensive.bufferPercent < 95,
              "Play continues the same heavy preparation while showing its actual unfinished DSP stage")
    dspGate.signal(); try wait { expensive.isPlaying }
    expensive.stopAndReturnToStart(); try wait { expensive.standbyPlayer?.start == 1.5 }
    guard let heavyReady = expensive.standbyPlayer else { throw SounderError.message("Heavy VST standby is absent") }
    lock.lock(); let beforeClick = heavyFactories; lock.unlock()
    let heavyClick = ProcessInfo.processInfo.systemUptime
    expensive.playPause()
    lock.lock(); let afterClick = heavyFactories; lock.unlock()
    try check(expensive.player === heavyReady && beforeClick == afterClick && ProcessInfo.processInfo.systemUptime - heavyClick < 0.1,
              "A truthful 100% starts the exact warmed heavy VST transport without any new factory or warm-up")
    let failureEditor = Editor(store: store, makePlayback: { _, _, _ in throw SounderError.message("Expected preparation failure") })
    failureEditor.project = editor.project; failureEditor.preparesPlaybackInBackground = true
    failureEditor.playPause(); try wait { !failureEditor.isPreparingPlayback }
    try check(!failureEditor.busy && failureEditor.player == nil && failureEditor.bufferPercent == 0, "Preparation failures release busy state and never start stale audio")
}

extension AppDelegate {
    private func verifyUnchangedPluginReadiness(path: String) throws {
        let host = try SNPluginHost(path: path, classID: "", state: nil)
        let fx = PluginEffect(name: host.pluginName, path: path, classID: host.classID, state: try host.saveState())
        let local = Editor(store: editor.audio)
        local.project = editor.project; local.project.tracks[0].effects = [fx]; local.pluginHosts[fx.id] = host
        local.preparesPlaybackInBackground = true; local.update()
        defer { local.preparesPlaybackInBackground = false; local.stop() }
        let deadline = Date().addingTimeInterval(15)
        while local.standbyPlayer == nil, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        guard let ready = local.standbyPlayer else { throw SounderError.message("Native VST readiness timed out") }
        let window = PluginEditorWindow(host: host, editor: local, effectID: fx.id)
        window.lastParameters = []; window.lastRevision = host.editRevision; window.lastLatency = host.latency
        window.captureChanges()
        guard local.standbyPlayer === ready, local.bufferPercent == 100 else { throw SounderError.message("An unchanged VST poll discarded its ready transport") }
        for _ in 0..<5 { window.captureChanges() }
        guard local.standbyPlayer === ready else { throw SounderError.message("Repeated VST polls invalidated cached readiness") }
        print("PASS: Actual VST editor snapshots preserve the same 100% ready transport when saved settings have not changed")
        if let parameter = host.parameters().first, let id = parameter["index"] as? NSNumber, let value = parameter["value"] as? NSNumber {
            let before = local.project.tracks[0].effects[0].state
            host.setParameter(id.intValue, value: value.doubleValue < 0.5 ? 0.75 : 0.25)
            window.captureChanges()
            guard local.standbyPlayer == nil, local.project.tracks[0].effects[0].state != before else { throw SounderError.message("Actual VST edits did not invalidate the ready DSP buffer") }
            print("PASS: A genuine native VST parameter edit still captures state and invalidates outdated readiness")
        }
    }
    func verifyPerformanceUI() throws {
        try runPerformanceTests()
        if let index = CommandLine.arguments.firstIndex(of: "--performance-plugin-ui-test"), index + 1 < CommandLine.arguments.count {
            try verifyUnchangedPluginReadiness(path: CommandLine.arguments[index + 1])
        }
        performanceIndicators.layoutSubtreeIfNeeded()
        let cpu = performanceIndicators.cpu.convert(performanceIndicators.cpu.bounds, to: window.contentView)
        let buffer = performanceIndicators.buffer.convert(performanceIndicators.buffer.bounds, to: window.contentView)
        guard cpu.minX < buffer.minX, performanceIndicators.frame.width > 100,
              cpu.midY == buffer.midY, buffer.maxX < window.contentView!.bounds.maxX else { throw SounderError.message("CPU/BUFFER layout is invalid") }
        let background = editor.preparesPlaybackInBackground, cursor = editor.cursor
        defer { editor.stop(); editor.cursor = cursor; editor.preparesPlaybackInBackground = background; refresh() }
        editor.preparesPlaybackInBackground = true
        editor.cursor = 1.25; editor.playPause()
        var samples = Set<Int>()
        let deadline = Date().addingTimeInterval(15)
        while editor.isPreparingPlayback, Date() < deadline {
            performanceIndicators.refresh(); samples.insert(Int(editor.bufferPercent))
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        guard editor.isPlaying, let cached = editor.player?.graph.outputCache else { throw SounderError.message("Interactive background playback failed") }
        editor.stopAndReturnToStart()
        while editor.standbyPlayer?.start != editor.cursor, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        performanceIndicators.refresh()
        guard performanceIndicators.buffer.stringValue == "100%" else { throw SounderError.message("BUFFER lost cached readiness after Stop: label=\(performanceIndicators.buffer.stringValue), actual=\(editor.bufferPercent), cursor=\(editor.cursor), start=\(String(describing: editor.lastPlaybackStart)), regions=\(cached.cachedRegions(in: 0..<cached.frames))") }
        editor.playPause()
        while editor.isPreparingPlayback, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        guard editor.player?.graph.outputCache === cached else { throw SounderError.message("Interactive Play discarded the processed cache") }
        editor.stopAndReturnToStart(); performanceIndicators.refresh()
        print("PASS: Interactive BUFFER sampled real preparation values \(samples.sorted()) and retained 100% readiness after Stop/replay")
        print("PASS: CPU/BUFFER appear on the right of the toolbar with aligned percentage readouts")
    }
}
