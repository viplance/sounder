import AppKit

func runAudioImportTests() throws {
    _ = NSApplication.shared
    func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw SounderError.message(message) }; print("PASS: \(message)")
    }
    func wait(_ job: AudioImportController) throws {
        let deadline = Date().addingTimeInterval(10)
        while job.isRunning && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        try check(!job.isRunning, "Background import finishes without blocking the main run loop")
    }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SounderImportTests-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try AudioStore(directory: directory.appendingPathComponent("Recordings"))
    let source = directory.appendingPathComponent("Stereo source.wav")
    try store.write(AudioSignal(channels: [[Float](repeating: 0.25, count: 12_000), [Float](repeating: -0.125, count: 12_000)]), to: source, bitDepth: 24)
    let original = try Data(contentsOf: source)
    let editor = Editor(store: store); editor.cursor = 1.25
    let missing = directory.appendingPathComponent("Missing.wav")
    editor.importAudio(urls: [source, missing, source])
    let job = editor.importer!
    try check(job.window.isVisible && editor.isImporting && !editor.dirty, "Import progress opens immediately before audio is added")
    try wait(job)
    try check(job.statuses[0] == "Ready" && job.statuses[1].hasPrefix("Failed:") && job.statuses[2] == "Ready" && job.fractions[0] == 1 && job.fractions[2] == 1, "Each file has independent progress and a failed file does not stop the remaining imports")
    let clips = editor.project.tracks[0].clips
    try check(clips.count == 2 && clips[0].start == 1.25 && clips[1].start == 1.5 && clips[0].order < clips[1].order, "Successful imports retain selection order and sequential placement")
    try check(clips.allSatisfy { store.cache[$0.source]?.channelPeaks.count == 2 }, "Final source paths are cached with stereo waveforms before the first timeline draw")
    try check(try Data(contentsOf: source) == original, "Import preserves the original file byte for byte")
    let loaded = try store.load(clips[0].source)
    try check(loaded.channels[0][0] == 0.25 && loaded.channels[1][0] == -0.125, "Prepared import cache contains the actual left and right PCM samples")
    editor.undo()
    try check(editor.project.tracks[0].clips.isEmpty, "A batch of imported fragments can be undone together")
    job.close()
    let secondSource = directory.appendingPathComponent("Second instrument.wav")
    let thirdSource = directory.appendingPathComponent("Third instrument.wav")
    try FileManager.default.copyItem(at: source, to: secondSource)
    try FileManager.default.copyItem(at: source, to: thirdSource)
    let root = Track(name: "Root")
    let child = Track(name: "Child", parent: root.id)
    let tail = Track(name: "Last root")
    // Serialized array order differs from visual hierarchy order.
    editor.project = Project(tracks: [root, tail, child]); editor.selectedTrack = child.id; editor.cursor = 3.5
    let beforeBatch = editor.undoStack.count
    editor.importAudio(urls: [source, secondSource, thirdSource], placement: .separateTracks)
    let separate = editor.importer!
    editor.selectedTrack = root.id; editor.cursor = 7
    try wait(separate)
    let visual = TrackHierarchy.orderedRows(editor.project.tracks).map { $0.0 }
    try check(visual.count == 4 && visual[0].clips.isEmpty && visual[1].id == child.id && visual[1].clips.first?.name == "Stereo source" && visual[2].id == tail.id && visual[2].clips.first?.name == "Second instrument", "Separate-track import starts at the captured active track and follows visual hierarchy order")
    try check(visual[3].name == "Third instrument" && visual[3].parent == nil && visual[3].clips.first?.name == "Third instrument", "Missing destination tracks are created with the imported fragment name")
    let parallelClips = visual.flatMap(\.clips)
    try check(parallelClips.count == 3 && parallelClips.allSatisfy { $0.start == 3.5 } && editor.selectedTrack == child.id && editor.selection == Set(parallelClips.map(\.id)), "Separate-track files share the captured cursor time and are selected together")
    try check(editor.undoStack.count == beforeBatch + 1 && parallelClips.allSatisfy { store.cache[$0.source]?.channelPeaks.count == 2 }, "Parallel import publishes prepared waveforms and creates one Undo entry")
    editor.undo()
    try check(editor.project.tracks.count == 3 && editor.project.tracks.allSatisfy { $0.clips.isEmpty }, "Undo removes imported fragments and auto-created tracks together")
    editor.redo()
    try check(editor.project.tracks.count == 4 && editor.project.tracks.flatMap(\.clips).count == 3, "Redo restores the complete parallel import")
    editor.undo(); separate.close()
    editor.project = Project(tracks: []); editor.selectedTrack = nil
    let prepared = [ImportedAudio(name: "First", url: source, data: loaded), ImportedAudio(name: "Second", url: secondSource, data: loaded)]
    editor.finishAudioImport(prepared, track: nil, start: 2, placement: .separateTracks)
    try check(editor.project.tracks.map(\.name) == ["First", "Second"] && editor.project.tracks.flatMap(\.clips).allSatisfy { $0.start == 2 }, "An empty project creates one named track per imported file at the same time")
    editor.undo()
    let pathsBeforeCancel = Set(try FileManager.default.contentsOfDirectory(atPath: store.directory.path))
    editor.importAudio(urls: [source, source], placement: .separateTracks)
    let cancelled = editor.importer!; cancelled.cancel()
    try wait(cancelled)
    try check(editor.project.tracks.isEmpty && cancelled.statuses.allSatisfy { $0 == "Cancelled" } && Set(try FileManager.default.contentsOfDirectory(atPath: store.directory.path)) == pathsBeforeCancel, "Cancellation removes partial copies and leaves the project untouched")
    cancelled.close()

    // Opening must leave the live project/cache untouched until every source is ready.
    let document = directory.appendingPathComponent("Session.sounder")
    var savedProject = Project(tracks: [Track(name: "Saved")])
    savedProject.tracks[0].clips = [Clip(name: "Audio", source: source.path, start: 0, duration: 0.25, order: 0)]
    _ = try ProjectStorage.save(savedProject, to: document)
    func waitForOpen(_ job: ProjectOpenController) throws {
        let deadline = Date().addingTimeInterval(10)
        while job.isRunning && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        try check(!job.isRunning, "Project opening completes while the main run loop remains responsive")
    }
    let prior = editor.project
    let priorCache = Set(store.cache.keys)
    try editor.startProjectOpen(from: document)
    let cancelledOpen = editor.projectOpener!
    try check(cancelledOpen.window.isVisible && editor.isOpening && editor.busy && !editor.canRecord && !editor.canEditEffects,
              "Project progress appears immediately and conflicting actions are disabled")
    try check(editor.project.tracks.isEmpty, "Opening does not replace the project before loading finishes")
    cancelledOpen.cancel(); try waitForOpen(cancelledOpen)
    try check(cancelledOpen.failure is CancellationError && editor.project.tracks.count == prior.tracks.count && Set(store.cache.keys) == priorCache && !editor.isOpening,
              "Cancelled opening preserves the current project and audio cache")
    try editor.startProjectOpen(from: document)
    let opened = editor.projectOpener!
    try waitForOpen(opened)
    let reopened = editor.project.tracks[0].clips[0]
    try check(opened.failure == nil && opened.fraction == 1 && !opened.window.isVisible && editor.projectURL == document && !editor.dirty,
              "Successful opening commits the document and dismisses progress")
    try check(store.cache[reopened.source]?.channels[0][0] == 0.25 && store.cache[reopened.source]?.channelPeaks.count == 2,
              "Opening publishes decoded stereo PCM and waveforms before timeline drawing")
    editor.cursor = 0.125
    let committedCache = Set(store.cache.keys)
    let broken = directory.appendingPathComponent("Broken.sounder")
    var invalid = savedProject
    invalid.tracks[0].clips[0].duration = 10
    _ = try ProjectStorage.save(invalid, to: broken)
    try editor.startProjectOpen(from: broken)
    let failedOpen = editor.projectOpener!
    try waitForOpen(failedOpen)
    try check(failedOpen.failure != nil && failedOpen.window.isVisible && editor.projectURL == document && editor.cursor == 0.125 && Set(store.cache.keys) == committedCache,
              "Failed validation keeps the previous project, cursor and prepared cache intact")
    failedOpen.close()
}

