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
    let pathsBeforeCancel = Set(try FileManager.default.contentsOfDirectory(atPath: store.directory.path))
    editor.importAudio(urls: [source, source])
    let cancelled = editor.importer!; cancelled.cancel()
    try wait(cancelled)
    try check(editor.project.tracks[0].clips.isEmpty && cancelled.statuses.allSatisfy { $0 == "Cancelled" } && Set(try FileManager.default.contentsOfDirectory(atPath: store.directory.path)) == pathsBeforeCancel, "Cancellation removes partial copies and leaves the project untouched")
    cancelled.close()
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
