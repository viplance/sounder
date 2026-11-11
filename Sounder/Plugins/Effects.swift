import AppKit
import UniformTypeIdentifiers

private let effectsControlFont = NSFont.systemFont(ofSize: 12)
private func applyEffectsButtonFont(_ button: NSButton) {
    button.font = effectsControlFont
    button.attributedTitle = NSAttributedString(string: button.title, attributes: [.font: effectsControlFont, .foregroundColor: NSColor.labelColor])
}

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
    static func apply(_ signal: AudioSignal, effects: [PluginEffect], format: ProjectAudioFormat,
                      progress: (Double, String) -> Void = { _, _ in }, cancelled: () -> Bool = { false }) throws -> AudioSignal {
        var output = signal
        let active = effects.filter { !$0.bypassed }
        for (index, effect) in active.enumerated() {
            do {
                if cancelled() { throw CancellationError() }
                progress(Double(index) / Double(active.count), "Processing " + effect.name)
                let host = try SNPluginHost(path: effect.path, classID: effect.classID, state: effect.state, sampleRate: format.sampleRate)
                var interleaved = [Float](repeating: 0, count: output.frameCount * format.channels)
                for frame in 0..<output.frameCount { for channel in 0..<format.channels { interleaved[frame * format.channels + channel] = output.channels[channel][frame] } }
                let processed = try host.processAudio(interleaved.withUnsafeBytes { Data($0) }, channels: format.channels, progress: {
                    progress((Double(index) + $0) / Double(active.count), "Processing " + effect.name)
                }, cancelled: cancelled)
                let values = processed.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
                let frames = values.count / format.channels
                output = AudioSignal(channels: (0..<format.channels).map { channel in (0..<frames).map { values[$0 * format.channels + channel] } })
            } catch {
                if cancelled() || error is CancellationError { throw CancellationError() }
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
        window = PopupWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 466))
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
        (window as? PopupWindow)?.installHeader(protectsHostedContent: true)
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
        guard let snapshot = host.editorSnapshot(revision: lastRevision, values: lastParameters.map { NSNumber(value: $0) }) else { return }
        if let message = snapshot["error"] as? String { editor.error(SounderError.message(message)); return }
        let parameters = (snapshot["values"] as? [NSNumber] ?? []).map(\.doubleValue)
        let revision = (snapshot["revision"] as? NSNumber)?.uint64Value ?? lastRevision
        let latency = (snapshot["latency"] as? NSNumber)?.intValue ?? lastLatency
        if latency != lastLatency { lastLatency = latency; editor.effectsChanged() }
        defer { lastParameters = parameters; lastRevision = revision }
        guard let state = snapshot["state"] as? Data,
              let effect = editor.project.allEffects.first(where: { $0.id == effectID }), state != effect.state else { return }
        editor.invalidateMixCache()
        if !editor.dirty || Date().timeIntervalSince(lastChange) > 0.5 { editor.checkpoint() }
        editor.setEffectState(state, effectID: effectID)
        lastChange = Date(); editor.update()
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
        label.font = effectsControlFont; label.lineBreakMode = .byTruncatingTail
        textField = label; addSubview(label)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        textField?.frame = NSRect(x: 8, y: bounds.midY - 9, width: max(0, bounds.width - 16), height: 18)
    }
}

