import AppKit
import AVFoundation

extension AppDelegate {
    func verifyCanvasCompositionUI() throws {
        let content = window.contentView!
        content.layoutSubtreeIfNeeded(); timeline.refresh(); content.displayIfNeeded()
        let clip = timeline.clipRect(editor.project.tracks[0].clips[0], row: 0, layer: 0)
        let point = timeline.convertDocumentPoint(NSPoint(x: clip.minX + 18, y: clip.midY + 5), to: content)
        guard let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { throw SounderError.message("Cannot capture canvas composition") }
        content.cacheDisplay(in: content.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsWide) / content.bounds.width
        let y = content.isFlipped ? point.y : content.bounds.maxY - point.y
        let color = bitmap.colorAt(x: Int(point.x * scale), y: Int(y * scale))!.usingColorSpace(.deviceRGB)!
        guard color.greenComponent - color.redComponent > 0.04 else { throw SounderError.message("Pinned overlay covers the stopped fragment canvas: \(color)") }
        print("PASS: The stopped window composites fragment pixels through the pinned overlay")
    }

    func verifyScrollTilesUI() throws {
        func check(_ condition: Bool, _ message: String) throws {
            guard condition else { throw SounderError.message(message) }; print("PASS: \(message)")
        }
        let surface = TimelineScrollSurface(frame: NSRect(x: 0, y: 0, width: 900, height: 200))
        window.contentView!.addSubview(surface)
        defer { surface.removeFromSuperview() }
        var bodyColor = NSColor.blue
        surface.paint = { rect, ruler in
            fill(rect, ruler ? .green : bodyColor)
            if !ruler {
                fill(NSRect(x: 0, y: 142, width: 10_000, height: 16), .red)
                fill(NSRect(x: 1300, y: 0, width: 16, height: 10_000), .white)
            }
        }
        func present(_ x: CGFloat) { surface.present(viewport: NSRect(x: x, y: 100, width: 900, height: 200), headerWidth: 220, rulerHeight: 42) }
        func pixel(_ point: NSPoint) throws -> NSColor {
            let scale = window.backingScaleFactor
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(surface.bounds.width * scale), pixelsHigh: Int(surface.bounds.height * scale), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                  let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else { throw SounderError.message("Cannot capture scroll tiles") }
            graphics.cgContext.translateBy(x: 0, y: CGFloat(bitmap.pixelsHigh))
            graphics.cgContext.scaleBy(x: scale, y: -scale)
            surface.layer!.render(in: graphics.cgContext)
            return bitmap.colorAt(x: Int(point.x * scale), y: Int(point.y * scale))!.usingColorSpace(.deviceRGB)!
        }
        present(900)
        let top = try pixel(NSPoint(x: 450, y: 50)), bottom = try pixel(NSPoint(x: 450, y: 180))
        let ruler = try pixel(NSPoint(x: 450, y: 20)), stripe = try pixel(NSPoint(x: 405, y: 100))
        try check(top.redComponent > 0.9 && bottom.blueComponent > 0.9 && ruler.greenComponent > 0.9 && stripe.redComponent > 0.9 && stripe.greenComponent > 0.9,
                  "Scroll tiles preserve vertical image orientation, ruler placement and document-to-viewport translation (\(top), \(bottom), \(ruler), \(stripe))")
        let builds = surface.tileBuildCount
        present(920)
        try check(surface.tileBuildCount == builds, "Sub-tile scroll translates cached layers without repainting")
        present(1150)
        try check(surface.tileBuildCount == builds + 1 && surface.retainedTileCount <= 3,
                  "Crossing a tile boundary renders only the entering tile and bounds retained memory")
        bodyColor = .yellow; surface.invalidateTiles(); present(1150)
        let updated = try pixel(NSPoint(x: 600, y: 100))
        try check(updated.redComponent > 0.9 && updated.greenComponent > 0.9 && updated.blueComponent < 0.1,
                  "Invalidation replaces stale scroll pixels after content changes (\(updated))")
    }

