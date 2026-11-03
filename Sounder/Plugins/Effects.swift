import AppKit
import UniformTypeIdentifiers

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
        window.level = .floating
        window.hidesOnDeactivate = false
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
        guard let effect = editor.project.allEffects.first(where: { $0.id == effectID }) else { return }
        do {
            let state = try host.saveState()
            if state != effect.state {
                if !editor.dirty || Date().timeIntervalSince(lastChange) > 0.5 { editor.checkpoint() }
                editor.setEffectState(state, effectID: effectID)
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

/// View-based labels use the same vertical center as the native selection.
final class PluginNameRow: NSTableCellView {
    init(name: String) {
        super.init(frame: .zero)
        let label = NSTextField(labelWithString: name)
        label.font = .systemFont(ofSize: 13); label.lineBreakMode = .byTruncatingTail
        textField = label; addSubview(label)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        textField?.frame = NSRect(x: 8, y: bounds.midY - 9, width: max(0, bounds.width - 16), height: 18)
    }
}

/// A native popover keeps substring search and keyboard selection together.
final class PluginPicker: PointerButton, NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    let search = NSSearchField()
    let vst3Only = PointerButton(title: "VST3 only", target: nil, action: nil)
    let results = NSTableView()
    let popover = NSPopover()
    private(set) var installed: [URL] = []
    private(set) var matches: [URL] = []
    private(set) var selectedURL: URL?
    var onChoose: ((URL) -> Void)?
    private var prepared = false
    override init(frame: NSRect) {
        super.init(frame: frame)
        title = "Choose plug-in…"; bezelStyle = .rounded
        alignment = .left; lineBreakMode = .byTruncatingTail
        image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil); imagePosition = .imageTrailing
        target = self; action = #selector(showPicker)
        setAccessibilityLabel("Search installed VST and VST3 plug-ins")
        vst3Only.setButtonType(.switch); vst3Only.state = .on
        vst3Only.font = .systemFont(ofSize: 12)
        vst3Only.target = self; vst3Only.action = #selector(toggleVST3Only)
    }
    required init?(coder: NSCoder) { fatalError() }
    private var available: [URL] {
        installed.filter { vst3Only.state != .on || $0.pathExtension.lowercased() == "vst3" }
    }
    private func updateSelection() {
        let urls = available
        if !urls.contains(where: { $0 == selectedURL }) { selectedURL = urls.first }
        title = selectedURL.map(Self.displayName) ?? (vst3Only.state == .on ? "No installed VST3 effects found" : "No installed VST / VST3 effects found")
    }
    func setPlugins(_ urls: [URL]) {
        installed = urls; updateSelection(); filter(search.stringValue)
    }
    @objc func toggleVST3Only() { updateSelection(); filter(search.stringValue) }
    static func displayName(_ url: URL) -> String { url.deletingPathExtension().lastPathComponent + "  [" + url.pathExtension.uppercased() + "]" }
    func filter(_ query: String) {
        let words = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        matches = available.filter { url in words.allSatisfy { Self.displayName(url).range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil } }
        results.reloadData()
        if !matches.isEmpty { results.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
    }
    @objc func showPicker() {
        if !prepared {
            prepared = true
            let controller = NSViewController()
            controller.view = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 320))
            search.frame = NSRect(x: 12, y: 278, width: 278, height: 28)
            vst3Only.frame = NSRect(x: 300, y: 279, width: 108, height: 26)
            controller.view.addSubview(vst3Only)
            search.placeholderString = "Search plug-ins…"; search.delegate = self
            search.sendsSearchStringImmediately = true
            controller.view.addSubview(search)
            let scroll = NSScrollView(frame: NSRect(x: 12, y: 12, width: 396, height: 256)); scroll.hasVerticalScroller = true
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("plugin")); column.width = 376
            results.addTableColumn(column); results.headerView = nil; results.rowHeight = 28
            results.style = .plain; results.intercellSpacing = .zero
            results.dataSource = self; results.delegate = self; results.target = self; results.action = #selector(choose)
            results.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
            results.frame = NSRect(origin: .zero, size: scroll.contentSize); results.autoresizingMask = [.width]
            scroll.documentView = results; controller.view.addSubview(scroll)
            popover.contentViewController = controller; popover.behavior = .transient; popover.animates = false
        }
        search.stringValue = ""; filter("")
        popover.show(relativeTo: bounds, of: self, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeFirstResponder(search)
    }
    func numberOfRows(in tableView: NSTableView) -> Int { matches.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard matches.indices.contains(row) else { return nil }
        return PluginNameRow(name: Self.displayName(matches[row]))
    }
    func controlTextDidChange(_ obj: Notification) { filter(search.stringValue) }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.moveDown(_:)) || selector == #selector(NSResponder.moveUp(_:)) {
            guard !matches.isEmpty else { return true }
            let row = max(0, min(matches.count - 1, results.selectedRow + (selector == #selector(NSResponder.moveDown(_:)) ? 1 : -1)))
            results.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false); results.scrollRowToVisible(row); return true
        }
        if selector == #selector(NSResponder.insertNewline(_:)) { choose(); return true }
        if selector == #selector(NSResponder.cancelOperation(_:)) { popover.close(); return true }
        return false
    }
    @objc func choose() {
        guard matches.indices.contains(results.selectedRow) else { return }
        let url = matches[results.selectedRow]
        selectedURL = url; title = Self.displayName(url)
        popover.close(); onChoose?(url)
    }
}

