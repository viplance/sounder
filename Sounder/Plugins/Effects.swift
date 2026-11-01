import AppKit

struct PluginEffect: Codable, Identifiable {
    var id = UUID()
    var name: String
    var path: String
    var classID: String
    var state: Data?
    var bypassed = false
    var format: String { URL(fileURLWithPath: path).pathExtension.uppercased() }
}

enum PluginProcessing {
    static func apply(_ samples: [Float], effects: [PluginEffect]) throws -> [Float] {
        try apply(AudioSignal(channels: [samples]), effects: effects, format: ProjectAudioFormat(channels: 1)).mono
    }
    static func apply(_ signal: AudioSignal, effects: [PluginEffect], format: ProjectAudioFormat) throws -> AudioSignal {
        var output = signal
        for effect in effects where !effect.bypassed {
            do {
                let host = try SNPluginHost(path: effect.path, classID: effect.classID, state: effect.state, sampleRate: format.sampleRate)
                var interleaved = [Float](repeating: 0, count: output.frameCount * format.channels)
                for frame in 0..<output.frameCount { for channel in 0..<format.channels { interleaved[frame * format.channels + channel] = output.channels[channel][frame] } }
                let processed = try host.processAudio(interleaved.withUnsafeBytes { Data($0) }, channels: format.channels)
                let values = processed.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
                let frames = values.count / format.channels
                output = AudioSignal(channels: (0..<format.channels).map { channel in (0..<frames).map { values[$0 * format.channels + channel] } })
            } catch {
                throw SounderError.message("\(effect.name): \(error.localizedDescription)\nOpen the track’s FX chain to bypass or replace the plug-in.")
            }
        }
        return output
    }
    static func installed() -> [URL] {
        let paths = ["/Library/Audio/Plug-Ins/VST", "/Library/Audio/Plug-Ins/VST3", NSHomeDirectory() + "/Library/Audio/Plug-Ins/VST", NSHomeDirectory() + "/Library/Audio/Plug-Ins/VST3"]
        var result: [URL] = []
        for path in paths {
            if let files = FileManager.default.enumerator(at: URL(fileURLWithPath: path), includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
                for case let file as URL in files where ["vst", "vst3"].contains(file.pathExtension.lowercased()) { result.append(file); files.skipDescendants() }
            }
        }
        return result.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
}

final class PluginEditorWindow: NSObject, NSWindowDelegate {
    let host: SNPluginHost
    unowned let editor: Editor
    let effectID: UUID
    var window: NSWindow!
    var idle: Timer?
    var lastParameters: [Double] = []
    var lastRevision: UInt64 = 0
    var lastChange = Date.distantPast
    var lastLatency = 0
    init(host: SNPluginHost, editor: Editor, effectID: UUID) {
        self.host = host; self.editor = editor; self.effectID = effectID
    }
    func show(native: Bool) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 466), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = host.pluginName; window.delegate = self; window.isReleasedWhenClosed = false
        let body = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 466)); body.wantsLayer = true; body.layer?.backgroundColor = panelColor.cgColor
        let root = NSView(frame: body.frame); root.addSubview(body); window.contentView = root
        if native && host.attachEditor(body) {
            window.setContentSize(NSSize(width: max(320, body.frame.width), height: body.frame.height))
        } else {
            let scroll = NSScrollView(frame: body.bounds); scroll.hasVerticalScroller = true; scroll.autoresizingMask = [.width, .height]; body.addSubview(scroll)
            let parameters = host.parameters()
            let content = NSView(frame: NSRect(x: 0, y: 0, width: 620, height: CGFloat(max(1, parameters.count)) * 48 + 20))
            for (row, parameter) in parameters.enumerated() {
                let y = content.frame.height - CGFloat(row + 1) * 48
                let name = NSTextField(labelWithString: parameter["name"] as? String ?? "Parameter"); name.frame = NSRect(x: 18, y: y + 12, width: 250, height: 20); content.addSubview(name)
                let slider = NSSlider(value: (parameter["value"] as? NSNumber)?.doubleValue ?? 0, minValue: 0, maxValue: 1, target: self, action: #selector(changeParameter(_:)))
                slider.isContinuous = true
                slider.tag = (parameter["index"] as? NSNumber)?.intValue ?? 0; slider.frame = NSRect(x: 285, y: y + 10, width: 305, height: 24); slider.toolTip = name.stringValue; content.addSubview(slider)
            }
            if parameters.isEmpty { let label = NSTextField(labelWithString: "This plug-in exposes no editable parameters."); label.frame = NSRect(x: 18, y: 10, width: 550, height: 22); content.addSubview(label) }
            scroll.documentView = content
        }
        ToastOverlay.install(in: root, center: editor.notifications)
        lastParameters = parameterValues(); lastRevision = host.editRevision; lastLatency = host.latency
        idle = Timer(timeInterval: 1 / 30, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.host.editorIdle(); self.captureChanges()
        }
        RunLoop.main.add(idle!, forMode: .common)
        editor.pluginWindows[effectID] = self
        window.center(); window.makeKeyAndOrderFront(nil)
    }
    func parameterValues() -> [Double] { host.parameters().map { ($0["value"] as? NSNumber)?.doubleValue ?? 0 } }
    func captureChanges() {
        let parameters = parameterValues(), revision = host.editRevision
        if host.latency != lastLatency { lastLatency = host.latency; editor.effectsChanged() }
        guard parameters != lastParameters || revision != lastRevision else { return }
        editor.invalidateMixCache()
        guard let track = editor.project.tracks.firstIndex(where: { $0.effects.contains(where: { $0.id == effectID }) }),
              let effect = editor.project.tracks[track].effects.firstIndex(where: { $0.id == effectID }) else { return }
        do {
            let state = try host.saveState()
            if state != editor.project.tracks[track].effects[effect].state {
                if !editor.dirty || Date().timeIntervalSince(lastChange) > 0.5 { editor.checkpoint() }
                editor.project.tracks[track].effects[effect].state = state
                lastChange = Date(); editor.update()
            }
            lastParameters = parameters; lastRevision = revision
        } catch { editor.error(error) }
    }
    @objc func changeParameter(_ sender: NSSlider) { host.setParameter(sender.tag, value: sender.doubleValue); captureChanges() }
    func close(capture: Bool = true) {
        if capture { captureChanges() }
        idle?.invalidate(); idle = nil; host.detachEditor(); window?.orderOut(nil)
        editor.pluginWindows.removeValue(forKey: effectID)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { close(); return false }
}

