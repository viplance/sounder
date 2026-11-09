import AppKit
import AVFoundation
import CryptoKit

func runPluginInstallationTests(archives: URL? = nil) throws {
    _ = NSApplication.shared
    func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw SounderError.message(message) }; print("PASS: \(message)")
    }
    let catalog = try PluginCatalog.bundled.get()
    try check(catalog.count == 9 && Set(catalog.map(\.bundleIdentifier)).count == 9,
              "The bundled JSON contains nine distinct macOS VST3 plug-ins")
    let nova = catalog.first { $0.id == "nova" }!
    let picker = PluginPicker(frame: NSRect(x: 0, y: 0, width: 221, height: 30))
    picker.results.dataSource = picker; picker.results.delegate = picker
    picker.setPlugins([]); picker.filter("tókyo equalizer")
    try check(picker.matches.isEmpty && picker.catalogMatches.map(\.id) == [nova.id],
              "Catalog search matches maker/category and case/diacritic-insensitive words")
    var installs = 0, additions = 0
    picker.onInstall = { _ in installs += 1 }; picker.onChoose = { _ in additions += 1 }
    picker.results.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
    picker.choose()
    try check(installs == 0 && additions == 0, "Selecting a missing plug-in never downloads or adds it without Install")
    let row = picker.tableView(picker.results, viewFor: nil, row: 0) as! CatalogPluginRow
    row.frame = NSRect(x: 0, y: 0, width: 396, height: 28); row.layout()
    try check(row.install.frame.maxX == 388 && row.name.frame.maxX < row.install.frame.minX && row.install.title == "Install",
              "Install occupies the right edge without overlapping the plug-in name")
    row.install.performClick(nil)
    try check(installs == 1 && additions == 0, "Install has one explicit action and does not add an uninstalled bundle")
    picker.canInstall = false
    let disabled = picker.tableView(picker.results, viewFor: nil, row: 0) as! CatalogPluginRow
    try check(!disabled.install.isEnabled, "An active installation disables duplicate Install actions")
    let installed = URL(fileURLWithPath: "/test/VST3/" + nova.bundleName)
    picker.canInstall = true; picker.setPlugins([installed]); picker.filter("TDR Nova")
    try check(picker.matches == [installed] && picker.catalogMatches.isEmpty && picker.numberOfRows(in: picker.results) == 1,
              "An installed catalog entry becomes one ordinary row with no Install button")
    picker.results.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false); picker.choose()
    try check(additions == 1, "An installed catalog plug-in uses the normal immediate selection action")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SounderInstallTests-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    func wait(_ job: PluginInstallController, timeout: Double = 30) throws {
        let end = Date().addingTimeInterval(timeout)
        while job.isRunning && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        if job.isRunning { job.cancel() }
        try check(!job.isRunning, "The installation worker finishes without blocking the main run loop")
    }
    let damaged = directory.appendingPathComponent("damaged.zip")
    try Data(repeating: 0x61, count: 1_048_576).write(to: damaged)
    let bad = PluginInstallController(plugin: nova, destinationDirectory: directory.appendingPathComponent("rejected"))
    let availability = Editor(store: try AudioStore(directory: directory.appendingPathComponent("availability")))
    availability.pluginInstaller = bad
    bad.start(localArchive: damaged)
    try check(availability.canRecord && availability.busy, "Installation leaves Record available while protecting project file actions")
    try check(bad.isRunning && bad.window.isVisible, "Install progress appears before unpacking or copying")
    try wait(bad)
    try check(bad.failure != nil && bad.window.isVisible && !FileManager.default.fileExists(atPath: bad.destinationDirectory.path),
              "A changed/corrupt download cannot install executable code and retains its error details")
    bad.close()
    let cancelled = PluginInstallController(plugin: nova, destinationDirectory: directory.appendingPathComponent("cancelled"))
    cancelled.start(localArchive: damaged); cancelled.cancel(); try wait(cancelled)
    try check(cancelled.failure is CancellationError && !cancelled.window.isVisible && !FileManager.default.fileExists(atPath: cancelled.destinationDirectory.path),
              "Cancelling before installation leaves the VST3 directory untouched and closes progress")
    let downloading = CommandLine.arguments.contains("--plugin-download")
    let store = try AudioStore(directory: directory.appendingPathComponent("recordings"))
    let editor = Editor(store: store)
    let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
    let capture = try LiveRecorder(url: store.freshURL(), format: ProjectAudioFormat(), inputFormat: format)
    try capture.start(); editor.activateRecording(capture)
    var activations = 0
    editor.activateInstalledPlugin(installed) { _ in activations += 1 }
    editor.update()
    try check(activations == 0 && editor.isRecording, "A completed installation cannot interrupt an ongoing recording")
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480)!
    buffer.frameLength = 480; buffer.floatChannelData![0].initialize(repeating: 0, count: 480)
    capture.writer.append(buffer); editor.stop()
    try check(activations == 1 && !editor.isRecording && editor.project.tracks[0].clips.count == 1,
              "A deferred installed plug-in activates once after the take is safely finalized")
    editor.requestingMic = true
    editor.activateInstalledPlugin(installed) { _ in activations += 1 }
    editor.requestingMic = false; editor.error(SounderError.message("Simulated microphone setup failure"))
    try check(activations == 2, "A microphone setup failure also releases the deferred plug-in selection")
    guard archives != nil || downloading else { return }
    let destination = directory.appendingPathComponent("VST3")
    for plugin in (downloading ? Array(catalog.prefix(1)) : catalog) {
        let source = archives?.appendingPathComponent(plugin.id + "." + plugin.archive.rawValue)
        let job = PluginInstallController(plugin: plugin, destinationDirectory: destination)
        var installed: URL?
        job.completed = { if case .success(let url) = $0 { installed = url } }
        job.start(localArchive: source); try wait(job, timeout: 90)
        if let failure = job.failure { throw failure }
        guard let installed else { throw SounderError.message("Missing installed plug-in") }
        try check(Bundle(url: installed)?.bundleIdentifier == plugin.bundleIdentifier && job.fraction == 1 && !job.window.isVisible,
                  "\(plugin.name) verifies, extracts and installs its native VST3 into the chosen directory")
        let host = try SNPluginHost(path: installed.path, classID: "", state: nil, sampleRate: 48_000)
        _ = try host.saveState()
        try check(!host.pluginName.isEmpty, "\(plugin.name) loads in the real VST3 host after installation")
        picker.setPlugins([installed]); picker.filter(plugin.name)
        try check(!picker.catalogMatches.contains { $0.id == plugin.id }, "\(plugin.name) no longer offers Install after installation")
        job.close()
    }
    try check(try FileManager.default.contentsOfDirectory(atPath: destination.path).filter { $0.hasPrefix(".Sounder-install-") }.isEmpty,
              "Successful installs leave no staging folders or partial bundles")
}