    func verifyMeterLayersUI() throws {
        func check(_ condition: Bool, _ message: String) throws {
            guard condition else { throw SounderError.message(message) }; print("PASS: \(message)")
        }
        // Use an isolated real control: changing signal levels must not invalidate
        // the native thumb, while changing the fader must still redraw it.
        let meter = MixerVolumeControl(frame: NSRect(x: 20, y: 20, width: 200, height: 28))
        window.contentView!.addSubview(meter)
        meter.layoutSubtreeIfNeeded(); meter.displayIfNeeded()
        func drawSlider() throws {
            guard let image = meter.slider.bitmapImageRepForCachingDisplay(in: meter.slider.bounds) else { throw SounderError.message("Cannot render native volume thumb") }
            meter.slider.cacheDisplay(in: meter.slider.bounds, to: image)
        }
        try drawSlider()
        let cell = meter.slider.cell as! TrackVolumeMeterCell
        let before = cell.knobDrawCount
        let originalThumb = cell.displayedKnobRect(flipped: meter.slider.isFlipped)
        for index in 1...25 {
            var signal = StereoTrackLevelMeter()
            signal.update(StereoLevels(left: Float(index) / 25, right: Float(index) / 50), at: Double(index))
            meter.updateMeter(signal, active: true, recording: index > 20, showsPeaks: true)
            meter.displayIfNeeded()
        }
        try check(cell.knobDrawCount == before && !meter.slider.needsDisplay,
                  "Stereo playback/recording meter ticks do not redraw the native volume thumb")
        meter.slider.doubleValue = -12; try drawSlider()
        try check(before > 0 && cell.knobDrawCount > before && cell.displayedKnobRect(flipped: meter.slider.isFlipped).midX < originalThumb.midX,
                  "Native volume thumb still redraws at the new position after a fader change")
        var signal = StereoTrackLevelMeter()
        signal.update(StereoLevels(left: 1, right: 0), at: 100)
        meter.updateMeter(signal, active: true, recording: false, showsPeaks: true)
        let rail = meter.subviews.compactMap { $0 as? MixerMeterRail }.first!
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(rail.bounds.width * 2), pixelsHigh: Int(rail.bounds.height * 2), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!.cgContext
        context.scaleBy(x: 2, y: 2)
        rail.layer!.render(in: context)
        let bar = cell.barRect(flipped: meter.slider.isFlipped)
        let x = Int(bar.midX * 2), top = Int((bar.midY - 1.75) * 2), bottom = Int((bar.midY + 1.75) * 2)
        let left = bitmap.colorAt(x: x, y: top)!.usingColorSpace(.deviceRGB)!
        let right = bitmap.colorAt(x: x, y: bottom)!.usingColorSpace(.deviceRGB)!
        try check(left.greenComponent > left.redComponent + 0.1 && left.alphaComponent > 0.9 && right.alphaComponent < 0.3,
                  "Rendered stereo layers put the turquoise left channel above the silent right channel")
        meter.updateMeter(signal, active: true, recording: true, showsPeaks: true)
        context.clear(rail.bounds); rail.layer!.render(in: context)
        let recording = bitmap.colorAt(x: x, y: top)!.usingColorSpace(.deviceRGB)!
        try check(recording.redComponent > recording.greenComponent + 0.2,
                  "Recording uses the same proportional meter layer with red fill")
        meter.updateMeter(signal, active: false, recording: false, showsPeaks: true)
        context.clear(rail.bounds); rail.layer!.render(in: context)
        try check(bitmap.colorAt(x: x, y: top)!.alphaComponent < 0.3 && bitmap.colorAt(x: x, y: bottom)!.alphaComponent < 0.3,
                  "Stop clears both rendered meter fills without redrawing the native thumb")
        meter.removeFromSuperview()
        let cursor = editor.cursor
        defer { editor.cursor = cursor; timeline.presentTransportFrame() }
        timeline.presentTransportFrame()
        let surface = timeline.playheadSurfaceFrame
        for time in [0.25, 0.5, 1.0, 1.5] {
            editor.cursor = time; timeline.presentTransportFrame()
            try check(timeline.playheadSurfaceFrame == surface && abs(timeline.playheadFrame.midX - (timeline.header + time * editor.zoom)) < 0.001,
                      "Moving the playhead updates its visual position without moving the AppKit surface")
        }
        timeline.centerOnPlayhead(); timeline.presentTransportFrame()
        let capRect = NSRect(x: timeline.playheadFrame.midX - 4, y: timeline.viewportRect.minY, width: 8, height: 8)
        let content = window.contentView!, crop = timeline.convert(capRect, to: window.contentView)
        guard let capImage = content.bitmapImageRepForCachingDisplay(in: crop) else { throw SounderError.message("Cannot render the playhead cap") }
        content.cacheDisplay(in: crop, to: capImage)
        let cap = capImage.colorAt(x: capImage.pixelsWide * 3 / 4, y: capImage.pixelsHigh / 4)!.usingColorSpace(.deviceRGB)!
        try check(cap.greenComponent > cap.redComponent + 0.1,
                  "The rendered playhead cap stays at the top of the timeline")
    }