final class CatalogPluginRow: NSTableCellView {
    let name: NSTextField
    let install: EffectActionButton
    init(plugin: CatalogPlugin, enabled: Bool, action: @escaping () -> Void) {
        name = NSTextField(labelWithString: plugin.name + "  [VST3]")
        install = EffectActionButton("Install", invoke: action)
        super.init(frame: .zero)
        name.font = effectsControlFont; name.lineBreakMode = .byTruncatingTail; textField = name
        toolTip = plugin.maker + " · " + plugin.category + " · " + plugin.version + "\n" + plugin.description
        install.isEnabled = enabled; applyEffectsButtonFont(install)
        install.setAccessibilityLabel("Install " + plugin.name)
        addSubview(name); addSubview(install)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        install.frame = NSRect(x: bounds.maxX - 72, y: bounds.midY - 12, width: 64, height: 24)
        name.frame = NSRect(x: 8, y: bounds.midY - 9, width: max(0, install.frame.minX - 16), height: 18)
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
    var catalog: [CatalogPlugin] = (try? PluginCatalog.bundled.get()) ?? []
    private(set) var catalogMatches: [CatalogPlugin] = []
    var canInstall = true { didSet { if canInstall != oldValue { results.reloadData() } } }
    var onInstall: ((CatalogPlugin) -> Void)?
    private var resultCount: Int { matches.count + catalogMatches.count }
    private(set) var selectedURL: URL?
    var onChoose: ((URL) -> Void)?
    private var prepared = false
    override init(frame: NSRect) {
        super.init(frame: frame)
        title = "Choose plug-in…"; bezelStyle = .rounded; font = effectsControlFont
        search.font = effectsControlFont
        alignment = .left; lineBreakMode = .byTruncatingTail
        image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil); imagePosition = .imageTrailing
        target = self; action = #selector(showPicker)
        setAccessibilityLabel("Search installed VST and VST3 plug-ins")
        vst3Only.setButtonType(.switch); vst3Only.state = .on
        applyEffectsButtonFont(vst3Only)
        vst3Only.target = self; vst3Only.action = #selector(toggleVST3Only)
    }
    required init?(coder: NSCoder) { fatalError() }
    private var available: [URL] {
        installed.filter { vst3Only.state != .on || $0.pathExtension.lowercased() == "vst3" }
    }
    private func updateSelection() {
        let urls = available
        if !urls.contains(where: { $0 == selectedURL }) { selectedURL = urls.first }
        title = selectedURL.map(Self.displayName) ?? (catalog.isEmpty ? (vst3Only.state == .on ? "No installed VST3 effects found" : "No installed VST / VST3 effects found") : "Choose plug-in…")
        applyEffectsButtonFont(self)
    }
    func setPlugins(_ urls: [URL]) {
        installed = urls; updateSelection(); filter(search.stringValue)
    }
    @objc func toggleVST3Only() { updateSelection(); filter(search.stringValue) }
    static func displayName(_ url: URL) -> String { url.deletingPathExtension().lastPathComponent + "  [" + url.pathExtension.uppercased() + "]" }
    func filter(_ query: String) {
        let words = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        matches = available.filter { url in words.allSatisfy { Self.displayName(url).range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil } }
        catalogMatches = catalog.filter { plugin in plugin.installed(in: installed) == nil && words.allSatisfy { plugin.searchText.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil } }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        results.reloadData()
        if resultCount > 0 { results.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
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
    func numberOfRows(in tableView: NSTableView) -> Int { resultCount }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if matches.indices.contains(row) { return PluginNameRow(name: Self.displayName(matches[row])) }
        let index = row - matches.count
        guard catalogMatches.indices.contains(index) else { return nil }
        let plugin = catalogMatches[index]
        return CatalogPluginRow(plugin: plugin, enabled: canInstall) { [weak self] in self?.install(plugin) }
    }
    func controlTextDidChange(_ obj: Notification) { filter(search.stringValue) }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.moveDown(_:)) || selector == #selector(NSResponder.moveUp(_:)) {
            guard resultCount > 0 else { return true }
            let row = max(0, min(resultCount - 1, results.selectedRow + (selector == #selector(NSResponder.moveDown(_:)) ? 1 : -1)))
            results.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false); results.scrollRowToVisible(row); return true
        }
        if selector == #selector(NSResponder.insertNewline(_:)) { choose(); return true }
        if selector == #selector(NSResponder.cancelOperation(_:)) { popover.close(); return true }
        return false
    }
    func selectInstalled(_ url: URL) {
        guard available.contains(url) else { return }
        selectedURL = url; title = Self.displayName(url); applyEffectsButtonFont(self)
    }
    private func install(_ plugin: CatalogPlugin) {
        guard canInstall else { return }
        popover.close(); onInstall?(plugin)
    }
    @objc func choose() {
        // A catalog row selects only; installation requires its Install button.
        guard matches.indices.contains(results.selectedRow) else { return }
        let url = matches[results.selectedRow]
        selectInstalled(url)
        popover.close(); onChoose?(url)
    }
}