extension AppDelegate {
    func verifyPluginCatalogUI() throws {
        guard let id = editor.project.tracks.last?.id else { throw SounderError.message("Missing catalog test track") }
        let rack = EffectsWindow(editor: editor, trackID: id)
        rack.run()
        defer { rack.plugins.popover.close(); rack.done() }
        rack.plugins.setPlugins([]); rack.plugins.showPicker()
        let picker = rack.plugins
        picker.results.layoutSubtreeIfNeeded()
        guard picker.results.numberOfRows == 9, picker.catalogMatches.count == 9,
              let view = picker.popover.contentViewController?.view else { throw SounderError.message("Missing catalog rows") }
        for index in 0..<9 {
            guard let row = picker.results.view(atColumn: 0, row: index, makeIfNecessary: true) as? CatalogPluginRow,
                  row.install.title == "Install", row.install.isEnabled else { throw SounderError.message("Missing Install action") }
            row.layoutSubtreeIfNeeded()
            guard row.name.frame.maxX < row.install.frame.minX else { throw SounderError.message("Catalog name overlaps Install") }
        }
        let count = rack.effects.count
        picker.results.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false); picker.choose()
        guard editor.pluginInstaller == nil, rack.effects.count == count else { throw SounderError.message("Catalog selection unexpectedly installed a plug-in") }
        if let index = CommandLine.arguments.firstIndex(of: "--snapshot"), index + 1 < CommandLine.arguments.count,
           let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.layoutSubtreeIfNeeded(); view.cacheDisplay(in: view.bounds, to: bitmap)
            let path = URL(fileURLWithPath: CommandLine.arguments[index + 1]).deletingPathExtension().appendingPathExtension("catalog.png")
            try bitmap.representation(using: .png, properties: [:])?.write(to: path)
        }
        print("PASS: FX catalog renders nine right-aligned Install buttons and selection remains side-effect free")
    }
}