extension AppDelegate {
    func importUITest(_ url: URL) {
        let began = ProcessInfo.processInfo.systemUptime
        let originalInfo = try? FileManager.default.attributesOfItem(atPath: url.path)
        editor.importAudio(urls: [url])
        guard let job = editor.importer, job.window.isVisible else { fputs("FAIL: import window did not appear immediately\n", stderr); exit(1) }
        let appeared = ProcessInfo.processInfo.systemUptime - began
        var lastTick = ProcessInfo.processInfo.systemUptime, maxGap = 0.0, ticks = 0, snapshotTaken = false
        let heartbeat = Timer(timeInterval: 0.01, repeats: true) { _ in
            let now = ProcessInfo.processInfo.systemUptime
            maxGap = max(maxGap, now - lastTick); lastTick = now; ticks += 1
            if !snapshotTaken && job.fractions.contains(where: { $0 > 0 && $0 < 1 }),
               let index = CommandLine.arguments.firstIndex(of: "--snapshot"), index + 1 < CommandLine.arguments.count,
               let view = job.window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                snapshotTaken = true
                view.effectiveAppearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: bitmap) }
                try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
            }
        }
        RunLoop.main.add(heartbeat, forMode: .common)
        job.completed = { [weak self, weak job] in
            heartbeat.invalidate()
            guard let self, let job else { exit(1) }
            let clips = self.editor.project.tracks.flatMap(\.clips)
            let info = try? FileManager.default.attributesOfItem(atPath: url.path)
            guard clips.count == 1, job.statuses == ["Ready"], job.fractions == [1],
                  self.editor.audio.cache[clips[0].source]?.channelPeaks.count == 2,
                  ticks > 5, maxGap < 0.5, appeared < 0.5,
                  (info?[.size] as? NSNumber) == (originalInfo?[.size] as? NSNumber),
                  (info?[.modificationDate] as? Date) == (originalInfo?[.modificationDate] as? Date) else {
                fputs("FAIL: import UI, progress, source preservation or responsiveness check failed (max gap \(maxGap), ticks \(ticks))\n", stderr); exit(1)
            }
            print(String(format: "PASS: %@ imported in %.2f s; popup appeared in %.3f s; %d main-thread heartbeat ticks; longest gap %.3f s", url.lastPathComponent, ProcessInfo.processInfo.systemUptime - began, appeared, ticks, maxGap))
            print("PASS: prepared stereo data is cached at the final source path; original audio was preserved")
            try? FileManager.default.removeItem(atPath: clips[0].source)
            self.editor.dirty = false
            NSApp.terminate(nil)
        }
    }
}