final class EffectActionButton: PointerButton {
    private let invoke: () -> Void
    init(_ title: String, invoke: @escaping () -> Void) {
        self.invoke = invoke
        super.init(frame: .zero)
        self.title = title; identifier = NSUserInterfaceItemIdentifier(title); bezelStyle = .rounded; controlSize = .small
        font = effectsControlFont; target = self; action = #selector(invokeAction)
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

/// Keep rack commands in this window; text fields retain native editing keys.
final class EffectsRackWindow: PopupWindow {
    var command: ((UInt16) -> Bool)?
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if !acceptsEditorShortcuts, modifiers == .command, !(firstResponder is NSTextView), command?(event.keyCode) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

final class EffectsTableView: NSTableView {
    var contextualMenu: ((NSEvent) -> NSMenu?)?
    override func menu(for event: NSEvent) -> NSMenu? { contextualMenu?(event) }
}

final class EffectsWindow: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    unowned let editor: Editor
    let trackID: UUID
    var window: NSWindow!
    let table = EffectsTableView()
    let plugins = PluginPicker(frame: .zero)
    let allEffects = PointerButton(title: "Activate all", target: nil, action: nil)
    static let clipboardType = NSPasteboard.PasteboardType("enotix.Sounder.effects.json")
    var pasteboard = NSPasteboard.general
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
        window = EffectsRackWindow(contentRect: NSRect(x: 0, y: 0, width: 507, height: 399))
        window.title = "FX · " + (trackID == Project.masterID ? "Master" : editor.project.tracks[index!].name); window.delegate = self; window.isReleasedWhenClosed = false
        let root = NSView(); root.wantsLayer = true; root.layer?.backgroundColor = panelColor.cgColor; window.contentView = root
        window.level = .floating; window.hidesOnDeactivate = false
        plugins.frame = NSRect(x: 16, y: 353, width: 221, height: 30); root.addSubview(plugins)
        plugins.onChoose = { [weak self] url in self?.add(url) }
        plugins.onInstall = { [weak self] plugin in
            guard let self else { return }
            self.editor.installPlugin(plugin) { [weak self] url in
                guard let self, self.exists else { return }
                self.scan(); self.plugins.selectInstalled(url); self.add(url)
            }
        }
        if case .failure(let error) = PluginCatalog.bundled { editor.error(error) }
        let browse = PointerButton(title: "Open", target: self, action: #selector(browse)); browse.bezelStyle = .rounded; applyEffectsButtonFont(browse); browse.frame = NSRect(x: 243, y: 352, width: 78, height: 32); root.addSubview(browse)
        let rescan = PointerButton(title: "Rescan", target: self, action: #selector(scan)); rescan.bezelStyle = .rounded; applyEffectsButtonFont(rescan); rescan.frame = NSRect(x: 327, y: 352, width: 66, height: 32); root.addSubview(rescan)
        allEffects.target = self; allEffects.action = #selector(toggleAll)
        allEffects.bezelStyle = .rounded; allEffects.font = effectsControlFont
        allEffects.frame = NSRect(x: 399, y: 352, width: 92, height: 32); root.addSubview(allEffects)
        let scroll = NSScrollView(frame: NSRect(x: 16, y: 16, width: 475, height: 326)); scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("effect")); column.width = 455
        table.addTableColumn(column); table.headerView = nil; table.rowHeight = 40
        table.style = .plain; table.intercellSpacing = .zero
        table.allowsMultipleSelection = true
        table.contextualMenu = { [weak self] event in self?.contextMenu(for: event) }
        (window as? EffectsRackWindow)?.command = { [weak self] key in
            guard let self else { return false }
            switch key {
            case 0: self.table.selectAll(nil)
            case 8: self.copyEffects(nil)
            case 9: self.pasteEffects(nil)
            default: return false
            }
            return true
        }
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.dataSource = self; table.delegate = self; table.target = self; table.doubleAction = #selector(configure)
        table.registerForDraggedTypes([Self.dragType]); table.setDraggingSourceOperationMask(.move, forLocal: true)
        table.setAccessibilityLabel("Effect processing order")
        table.frame = NSRect(origin: .zero, size: scroll.contentSize); table.autoresizingMask = [.width]
        scroll.documentView = table; root.addSubview(scroll)
        (window as? PopupWindow)?.installHeader()
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
    @objc func toggleAll() { editor.toggleAllEffects(for: trackID) }
    func reload(notifyEditor: Bool = true) {
        table.reloadData()
        refreshAvailability()
        if let window, exists { window.title = "FX · " + (trackID == Project.masterID ? "Master" : editor.project.tracks[index!].name) }
        if notifyEditor { editor.update() }
    }
    func refreshAvailability() {
        plugins.canInstall = exists && editor.canEditEffects && !editor.isInstallingPlugin
        allEffects.title = editor.effectsBypassed(for: trackID) ? "Activate all" : "Bypass all"
        applyEffectsButtonFont(allEffects)
        allEffects.isEnabled = exists && !effects.isEmpty && editor.canToggleEffects
    }
    func numberOfRows(in tableView: NSTableView) -> Int { effects.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard effects.indices.contains(row) else { return nil }
        let effect = effects[row], id = effect.id
        let missing = !FileManager.default.fileExists(atPath: effect.path)
        let chainBypassed = editor.effectsBypassed(for: trackID)
        let enabledMark = effect.bypassed ? "" : " •"
        let name = NSTextField(labelWithString: "\(row + 1).  \(effect.name)  [\(effect.format)]\(enabledMark)" + (missing ? " · missing" : ""))
        name.lineBreakMode = .byTruncatingTail; name.font = effectsControlFont
        name.textColor = effect.bypassed || chainBypassed ? .secondaryLabelColor : .labelColor
        name.toolTip = effect.name + "\n" + effect.path
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let open = EffectActionButton("Open") { [weak self] in self?.editPlugin(id: id, native: true) }
        let up = EffectActionButton("Up") { [weak self] in self?.move(id: id, by: -1) }
        let down = EffectActionButton("Down") { [weak self] in self?.move(id: id, by: 1) }
        let bypass = EffectActionButton("Bypass") { [weak self] in self?.bypass(id: id) }
        bypass.setButtonType(.pushOnPushOff); bypass.state = effect.bypassed || chainBypassed ? .off : .on
        let remove = EffectActionButton("Remove") { [weak self] in self?.remove(id: id) }
        up.isEnabled = row > 0; down.isEnabled = row < effects.count - 1
        bypass.activeAppearanceColor = .systemGreen
        bypass.contentTintColor = .secondaryLabelColor
        for (button, symbol, help) in [(open, "slider.horizontal.3", "Open plugin"), (up, "arrow.up", "Move up"), (down, "arrow.down", "Move down"), (bypass, "power", "Bypass"), (remove, "trash", "Remove")] {
            button.title = ""; button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: help)
            button.imagePosition = .imageOnly; button.isBordered = false; button.toolTip = help
            button.setAccessibilityLabel(help + " " + effect.name)
        }
        bypass.toolTip = effect.bypassed ? "Enable" : "Disable"
        bypass.setAccessibilityLabel((bypass.toolTip ?? "") + " " + effect.name)
        return EffectRowView(name: name, controls: [(open, 26), (up, 26), (down, 26), (remove, 26), (bypass, 26)])
    }
    var selectedEffects: [PluginEffect] { table.selectedRowIndexes.compactMap { effects.indices.contains($0) ? effects[$0] : nil } }
    var canCopyEffects: Bool { exists && editor.canEditEffects && !selectedEffects.isEmpty }
    private func clipboardEffects() -> [PluginEffect]? {
        guard let data = pasteboard.data(forType: Self.clipboardType),
              let items = try? JSONDecoder().decode([PluginEffect].self, from: data), !items.isEmpty,
              items.allSatisfy({ ["vst", "vst3"].contains(URL(fileURLWithPath: $0.path).pathExtension.lowercased()) }) else { return nil }
        return items
    }
    var canPasteEffects: Bool { exists && editor.canEditEffects && clipboardEffects() != nil }
    func contextMenu(for event: NSEvent) -> NSMenu {
        let row = table.row(at: table.convert(event.locationInWindow, from: nil))
        if row >= 0 && !table.selectedRowIndexes.contains(row) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        window.makeFirstResponder(table)
        let menu = NSMenu(); menu.autoenablesItems = false
        let copy = NSMenuItem(title: "Copy", action: #selector(copyEffects(_:)), keyEquivalent: "c")
        copy.target = self; copy.isEnabled = canCopyEffects; menu.addItem(copy)
        let paste = NSMenuItem(title: "Paste", action: #selector(pasteEffects(_:)), keyEquivalent: "v")
        paste.target = self; paste.isEnabled = canPasteEffects; menu.addItem(paste)
        return menu
    }
    @objc func copyEffects(_ sender: Any?) { _ = copySelection() }
    @discardableResult func copySelection() -> Bool {
        guard canCopyEffects else { return false }
        do {
            var copied = selectedEffects
            for index in copied.indices {
                if let host = editor.pluginHosts[copied[index].id] { copied[index].state = try host.saveState() }
            }
            let data = try JSONEncoder().encode(copied)
            pasteboard.clearContents(); return pasteboard.setData(data, forType: Self.clipboardType)
        } catch { editor.error(error); return false }
    }
    @objc func pasteEffects(_ sender: Any?) { _ = pasteSelection() }
    @discardableResult func pasteSelection() -> Bool {
        guard exists, editor.canEditEffects, let copied = clipboardEffects() else { return false }
        plugins.popover.close()
        do {
            var additions: [PluginEffect] = [], hosts: [UUID: SNPluginHost] = [:]
            for original in copied {
                var effect = original; effect.id = UUID()
                let host = try SNPluginHost(path: effect.path, classID: effect.classID, state: effect.state, sampleRate: editor.project.audioFormat.sampleRate)
                additions.append(effect); hosts[effect.id] = host
            }
            let first = effects.count
            try editor.capturePluginStates()
            editor.checkpoint()
            editor.pluginHosts.merge(hosts) { current, _ in current }
            effects.append(contentsOf: additions)
            editor.effectsChanged(); reload()
            table.selectRowIndexes(IndexSet(integersIn: first..<(first + additions.count)), byExtendingSelection: false)
            table.scrollRowToVisible(first)
            window.makeFirstResponder(table)
            return true
        } catch { editor.error(error); return false }
    }
    @objc func scan() { installed = PluginProcessing.installed(); plugins.setPlugins(installed) }
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard effects.indices.contains(row), table.selectedRowIndexes.count <= 1 else { return nil }
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
            editor.checkpoint()
            // Register before effectsChanged can start background preparation.
            // The native editor and the audio graph must share this processor.
            editor.pluginHosts[effect.id] = host
            effects.append(effect); editor.effectsChanged(); reload(); editor.notifications.show("Effect added", style: .success); table.selectRowIndexes(IndexSet(integer: effects.count - 1), byExtendingSelection: false)
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
        editor.notifications.show("Effect removed", style: .error)
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