final class EffectActionButton: PointerButton {
    private let invoke: () -> Void
    init(_ title: String, invoke: @escaping () -> Void) {
        self.invoke = invoke
        super.init(frame: .zero)
        self.title = title; identifier = NSUserInterfaceItemIdentifier(title); bezelStyle = .rounded; controlSize = .small
        font = .systemFont(ofSize: 11); target = self; action = #selector(invokeAction)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func invokeAction() { invoke() }
}

/// Explicit row geometry leaves all remaining width to the plug-in name.
final class EffectRowView: NSTableCellView {
    let name: NSTextField
    let controls: [(NSButton, CGFloat)]
    override var isFlipped: Bool { true }
    init(name: NSTextField, controls: [(NSButton, CGFloat)]) {
        self.name = name; self.controls = controls
        super.init(frame: .zero)
        addSubview(name); controls.forEach { addSubview($0.0) }
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        var x = bounds.maxX - 7
        for (button, width) in controls.reversed() {
            x -= width
            button.frame = NSRect(x: x, y: bounds.midY - 12, width: width, height: 24)
            x -= 5
        }
        name.frame = NSRect(x: 7, y: bounds.midY - 9, width: max(0, x - 7), height: 18)
    }
}

final class EffectsWindow: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    unowned let editor: Editor
    let trackID: UUID
    var window: NSWindow!
    let table = NSTableView()
    let plugins = PluginPicker(frame: .zero)
    private static let dragType = NSPasteboard.PasteboardType("enotix.Sounder.effect")
    var installed: [URL] = []
    var snapshotMode = false
    var index: Int? { editor.project.tracks.firstIndex { $0.id == trackID } }
    var effects: [PluginEffect] {
        get { editor.effectChain(for: trackID) ?? [] }
        set { editor.setEffectChain(newValue, for: trackID) }
    }
    var exists: Bool { editor.effectChain(for: trackID) != nil }
    init(editor: Editor, trackID: UUID) { self.editor = editor; self.trackID = trackID }
    func run(snapshot: URL? = nil) {
        guard exists else { return }
        if let existing = editor.effectsWindows[trackID] {
            existing.window.makeKeyAndOrderFront(nil); existing.focusEmptyPicker(); return
        }
        snapshotMode = snapshot != nil
        editor.effectsWindows[trackID] = self
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 399), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "FX · " + (trackID == Project.masterID ? "Master" : editor.project.tracks[index!].name); window.delegate = self; window.isReleasedWhenClosed = false
        let root = NSView(); root.wantsLayer = true; root.layer?.backgroundColor = panelColor.cgColor; window.contentView = root
        window.level = .floating; window.hidesOnDeactivate = false
        plugins.frame = NSRect(x: 22, y: 353, width: 498, height: 30); root.addSubview(plugins)
        plugins.onChoose = { [weak self] url in self?.add(url) }
        let browse = PointerButton(title: "Browse…", target: self, action: #selector(browse)); browse.bezelStyle = .rounded; browse.frame = NSRect(x: 525, y: 352, width: 100, height: 32); root.addSubview(browse)
        let rescan = PointerButton(title: "Rescan", target: self, action: #selector(scan)); rescan.bezelStyle = .rounded; rescan.frame = NSRect(x: 630, y: 352, width: 108, height: 32); root.addSubview(rescan)
        let scroll = NSScrollView(frame: NSRect(x: 22, y: 16, width: 716, height: 326)); scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("effect")); column.width = 696
        table.addTableColumn(column); table.headerView = nil; table.rowHeight = 40
        table.style = .plain; table.intercellSpacing = .zero
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.dataSource = self; table.delegate = self; table.target = self; table.doubleAction = #selector(configure)
        table.registerForDraggedTypes([Self.dragType]); table.setDraggingSourceOperationMask(.move, forLocal: true)
        table.setAccessibilityLabel("Effect processing order")
        table.frame = NSRect(origin: .zero, size: scroll.contentSize); table.autoresizingMask = [.width]
        scroll.documentView = table; root.addSubview(scroll)
        scan(); reload(); window.center(); window.makeKeyAndOrderFront(nil)
        focusEmptyPicker()
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
    private func focusEmptyPicker() {
        guard effects.isEmpty else { return }
        if !plugins.popover.isShown { plugins.showPicker() }
        plugins.search.window?.makeFirstResponder(plugins.search)
    }
    func reload(notifyEditor: Bool = true) {
        table.reloadData()
        if let window, exists { window.title = "FX · " + (trackID == Project.masterID ? "Master" : editor.project.tracks[index!].name) }
        if notifyEditor { editor.update() }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { effects.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard effects.indices.contains(row) else { return nil }
        let effect = effects[row], id = effect.id
        let missing = !FileManager.default.fileExists(atPath: effect.path)
        let name = NSTextField(labelWithString: "\(row + 1).  \(effect.name)  [\(effect.format)]" + (missing ? " · missing" : ""))
        name.lineBreakMode = .byTruncatingTail; name.font = .systemFont(ofSize: 12)
        name.textColor = effect.bypassed ? .secondaryLabelColor : .labelColor
        name.toolTip = effect.name + "\n" + effect.path
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let open = EffectActionButton("Open") { [weak self] in self?.editPlugin(id: id, native: true) }
        let up = EffectActionButton("Up") { [weak self] in self?.move(id: id, by: -1) }
        let down = EffectActionButton("Down") { [weak self] in self?.move(id: id, by: 1) }
        let bypass = EffectActionButton("Bypass") { [weak self] in self?.bypass(id: id) }
        bypass.setButtonType(.pushOnPushOff); bypass.state = effect.bypassed ? .off : .on
        let remove = EffectActionButton("Remove") { [weak self] in self?.remove(id: id) }
        up.isEnabled = row > 0; down.isEnabled = row < effects.count - 1
        for button in [open, up, down, bypass, remove] { button.setAccessibilityLabel(button.title + " " + effect.name) }
        bypass.activeAppearanceColor = .systemGreen
        bypass.contentTintColor = .secondaryLabelColor
        for (button, symbol, help) in [(open, "slider.horizontal.3", "Open editor"), (up, "arrow.up", "Move up"), (down, "arrow.down", "Move down"), (bypass, "power", "Bypass"), (remove, "trash", "Remove")] {
            button.title = ""; button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: help)
            button.imagePosition = .imageOnly; button.isBordered = false; button.toolTip = help
        }
        bypass.toolTip = effect.bypassed ? "Включить" : "Выключить"
        bypass.setAccessibilityLabel((bypass.toolTip ?? "") + " " + effect.name)
        return EffectRowView(name: name, controls: [(open, 26), (up, 26), (down, 26), (bypass, 26), (remove, 26)])
    }
    @objc func scan() { installed = PluginProcessing.installed(); plugins.setPlugins(installed) }
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard effects.indices.contains(row) else { return nil }
        let item = NSPasteboardItem(); item.setString(effects[row].id.uuidString, forType: Self.dragType); return item
    }
    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
        guard exists, info.draggingSource as? NSTableView === table, (0...effects.count).contains(row),
              let text = info.draggingPasteboard.string(forType: Self.dragType), let id = UUID(uuidString: text),
              let source = effects.firstIndex(where: { $0.id == id }), row != source, row != source + 1 else { return [] }
        tableView.setDropRow(row, dropOperation: .above)
        return .move
    }
    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard info.draggingSource as? NSTableView === table, dropOperation == .above,
              let text = info.draggingPasteboard.string(forType: Self.dragType), let id = UUID(uuidString: text) else { return false }
        return reorder(id: id, insertion: row)
    }
    @discardableResult func reorder(id: UUID, insertion: Int) -> Bool {
        guard exists, (0...effects.count).contains(insertion), let row = effects.firstIndex(where: { $0.id == id }) else { return false }
        let destination = insertion > row ? insertion - 1 : insertion
        guard destination != row else { return false }
        editor.checkpoint()
        var chain = effects; let effect = chain.remove(at: row); chain.insert(effect, at: destination); effects = chain
        editor.effectsChanged(); reload(); table.selectRowIndexes(IndexSet(integer: destination), byExtendingSelection: false)
        return true
    }
    func add(_ url: URL) {
        guard exists else { return }
        plugins.popover.close()
        do {
            let host = try SNPluginHost(path: url.path, classID: "", state: nil, sampleRate: editor.project.audioFormat.sampleRate)
            let effect = PluginEffect(name: host.pluginName, path: url.path, classID: host.classID, state: try host.saveState())
            editor.checkpoint(); effects.append(effect); editor.effectsChanged(); reload(); editor.notifications.show("Effect added", style: .success); table.selectRowIndexes(IndexSet(integer: effects.count - 1), byExtendingSelection: false)
        } catch { editor.error(error); return }
        configure()
    }
    func makeBrowsePanel() -> NSOpenPanel {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.treatsFilePackagesAsDirectories = false
        panel.allowedContentTypes = ["vst", "vst3"].compactMap { UTType(filenameExtension: $0, conformingTo: .bundle) }
        panel.allowsOtherFileTypes = false; panel.allowsMultipleSelection = false
        return panel
    }
    @objc func browse() {
        let panel = makeBrowsePanel()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard ["vst", "vst3"].contains(url.pathExtension.lowercased()) else { editor.error(SounderError.message("Choose a .vst or .vst3 plug-in bundle.")); return }; add(url)
    }
    func editPlugin(native: Bool) {
        let row = table.selectedRow; guard effects.indices.contains(row), exists else { return }
        editPlugin(id: effects[row].id, native: native)
    }
    func editPlugin(id: UUID, native: Bool) {
        guard exists, let effect = effects.first(where: { $0.id == id }) else { return }
        do {
            if let existing = editor.pluginWindows[effect.id] { existing.window.makeKeyAndOrderFront(nil); return }
            let host = try editor.pluginHost(effect)
            PluginEditorWindow(host: host, editor: editor, effectID: effect.id).show(native: native)
        } catch { editor.error(error) }
    }
    @objc func configure() { editPlugin(native: true) }
    @objc func parameters() { editPlugin(native: false) }
    @objc func bypass() { if effects.indices.contains(table.selectedRow) { bypass(id: effects[table.selectedRow].id) } }
    func bypass(id: UUID) {
        guard exists, let row = effects.firstIndex(where: { $0.id == id }) else { return }
        editor.checkpoint(); effects[row].bypassed.toggle(); editor.effectsChanged(); reload()
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }
    @objc func remove() { if effects.indices.contains(table.selectedRow) { remove(id: effects[table.selectedRow].id) } }
    func remove(id: UUID) {
        guard exists, let row = effects.firstIndex(where: { $0.id == id }) else { return }
        editor.pluginWindows[id]?.close(); editor.checkpoint(); effects.remove(at: row); editor.effectsChanged(); reload()
        editor.notifications.show("Effect removed", style: .success)
    }
    func move(id: UUID, by delta: Int) {
        guard let row = effects.firstIndex(where: { $0.id == id }), effects.indices.contains(row + delta) else { return }
        reorder(id: id, insertion: delta > 0 ? row + delta + 1 : row + delta)
    }
    func move(_ delta: Int) { if effects.indices.contains(table.selectedRow) { move(id: effects[table.selectedRow].id, by: delta) } }
    @objc func up() { move(-1) }
    @objc func down() { move(1) }
    @objc func done() { plugins.popover.close(); window.orderOut(nil); editor.effectsWindows.removeValue(forKey: trackID); if snapshotMode { NSApp.stopModal() } }
    func windowShouldClose(_ sender: NSWindow) -> Bool { done(); return false }
}