    /// Reproducible real-device workload for sample/Instruments, excluding import/preparation.
    func playbackCPUProfile(path: String) {
        do {
            let audio = try editor.audio.load(path)
            editor.preparesPlaybackInBackground = false
            editor.project = Project(tracks: [Track(name: "CPU reference", clips: [
                Clip(name: URL(fileURLWithPath: path).lastPathComponent, source: path, start: 0,
                     duration: Double(audio.frameCount) / editor.project.audioFormat.sampleRate, order: 1)
            ])])
            // Start within long recordings so the visible phase measures
            // continuous follow, rather than mostly a stationary viewport.
            editor.cursor = min(30, max(0, editor.duration - 12)); refresh(); timeline.centerOnPlayhead()
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.level = .floating
            window.deminiaturize(nil); window.orderFrontRegardless(); NSApp.activate(ignoringOtherApps: true)
            editor.playPause()
            var sampler = ProcessCPUSampler(); _ = sampler.sample()
            var tick = 0
            print("PROFILE BEGIN: visible playback"); fflush(stdout)
            let timer = Timer(timeInterval: 1, repeats: true) { timer in
                let phase = tick < 12 ? "visible playback" : tick < 24 ? "hidden playback" : "stopped"
                print(String(format: "PROFILE %@ CPU %.2f%% cursor %.3f frames %d visible %d occlusion %lu paused %d", phase, sampler.sample(), self.editor.cursor, self.transportFrameCount, self.window.isVisible ? 1 : 0, self.window.occlusionState.rawValue, self.transportDisplayIsPaused ? 1 : 0)); fflush(stdout)
                tick += 1
                if tick == 12 { self.window.miniaturize(nil); print("PROFILE BEGIN: hidden playback") }
                if tick == 24 { self.editor.stop(); self.window.deminiaturize(nil); self.window.makeKeyAndOrderFront(nil); print("PROFILE BEGIN: stopped") }
                if tick == 36 { timer.invalidate(); self.editor.stop(); NSApp.terminate(nil) }
                fflush(stdout)
            }
            RunLoop.main.add(timer, forMode: .common)
        } catch { print("PROFILE FAILED: \(error)"); fflush(stdout); NSApp.terminate(nil) }
    }
}