final class EffectsWindow: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    unowned let editor: Editor
    let trackID: UUID
    var window: NSWindow!
    let table = NSTableView()
    let plugins = NSPopUpButton()
    var installed: [URL] = []
    var snapshotMode = false
    var index: Int? { editor.project.tracks.firstIndex { $0.id == trackID } }
    var effects: [PluginEffect] { index.map { editor.project.tracks[$0].effects } ?? [] }
    init(editor: Editor, trackID: UUID) { self.editor = editor; self.trackID = trackID }
    func run(snapshot: URL? = nil) {
        guard let index else { return }
        if let existing = editor.effectsWindows[trackID] { existing.window.makeKeyAndOrderFront(nil); return }
        snapshotMode = snapshot != nil
        editor.effectsWindows[trackID] = self
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 399), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "FX · " + editor.project.tracks[index].name; window.delegate = self; window.isReleasedWhenClosed = false
        let root = NSView(); root.wantsLayer = true; root.layer?.backgroundColor = panelColor.cgColor; window.contentView = root
        let heading = NSTextField(labelWithString: "Track effects"); heading.font = .systemFont(ofSize: 23, weight: .semibold); heading.frame = NSRect(x: 22, y: 354, width: 350, height: 35); root.addSubview(heading)
        let scroll = NSScrollView(frame: NSRect(x: 22, y: 142, width: 716, height: 204)); scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("effect")); column.title = "Processing order · top to bottom"; column.width = 690; table.addTableColumn(column); table.rowHeight = 34; table.dataSource = self; table.delegate = self; table.target = self; table.doubleAction = #selector(configure); scroll.documentView = table; root.addSubview(scroll)
        let actions: [(String, Selector)] = [("Open editor…", #selector(configure)), ("Parameters…", #selector(parameters)), ("Bypass", #selector(bypass)), ("↑", #selector(up)), ("↓", #selector(down)), ("Remove", #selector(remove))]
        var x: CGFloat = 22
        for (title, action) in actions { let button = PointerButton(title: title, target: self, action: action); button.bezelStyle = .rounded; let width: CGFloat = title.count < 2 ? 40 : title == "Open editor…" || title == "Parameters…" ? 125 : 90; button.frame = NSRect(x: x, y: 100, width: width, height: 30); root.addSubview(button); x += width + 6 }
        plugins.frame = NSRect(x: 22, y: 58, width: 425, height: 28); root.addSubview(plugins)
        let add = PointerButton(title: "Add", target: self, action: #selector(addPlugin)); add.bezelStyle = .rounded; add.frame = NSRect(x: 455, y: 56, width: 65, height: 32); root.addSubview(add)
        let browse = PointerButton(title: "Browse…", target: self, action: #selector(browse)); browse.bezelStyle = .rounded; browse.frame = NSRect(x: 525, y: 56, width: 100, height: 32); root.addSubview(browse)
        let rescan = PointerButton(title: "Rescan", target: self, action: #selector(scan)); rescan.bezelStyle = .rounded; rescan.frame = NSRect(x: 630, y: 56, width: 100, height: 32); root.addSubview(rescan)
        let done = PointerButton(title: "Done", target: self, action: #selector(done)); done.bezelStyle = .rounded; done.frame = NSRect(x: 638, y: 12, width: 100, height: 30); root.addSubview(done)
        ToastOverlay.install(in: root, center: editor.notifications)
        scan(); reload(); window.center(); window.makeKeyAndOrderFront(nil)
        if let snapshot {
            let capture = Timer(timeInterval: 0.7, repeats: false) { _ in
                if let view = self.window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.effectiveAppearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: bitmap) }
                    try? bitmap.representation(using: .png, properties: [:])?.write(to: snapshot)
                }
                self.done()
            }
            RunLoop.main.add(capture, forMode: .modalPanel)
        }
        if snapshotMode { NSApp.runModal(for: window); window.orderOut(nil) }
    }
    func reload() {
        table.reloadData()
        editor.update()
    }
    func numberOfRows(in tableView: NSTableView) -> Int { effects.count }
    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        let effect = effects[row]; let missing = !FileManager.default.fileExists(atPath: effect.path)
        return "\(row + 1).  \(effect.bypassed ? "○" : "●")  \(effect.name)    [\(effect.format)]" + (effect.bypassed ? "  ·  bypassed" : "") + (missing ? "  ·  missing" : "")
    }
    @objc func scan() { installed = PluginProcessing.installed(); plugins.removeAllItems(); plugins.addItems(withTitles: installed.map { $0.deletingPathExtension().lastPathComponent + "  [" + $0.pathExtension.uppercased() + "]" }); if installed.isEmpty { plugins.addItem(withTitle: "No installed VST / VST3 effects found") } }
    func add(_ url: URL) {
        guard let index else { return }
        do {
            let host = try SNPluginHost(path: url.path, classID: "", state: nil, sampleRate: editor.project.audioFormat.sampleRate)
            let effect = PluginEffect(name: host.pluginName, path: url.path, classID: host.classID, state: try host.saveState())
            editor.checkpoint(); editor.project.tracks[index].effects.append(effect); editor.effectsChanged(); reload(); editor.notifications.show("Effect added", style: .success); table.selectRowIndexes(IndexSet(integer: effects.count - 1), byExtendingSelection: false)
        } catch { editor.error(error); return }
        configure()
    }
    @objc func addPlugin() { let row = plugins.indexOfSelectedItem; if installed.indices.contains(row) { add(installed[row]) } }
    @objc func browse() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.treatsFilePackagesAsDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard ["vst", "vst3"].contains(url.pathExtension.lowercased()) else { editor.error(SounderError.message("Choose a .vst or .vst3 plug-in bundle.")); return }; add(url)
    }
    func editPlugin(native: Bool) {
        let row = table.selectedRow; guard effects.indices.contains(row), index != nil else { return }
        let effect = effects[row]
        do {
            if let existing = editor.pluginWindows[effect.id] { existing.window.makeKeyAndOrderFront(nil); return }
            let host = try editor.pluginHost(effect)
            PluginEditorWindow(host: host, editor: editor, effectID: effect.id).show(native: native)
        } catch { editor.error(error) }
    }
    @objc func configure() { editPlugin(native: true) }
    @objc func parameters() { editPlugin(native: false) }
    @objc func bypass() { let row = table.selectedRow; guard effects.indices.contains(row), let index else { return }; editor.checkpoint(); editor.project.tracks[index].effects[row].bypassed.toggle(); editor.effectsChanged(); reload(); editor.notifications.show("Effect bypass updated", style: .success); table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
    @objc func remove() { let row = table.selectedRow; guard effects.indices.contains(row), let index else { return }; editor.checkpoint(); let effectID = effects[row].id; editor.pluginWindows[effectID]?.close(); editor.project.tracks[index].effects.remove(at: row); editor.effectsChanged(); reload(); editor.notifications.show("Effect removed", style: .success) }
    func move(_ delta: Int) { let row = table.selectedRow; guard effects.indices.contains(row), effects.indices.contains(row + delta), let index else { return }; editor.checkpoint(); editor.project.tracks[index].effects.swapAt(row, row + delta); editor.effectsChanged(); reload(); editor.notifications.show("Effect order updated", style: .success); table.selectRowIndexes(IndexSet(integer: row + delta), byExtendingSelection: false) }
    @objc func up() { move(-1) }
    @objc func down() { move(1) }
    @objc func done() { window.orderOut(nil); editor.effectsWindows.removeValue(forKey: trackID); if snapshotMode { NSApp.stopModal() } }
    func windowShouldClose(_ sender: NSWindow) -> Bool { done(); return false }
}