extension AppDelegate {
    func verifyImportPlacementUI() throws {
        for choice in [0, 1, 2] {
            let dialog = ImportPlacementDialog()
            guard dialog.single.title == "One track", dialog.separate.title == "Separate tracks", dialog.placement == .separateTracks, dialog.separate.frame.minY > dialog.single.frame.minY else { throw SounderError.message("Separate tracks must be first and selected by default") }
            var keyFailure: String?
            let timer = Timer(timeInterval: 0.1, repeats: false) { _ in
                if choice == 1 {
                    for (code, flags, expected) in [(UInt16(125), NSEvent.ModifierFlags(), AudioImportPlacement.singleTrack), (126, [], .separateTracks), (48, [], .singleTrack), (48, [.shift], .separateTracks), (126, [], .singleTrack), (125, [], .separateTracks), (48, [], .singleTrack)] {
                        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: dialog.alert.window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
                        if !dialog.handleSelectionKey(event) || dialog.placement != expected { keyFailure = "Tab/Shift-Tab/Up/Down failed to switch the import radio choice" }
                    }
                    let otherWindow = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: self.window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 48)!
                    if dialog.handleSelectionKey(otherWindow) { keyFailure = "Import radio navigation intercepted another window" }
                }
                dialog.alert.buttons[choice == 2 ? 1 : 0].performClick(nil)
            }
            RunLoop.main.add(timer, forMode: .common)
            let result = dialog.runModal()
            if let keyFailure { throw SounderError.message(keyFailure) }
            guard choice == 0 ? result == .separateTracks : choice == 1 ? result == .singleTrack : result == nil else { throw SounderError.message("Import placement choice or cancellation failed") }
        }
        print("PASS: import radio choices cycle with Tab, Shift-Tab, Up and Down; default, confirmation and cancellation work")
    }
}