func runPerformanceTests() throws {
    func check(_ value: Bool, _ message: String) throws {
        guard value else { throw SounderError.message(message) }; print("PASS: \(message)")
    }
    func wait(_ predicate: () -> Bool, timeout: Double = 8) throws {
        let end = Date().addingTimeInterval(timeout)
        while !predicate(), Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.005)) }
        guard predicate() else { throw SounderError.message("Background playback preparation timed out") }
    }
    for cores in [1, 4, 8] {
        var cpu = ProcessCPUSampler()
        try check(cpu.sample(wall: 1, cpu: 0, processorCount: cores) == 0 &&
                  cpu.sample(wall: 2, cpu: 1, processorCount: cores) == 100 / Double(cores) &&
                  cpu.sample(wall: 3, cpu: Double(cores + 1), processorCount: cores) == 100 &&
                  cpu.sample(wall: 4, cpu: Double(cores * 3 + 1), processorCount: cores) == 100 &&
                  cpu.sample(wall: 5, cpu: Double(cores * 3 + 1), processorCount: cores) == 0,
                  "CPU is normalized to all \(cores) logical CPUs and stays within 0–100%")
    }
    let fill = AudioBufferFill()
    var average = BufferFillAverage()
    try check(average.sample(100, at: 0) == 100 && average.sample(0, at: 0.25) == 50 &&
              average.sample(50, at: 0.5) == 50 && average.sample(50, at: 1) == 100.0 / 3,
              "BUFFER averages observations within the last second without inventing startup samples")
    try check(average.sample(100, at: 1.01) == 50 && average.sample(25, at: 3) == 25,
              "Extra UI refreshes share a sample and stale observations expire after a polling gap")
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
    for rate in [44_100.0, 48_000, 96_000, 192_000] {
        var project = Project(); project.audioFormat.sampleRate = rate
        try check(project.playbackBufferSize == 1024, "Initial buffer is 1024 samples at \(Int(rate)) Hz")
    }
    for invalid in [-1, 0, 80, 95, 32769, Int.max] {
        var rejected = false
        do { try PlaybackBufferSize.validate(invalid) } catch { rejected = true }
        try check(rejected, "Buffer rejects invalid size \(invalid)")
    }
    let bufferEditor = Editor(store: store)
    var validPlans = true
    for size in PlaybackBufferSize.minimum...PlaybackBufferSize.maximum {
        let blocks = PlaybackBufferSize.blocks(frames: size)
        validPlans = validPlans && blocks.count >= 3 && blocks.reduce(0, +) == size && blocks.allSatisfy { $0 > 0 && $0 <= 512 }
    }
    try check(validPlans, "Every integer buffer size has an exact queue plan without sample rounding")
    for size in [96, 97, 511, 512, 1537, 4096, 32768] {
        try bufferEditor.setPlaybackBufferSize(size)
        let restored = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(bufferEditor.project))
        try check(restored.playbackBufferSize == size, "Project round-trip retains \(size) playback buffer samples")
    }
    bufferEditor.undo()
    try check(bufferEditor.project.playbackBufferSize == 4096, "Buffer edits support Undo")
    let suite = "SounderBufferTests." + UUID().uuidString
    let preferences = UserDefaults(suiteName: suite)!
    defer { preferences.removePersistentDomain(forName: suite) }
    let savedDefault = Editor(store: store, preferences: preferences)
    try check(savedDefault.project.playbackBufferSize == 1024, "New installations begin with a 1024-sample buffer")
    try savedDefault.setPlaybackBufferSize(513)
    try check(Editor(store: store, preferences: preferences).project.playbackBufferSize == 1024, "Unsaved project edits do not replace the saved default")
    try savedDefault.save(to: directory.appendingPathComponent("Buffer.sounder"))
    try check(Editor(store: store, preferences: preferences).project.playbackBufferSize == 513, "Successful project Save remembers an exact unaligned size for new projects")
    var older = Project(); older.playbackBufferFrames = 1025
    let olderURL = directory.appendingPathComponent("Older.sounder")
    _ = try ProjectStorage.save(older, to: olderURL)
    try savedDefault.open(from: olderURL)
    try check(savedDefault.project.playbackBufferSize == 1025 && Editor(store: store, preferences: preferences).project.playbackBufferSize == 513,
              "Opening an existing project restores its own buffer without overwriting the new-project default")
    try savedDefault.setPlaybackBufferSize(1001)
    var failedSave = false
    do { try savedDefault.save(to: directory) } catch { failedSave = true }
    try check(failedSave && Editor(store: store, preferences: preferences).project.playbackBufferSize == 513, "A failed project Save cannot change the remembered default")
    try store.write(AudioSignal(channels: [Array(repeating: 0.01, count: 144_000), Array(repeating: -0.01, count: 144_000)]), to: source)
    let gate = DispatchSemaphore(value: 0), entered = DispatchSemaphore(value: 0)
    let lock = NSLock(); var shouldWait = true, factoryRanOnMain = false
    let editor = Editor(store: store, makePlayback: { graph, format, start in
        lock.lock(); let hold = shouldWait; factoryRanOnMain = factoryRanOnMain || Thread.isMainThread; lock.unlock()
        if hold { entered.signal(); gate.wait() }
        return LivePlayback(graph: graph, format: format, start: start)
    })
    try editor.setPlaybackBufferSize(96)
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
    try check(editor.player?.bufferFrameCount == 96, "Background playback applies the real two-millisecond queue size")
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
    let probe = min(1000, edited.bufferFrameCount - 1)
    let mixed = try edited.graph.outputCache.read(probe..<(probe + 1))
    let original = try retained.read(probe..<(probe + 1))
    try check(edited.graph.outputCache !== retained && abs(mixed[0] - original[0] * Float(pow(10, -6.0 / 20))) < 0.00001 && !ahead.busy,
              "Editing proactively rebuilds the buffer with the new actual gain, without autoplay or stale cache reuse")
    ahead.undo(); try wait { ahead.standbyPlayer?.start == 0 }
    ahead.seek(to: 0.25); ahead.seek(to: 1.5); ahead.seek(to: 2.25)
    try wait { ahead.standbyPlayer?.start == 2.25 }
    let stopped = ahead.standbyPlayer; ahead.stop()
    try check(ahead.standbyPlayer === stopped && ahead.bufferPercent == 100 && !ahead.isPlaying, "Rapid stopped seeks prepare only the latest cursor and Stop preserves a ready standby buffer")
    // Hold a real preparation result while changing every track-header choice.
    // Both silent prebuffering and a pending user Play must replace the old job.
    for foreground in [false, true] {
        let editGate = DispatchSemaphore(value: 0), editEntered = DispatchSemaphore(value: 0)
        var editFactories = 0
        let editing = Editor(store: store, makePlayback: { graph, format, start in
            lock.lock(); editFactories += 1; let first = editFactories == 1; lock.unlock()
            if first { editEntered.signal(); editGate.wait() }
            let live = LivePlayback(graph: graph, format: format, start: start)
            try live.engine.enableManualRenderingMode(.offline,
                format: AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: AVAudioChannelCount(format.channels))!, maximumFrameCount: 512)
            return live
        })
        let effect = PluginEffect(name: "Individually bypassed", path: "/unused", classID: "", bypassed: true)
        let first = Track(name: "Header edits", clips: [Clip(name: "Source", source: source.path, start: 0, duration: 3, order: 1)], effects: [effect])
        let second = Track(name: "Solo destination")
        editing.project = Project(tracks: [first, second]); editing.selectedTrack = first.id
        editing.preparesPlaybackInBackground = true; editing.update()
        defer { editGate.signal(); editing.preparesPlaybackInBackground = false; editing.stop() }
        if foreground { editing.playPause() }
        var held = false
        try wait { if !held { held = editEntered.wait(timeout: .now()) == .success }; return held }
        let controls = TrackMixerControls(track: first, editor: editing)
        try check(controls.rec.isEnabled && controls.fx.isEnabled && controls.fx.power.isEnabled && editing.canEditEffects,
                  "REC and both FX actions remain enabled during \(foreground ? "foreground" : "idle") buffer preparation")
        let began = ProcessInfo.processInfo.systemUptime
        controls.rec.performClick(nil)
        editing.toggleMute(first.id); editing.toggleSolo(second.id)
        controls.fx.power.performClick(nil)
        controls.configure(editing.project.tracks[0])
        try check(ProcessInfo.processInfo.systemUptime - began < 0.5 && controls.rec.isEnabled && controls.fx.isEnabled &&
                  editing.project.tracks[0].recordArmed && editing.project.tracks[0].muted && editing.project.tracks[1].solo && editing.project.tracks[0].effectsBypassed,
                  "REC/MUTE/SOLO/FX apply without waiting for blocked buffer work and remain clickable")
        try check(editing.isPreparingPlayback == foreground && !editing.isPlaying,
                  "Track-header invalidation retains pending Play while idle preparation remains silent")
        editGate.signal()
        try wait { foreground ? editing.isPlaying : editing.standbyPlayer != nil }
        lock.lock(); let count = editFactories; lock.unlock()
        guard let prepared = editing.player ?? editing.standbyPlayer else { throw SounderError.message("Missing rebuilt header-edit buffer") }
        let samples = try prepared.graph.outputCache.read(0..<96)
        try check(count == 2 && samples.allSatisfy { $0 == 0 } && editing.isPlaying == foreground,
                  "Cancelled buffer never activates; replacement reflects the latest Mute/Solo/FX/REC choices and playback intent")
        editing.preparesPlaybackInBackground = false; editing.stop()
    }
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
    let originalStart = expensive.lastPlaybackStart
    lock.lock(); blockDSP = true; lock.unlock()
    expensive.effectsChanged()
    var rebuildBlocked = false
    try wait { if !rebuildBlocked { rebuildBlocked = dspEntered.wait(timeout: .now()) == .success }; return rebuildBlocked }
    let rebuildPosition = expensive.cursor
    // Native plug-ins can publish saved state/latency after the chain edit has
    // already started a costly warm-up. Checkpoint invalidates that first job.
    expensive.invalidateMixCache(); expensive.checkpoint()
    expensive.project.masterVolumeDB = -4; expensive.update()
    expensive.effectsChanged()
    try check(expensive.isPreparingPlayback && expensive.cursor == rebuildPosition,
              "FX state/checkpoint invalidation retains pending Play through repeated heavy graph rebuilds")
    dspGate.signal(); try wait { expensive.isPlaying }
    try check(abs((expensive.player?.start ?? -1) - rebuildPosition) < 1 / store.sampleRate && expensive.lastPlaybackStart == originalStart,
              "Playback resumes automatically at the retained position after FX rebuild without moving the last-start notch")
    lock.lock(); blockDSP = true; lock.unlock()
    expensive.effectsChanged()
    var cancelRebuildBlocked = false
    try wait { if !cancelRebuildBlocked { cancelRebuildBlocked = dspEntered.wait(timeout: .now()) == .success }; return cancelRebuildBlocked }
    expensive.checkpoint(); expensive.project.masterVolumeDB = -6; expensive.effectsChanged()
    expensive.stop(); dspGate.signal()
    try wait { expensive.standbyPlayer != nil }
    try check(!expensive.isPlaying && !expensive.isPreparingPlayback,
              "Explicit Stop during an invalidated FX rebuild cancels autoplay; idle preparation stays silent")
    let seekGate = DispatchSemaphore(value: 0), seekEntered = DispatchSemaphore(value: 0)
    let seeking = Editor(store: store, makePlayback: { graph, format, start in
        if start == 0.25 { seekEntered.signal(); seekGate.wait() }
        return LivePlayback(graph: graph, format: format, start: start)
    })
    seeking.project = editor.project; seeking.preparesPlaybackInBackground = true; seeking.cursor = 0.25
    defer { seekGate.signal(); seeking.preparesPlaybackInBackground = false; seeking.stop() }
    seeking.playPause()
    var seekWorkerBlocked = false
    try wait {
        if !seekWorkerBlocked { seekWorkerBlocked = seekEntered.wait(timeout: .now()) == .success }
        return seekWorkerBlocked
    }
    let seekStarted = ProcessInfo.processInfo.systemUptime
    seeking.seek(to: 1); seeking.seek(to: 1.5)
    try check(ProcessInfo.processInfo.systemUptime - seekStarted < 0.1 && seeking.cursor == 1.5 && seeking.isPreparingPlayback && seeking.player == nil,
              "Seeking during buffer preparation immediately moves the cursor and replaces pending work without waiting")
    seekGate.signal()
    try wait { seeking.isPlaying }
    try check(seeking.player?.start == 1.5 && seeking.lastPlaybackStart == 1.5,
              "Repeated preparation seeks autoplay only the latest selected position, discarding cancelled results")
    seeking.preparesPlaybackInBackground = false; seeking.stop()
    seeking.preparesPlaybackInBackground = true; seeking.seek(to: 0.25)
    var idleWorkerBlocked = false
    try wait {
        if !idleWorkerBlocked { idleWorkerBlocked = seekEntered.wait(timeout: .now()) == .success }
        return idleWorkerBlocked
    }
    seeking.seek(to: 2)
    try check(seeking.cursor == 2 && seeking.isPrebuffering && !seeking.isPreparingPlayback,
              "Seeking during idle prebuffering replaces its target without enabling autoplay")
    seekGate.signal()
    try wait { seeking.bufferPercent == 100 }
    try check(!seeking.isPlaying && seeking.cursor == 2, "Replacement idle preparation stays stopped at the newly selected cursor")
    seeking.preparesPlaybackInBackground = false; seeking.stop()
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
        guard performanceIndicators.buffer.title == editor.playbackBufferLabel, performanceIndicators.buffer.isEnabled,
              editor.bufferPercent == 100 else { throw SounderError.message("Idle BUFFER must show editable duration while retaining ready audio") }
        editor.playPause()
        while editor.isPreparingPlayback, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        guard editor.player?.graph.outputCache === cached else { throw SounderError.message("Interactive Play discarded the processed cache") }
        editor.stopAndReturnToStart(); performanceIndicators.refresh()
        editor.preparesPlaybackInBackground = false; editor.invalidateMixCache()
        performanceIndicators.refresh()
        let dialog = PlaybackBufferDialog(frames: 512, sampleRate: 48_000)
        guard dialog.duration.stringValue == "10.7 ms" else { throw SounderError.message("Buffer duration does not match the project sample rate") }
        dialog.field.stringValue = "1536"
        dialog.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: dialog.field))
        guard dialog.duration.stringValue == "32 ms" else { throw SounderError.message("Buffer duration does not update immediately during entry") }
        let dialogValues = [80, 32784, 113]
        var attempts = 0
        let dialogDeadline = Date().addingTimeInterval(3)
        let responder = Timer(timeInterval: 0.05, repeats: true) { _ in
            guard let modal = NSApp.modalWindow else { return }
            if Date() > dialogDeadline { NSApp.stopModal(withCode: .alertSecondButtonReturn); return }
            func input(in view: NSView) -> NSTextField? {
                if let field = view as? NSTextField, field.isEditable { return field }
                return view.subviews.lazy.compactMap { input(in: $0) }.first
            }
            guard attempts < dialogValues.count, let content = modal.contentView, let field = input(in: content) else { return }
            field.stringValue = String(dialogValues[attempts]); attempts += 1
            NSApp.stopModal(withCode: .alertFirstButtonReturn)
        }
        RunLoop.main.add(responder, forMode: .modalPanel)
        defer { responder.invalidate() }
        performanceIndicators.buffer.performClick(nil)
        responder.invalidate(); performanceIndicators.refresh()
        guard attempts == 3, editor.project.playbackBufferSize == 113,
              performanceIndicators.buffer.title == editor.playbackBufferLabel else {
            throw SounderError.message("BUFFER editor must reject out-of-range input and preserve arbitrary integer values")
        }
        print("PASS: BUFFER updates milliseconds during entry, rejects invalid limits and applies the exact selected integer size")
        print("PASS: Interactive BUFFER sampled real preparation values \(samples.sorted()) and shows editable duration while idle without discarding readiness")
        print("PASS: CPU/BUFFER appear on the right of the toolbar with aligned readouts")
    }
}
