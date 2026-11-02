import AppKit
import AVFoundation

final class PointerButton: NSButton {
    private var pointerTracking: NSTrackingArea?
    private(set) var isHovering = false
    var contentPadding = NSSize.zero { didSet { invalidateIntrinsicContentSize() } }
    override var intrinsicContentSize: NSSize {
        let size = super.intrinsicContentSize
        return NSSize(width: size.width + contentPadding.width * 2, height: size.height + contentPadding.height * 2)
    }
    private func drawHover() {
        let rect: NSRect
        let path: NSBezierPath
        if imagePosition == .imageOnly {
            let size = max(0, min(bounds.width, bounds.height) - 2)
            rect = NSRect(x: bounds.midX - size / 2, y: bounds.midY - size / 2, width: size, height: size)
            path = NSBezierPath(ovalIn: rect)
        } else {
            rect = bounds.insetBy(dx: 0.5, dy: 1)
            path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        }
        NSColor.labelColor.withAlphaComponent(isBordered ? 0.06 : 0.10).setFill(); path.fill()
        if isBordered { NSColor.labelColor.withAlphaComponent(0.16).setStroke(); path.lineWidth = 0.7; path.stroke() }
    }
    var activeAppearanceColor: NSColor? { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        let hover = isHovering && isEnabled && window?.isKeyWindow == true
        defer { if hover { drawHover() } }
        guard state == .on, isEnabled, let color = activeAppearanceColor else { super.draw(dirtyRect); return }
        if imagePosition == .imageOnly, let image {
            let tinted = NSImage(size: image.size, flipped: false) { rect in
                image.draw(in: rect)
                color.setFill(); rect.fill(using: .sourceAtop)
                return true
            }
            let scale = min(1, (bounds.width - 2) / image.size.width, (bounds.height - 2) / image.size.height)
            let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
            tinted.draw(in: NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height))
        } else {
            color.setFill(); NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 1), xRadius: 5, yRadius: 5).fill()
            let attributes: [NSAttributedString.Key: Any] = [.font: font ?? NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.black]
            let size = (title as NSString).size(withAttributes: attributes)
            (title as NSString).draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: attributes)
        }
    }
    var interactionCursor: NSCursor = .arrow {
        didSet { window?.invalidateCursorRects(for: self) }
    }
    override var isEnabled: Bool {
        didSet {
            if isEnabled != oldValue {
                if !isEnabled { isHovering = false }
                needsDisplay = true; window?.invalidateCursorRects(for: self)
            }
        }
    }
    override func resetCursorRects() {
        super.resetCursorRects()
        if isEnabled { addCursorRect(bounds, cursor: interactionCursor) }
    }
    override func updateTrackingAreas() {
        if let pointerTracking { removeTrackingArea(pointerTracking) }
        super.updateTrackingAreas()
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .cursorUpdate, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area); pointerTracking = area
    }
    override func mouseEntered(with event: NSEvent) { isHovering = isEnabled; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { isHovering = false; needsDisplay = true }
    override func cursorUpdate(with event: NSEvent) {
        // Native toolbar tracking can supersede the custom view's cursor rectangles.
        (isEnabled ? interactionCursor : NSCursor.arrow).set()
    }
}

final class ProjectNameLabel: NSTextField {
    override func mouseDown(with event: NSEvent) {
        if isEnabled { sendAction(action, to: target) }
    }
    override func resetCursorRects() {
        super.resetCursorRects()
        if isEnabled { addCursorRect(bounds, cursor: .iBeam) }
    }
}

// Both display and editing occupy the same text geometry; no stack-view swap.
final class ProjectNameView: NSView {
    let label: ProjectNameLabel
    let field: InlineNameField
    private let dirtyMark = NSTextField(labelWithString: "  •")
    private var nameWidth: NSLayoutConstraint!
    init(label: ProjectNameLabel, field: InlineNameField) {
        self.label = label; self.field = field
        super.init(frame: .zero)
        addSubview(label); addSubview(field); addSubview(dirtyMark)
        dirtyMark.font = label.font; dirtyMark.textColor = label.textColor; dirtyMark.isHidden = true
        nameWidth = widthAnchor.constraint(equalToConstant: intrinsicContentSize.width)
        nameWidth.isActive = true
        field.textChanged = { [weak self] in self?.updateSize() }
    }
    required init?(coder: NSCoder) { fatalError() }
    private var showsDirtyMark: Bool { field.isRenaming && label.stringValue.hasSuffix("  •") }
    private var editingWidth: CGFloat {
        let measurement = NSTextField(labelWithString: field.stringValue)
        measurement.font = field.font
        return measurement.intrinsicContentSize.width + 4
    }
    override var intrinsicContentSize: NSSize {
        let display = NSTextField(labelWithString: label.stringValue)
        display.font = label.font
        let width = field.isRenaming ? editingWidth + (showsDirtyMark ? dirtyMark.intrinsicContentSize.width : 0) : display.intrinsicContentSize.width + 4
        return NSSize(width: min(640, max(4, width)), height: display.intrinsicContentSize.height)
    }
    func updateSize() { nameWidth.constant = intrinsicContentSize.width; invalidateIntrinsicContentSize(); needsLayout = true }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }
    override func layout() {
        super.layout()
        label.frame = bounds
        let suffix = showsDirtyMark ? dirtyMark.intrinsicContentSize.width : 0
        field.frame = NSRect(x: 0, y: 0, width: max(4, bounds.width - suffix), height: bounds.height)
        dirtyMark.isHidden = !showsDirtyMark
        dirtyMark.frame = NSRect(x: field.frame.maxX, y: 0, width: suffix, height: bounds.height)
    }
}

// Settings use a compact form layout rather than NSAlert's reserved icon area.
final class CompactSettingsAlert: NSAlert {
    var minimumWidth: CGFloat = 340
    var minimumButtonWidth: CGFloat = 96
    var buttonSpacing: CGFloat = 12
    private var prepared = false
    override func layout() {
        if !prepared { prepared = true; super.layout() }
        let panel = super.window
        let form = accessoryView
        let errorHeight: CGFloat = informativeText.isEmpty ? 0 : 38
        let buttonWidths = buttons.map { max(minimumButtonWidth, $0.intrinsicContentSize.width + 12) }
        let width = max(minimumWidth, (form?.frame.width ?? 0) + 40, buttonWidths.reduce(0, +) + CGFloat(max(0, buttons.count - 1)) * buttonSpacing + 40)
        let formY: CGFloat = 66 + errorHeight
        let titleY = formY + (form?.frame.height ?? 0) + 12
        let root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: titleY + 24 + 16))
        panel.setContentSize(root.frame.size); panel.contentView = root
        let heading = NSTextField(labelWithString: messageText)
        heading.font = .systemFont(ofSize: 17, weight: .semibold)
        heading.frame = NSRect(x: 20, y: titleY, width: width - 40, height: 24); root.addSubview(heading)
        if let form { form.removeFromSuperview(); form.frame.origin = NSPoint(x: 20, y: formY); root.addSubview(form) }
        if !informativeText.isEmpty {
            let error = NSTextField(wrappingLabelWithString: informativeText)
            error.font = .systemFont(ofSize: 11); error.textColor = .secondaryLabelColor
            error.frame = NSRect(x: 20, y: 56, width: width - 40, height: 36); root.addSubview(error)
        }
        var right = width - 20
        // Preserve NSAlert response order while placing the primary action at the right.
        for (index, button) in buttons.enumerated() {
            let buttonWidth = buttonWidths[index]
            right -= buttonWidth
            button.removeFromSuperview(); button.frame = NSRect(x: right, y: 16, width: buttonWidth, height: 32)
            button.target = self; button.action = #selector(chosen(_:)); button.tag = index
            button.keyEquivalent = index == 0 ? "\r" : index == 1 ? "\u{1b}" : ""
            root.addSubview(button); right -= buttonSpacing
        }
    }
    @objc private func chosen(_ sender: NSButton) {
        NSApp.stopModal(withCode: NSApplication.ModalResponse(rawValue: NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + sender.tag))
    }
    override func runModal() -> NSApplication.ModalResponse {
        let responder = window.initialFirstResponder
        layout(); window.center()
        if let responder { window.initialFirstResponder = responder }
        window.makeKeyAndOrderFront(nil)
        if let responder { window.makeFirstResponder(responder) }
        let response = NSApp.runModal(for: window)
        window.orderOut(nil)
        return response
    }
}

final class NormalizeDialog {
    let alert = CompactSettingsAlert()
    let field: NSTextField
    init(level: Double) {
        field = NSTextField(string: String(format: "%g", level))
        alert.messageText = "Normalize"
        let form = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 28))
        let label = NSTextField(labelWithString: "Maximum level")
        label.frame = NSRect(x: 0, y: 3, width: 130, height: 22); form.addSubview(label)
        field.frame = NSRect(x: 140, y: 1, width: 100, height: 26); field.setAccessibilityLabel("Maximum level (dBFS)"); form.addSubview(field)
        let unit = NSTextField(labelWithString: "dBFS"); unit.frame = NSRect(x: 250, y: 3, width: 50, height: 22); form.addSubview(unit)
        alert.accessoryView = form; alert.addButton(withTitle: "Process"); alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
    }
    func runModal() -> Double? {
        while alert.runModal() == .alertFirstButtonReturn {
            let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
            if let value = Double(text), (try? FragmentNormalization.validate(value)) != nil { return value }
            alert.informativeText = "Enter a maximum level between -120 and 0 dBFS."
        }
        return nil
    }
}

final class FragmentSettingsDialog: NSObject, NSTextFieldDelegate {
    let alert = CompactSettingsAlert()
    let volume = NSTextField(), pan = NSTextField(), fadeIn = NSTextField(), fadeOut = NSTextField()
    let volumeSlider = NSSlider(value: 0, minValue: -48, maxValue: 24, target: nil, action: nil)
    let panSlider = NSSlider(value: 0, minValue: -90, maxValue: 90, target: nil, action: nil)
    let inCurve = NSPopUpButton(), outCurve = NSPopUpButton()
    let clip: Clip
    let store: AudioStore
    private(set) var peak: Double?
    init(clip: Clip, store: AudioStore, peak: Double? = nil) {
        self.clip = clip; self.store = store; self.peak = peak
        super.init()
        alert.messageText = "Edit fragment"
        let form = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 190))
        for (title, y) in [("Volume", CGFloat(156)), ("Pan", 112), ("Fade in", 56), ("Fade out", 12)] {
            let label = NSTextField(labelWithString: title); label.frame = NSRect(x: 0, y: y + 2, width: 110, height: 24); form.addSubview(label)
        }
        for (slider, field, value, y, unit) in [(volumeSlider, volume, clip.volumeDB, CGFloat(156), "dB"), (panSlider, pan, clip.pan, 112, "°")] {
            slider.frame = NSRect(x: 116, y: y, width: 216, height: 24); slider.target = self; slider.action = #selector(sliderChanged(_:)); form.addSubview(slider)
            field.stringValue = String(format: "%g", value); field.frame = NSRect(x: 344, y: y, width: 80, height: 24); field.delegate = self; form.addSubview(field)
            let label = NSTextField(labelWithString: unit); label.frame = NSRect(x: 432, y: y + 2, width: 45, height: 24); form.addSubview(label)
            slider.doubleValue = value
        }
        for (field, popup, value, curve, y) in [(fadeIn, inCurve, clip.fadeInMS, clip.fadeInCurve, CGFloat(56)), (fadeOut, outCurve, clip.fadeOutMS, clip.fadeOutCurve, 12)] {
            field.stringValue = String(format: "%g", value); field.frame = NSRect(x: 116, y: y, width: 80, height: 24); form.addSubview(field)
            let label = NSTextField(labelWithString: "ms"); label.frame = NSRect(x: 204, y: y + 2, width: 32, height: 24); form.addSubview(label)
            popup.addItems(withTitles: FadeCurve.allCases.map(\.title)); popup.selectItem(at: FadeCurve.allCases.firstIndex(of: curve)!)
            popup.frame = NSRect(x: 244, y: y - 2, width: 234, height: 28); form.addSubview(popup)
        }
        for (control, title) in [(volume, "Volume (dB)"), (pan, "Pan (degrees)"), (fadeIn, "Fade in (ms)"), (fadeOut, "Fade out (ms)")] { control.setAccessibilityLabel(title) }
        volumeSlider.setAccessibilityLabel("Volume"); panSlider.setAccessibilityLabel("Pan")
        inCurve.setAccessibilityLabel("Fade in curve"); outCurve.setAccessibilityLabel("Fade out curve")
        alert.accessoryView = form; alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel")
        alert.buttons[0].isEnabled = false; alert.window.initialFirstResponder = volume
        if let peak { prepare(peak) }
    }
    private func number(_ field: NSTextField) -> Double? {
        guard let value = Double(field.stringValue.replacingOccurrences(of: ",", with: ".")), value.isFinite else { return nil }; return value
    }
    private func prepare(_ peak: Double) {
        do {
            let maximum = try FragmentSettings.maximumVolume(clip: clip, peak: peak)
            self.peak = peak; volumeSlider.maxValue = maximum
            volumeSlider.toolTip = String(format: "Maximum without clipping: %.2f dB", maximum)
            volumeSlider.doubleValue = max(-48, min(number(volume) ?? clip.volumeDB, maximum))
            volume.stringValue = String(format: "%g", volumeSlider.doubleValue); alert.buttons[0].isEnabled = true
        } catch { alert.informativeText = error.localizedDescription; alert.buttons[0].isEnabled = false; alert.layout() }
    }
    @objc private func sliderChanged(_ sender: NSSlider) {
        (sender === volumeSlider ? volume : pan).stringValue = String(format: "%g", (sender.doubleValue * 100).rounded() / 100)
    }
    func controlTextDidEndEditing(_ notification: Notification) {
        if let field = notification.object as? NSTextField, let value = number(field) {
            let slider = field === volume ? volumeSlider : panSlider
            slider.doubleValue = max(slider.minValue, min(value, slider.maxValue))
            field.stringValue = String(format: "%g", slider.doubleValue)
        }
    }
    func runModal() -> FragmentSettings? {
        if peak == nil {
            let cached = store.cache[clip.source], rate = store.sampleRate
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                do {
                    let data = try cached ?? AudioStore.decode(URL(fileURLWithPath: clip.source), sampleRate: rate)
                    let measured = FragmentNormalization.peak(for: clip, data: data, sampleRate: rate)
                    DispatchQueue.main.async { [self] in
                        if store.sampleRate == rate { store.cache[clip.source] = data }
                        prepare(measured)
                    }
                } catch { DispatchQueue.main.async { [self] in alert.informativeText = error.localizedDescription; alert.layout() } }
            }
        }
        while alert.runModal() == .alertFirstButtonReturn {
            guard let peak, let volumeDB = number(volume), let panValue = number(pan), let first = number(fadeIn), let last = number(fadeOut) else { alert.informativeText = "Enter valid numeric values."; continue }
            var settings = FragmentSettings(clip)
            settings.volumeDB = volumeDB; settings.pan = panValue; settings.fadeInMS = first; settings.fadeOutMS = last
            settings.fadeInCurve = FadeCurve.allCases[inCurve.indexOfSelectedItem]; settings.fadeOutCurve = FadeCurve.allCases[outCurve.indexOfSelectedItem]
            do { return FragmentSettings(try settings.applying(to: clip, peak: peak)) }
            catch { alert.informativeText = error.localizedDescription }
        }
        return nil
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation, NSToolbarDelegate {
    var window: NSWindow!
    var editor: Editor!
    var timeline: Timeline!
    var notificationOverlay: ToastOverlay!
    var timeLabel: NSTextField!
    var tempoButton: NSButton!
    var bpmButton: NSButton!
    var metronomeButton: NSButton!
    var projectLabel: ProjectNameLabel!
    let projectNameField = InlineNameField(frame: .zero)
    var projectNameView: ProjectNameView!
    var qualityButton: NSButton!
    var playButton: NSButton!
    var recordButton: NSButton!
    var exportButton: NSButton!
    var editButtons: [NSButton] = []
    var fragmentMuteButton: NSButton!
    private var titlebarItems: [NSToolbarItem.Identifier: NSToolbarItem] = [:]
    private let titlebarOrder: [NSToolbarItem.Identifier] = [NSToolbarItem.Identifier("project"), NSToolbarItem.Identifier("quality"), .flexibleSpace, NSToolbarItem.Identifier("open"), NSToolbarItem.Identifier("save"), NSToolbarItem.Identifier("export")]
    var closingConfirmed = false
    var dialogAutomation: ((NSAlert) -> Void)?
    var fragmentDialogAutomation: ((FragmentSettingsDialog) -> Void)?
    private var shortcutMonitor: Any?
    func applicationDidFinishLaunching(_ notification: Notification) {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "enotix.Sounder") where app.processIdentifier != ProcessInfo.processInfo.processIdentifier { app.terminate() }
        do { editor = Editor(store: try AudioStore()) }
        catch { NSAlert(error: error).runModal(); NSApp.terminate(nil); return }
        NSApp.appearance = NSAppearance(named: .darkAqua)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 790), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Sounder"; window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true; window.backgroundColor = panelColor; window.minSize = NSSize(width: 1000, height: 600); window.delegate = self
        let content = NSView(); content.wantsLayer = true; content.layer?.backgroundColor = background.cgColor; window.contentView = content
        let stack = NSStackView(); stack.orientation = .vertical; stack.spacing = 0; stack.alignment = .leading; stack.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: content.leadingAnchor), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor), stack.topAnchor.constraint(equalTo: content.safeAreaLayoutGuide.topAnchor), stack.bottomAnchor.constraint(equalTo: content.bottomAnchor)])
        installTitlebarControls()
        let toolbarTopInset: CGFloat = 10 / 1.5
        let toolbar = NSStackView(); toolbar.orientation = .horizontal; toolbar.spacing = 14; toolbar.edgeInsets = NSEdgeInsets(top: toolbarTopInset, left: 22, bottom: 12, right: 22)
        playButton = button("Play / pause · Space", "play.fill", #selector(play))
        recordButton = button("Record · R", "record.circle", #selector(record)); recordButton.contentTintColor = .systemRed
        toolbar.addArrangedSubview(section("PLAYER", [button("Return to start", "backward.end.fill", #selector(rewind)), playButton, button("Stop and return to playback start · Escape", "stop.fill", #selector(stop)), recordButton]))
        let split = button("Split at playhead · S", "scissors", #selector(split)); let trim = button("Trim to ruler selection", "crop", #selector(trim)); let delete = button("Delete fragments · Delete", "trash", #selector(deleteClips))
        let join = button("Join selected fragments · ⌘J", "link", #selector(join))
        let normalize = button("Normalize · N", "waveform.path", #selector(normalize))
        fragmentMuteButton = button("Mute selected fragments", "speaker.slash", #selector(muteFragments))
        let importButton = button("Import audio · ⌘I", "square.and.arrow.down.on.square", #selector(importAudio))
        toolbar.addArrangedSubview(section("FRAGMENTS", [split, trim, delete, join, normalize, fragmentMuteButton, importButton]))
        let addTrack = button("Add track · ⌘T", "plus", #selector(addTrack)); let nest = button("Add nested track", "arrow.turn.down.right", #selector(nest)); let removeTrack = button("Delete track", "minus", #selector(removeTrack))
        toolbar.addArrangedSubview(section("TRACKS", [addTrack, nest, removeTrack])); editButtons = [split, trim, delete, join, normalize, fragmentMuteButton, addTrack, nest, removeTrack, importButton]
        toolbar.addArrangedSubview(section("VIEW", [button("Zoom out", "minus.magnifyingglass", #selector(zoomOut)), button("Zoom in", "plus.magnifyingglass", #selector(zoomIn))]))
        let spacer2 = NSView(); spacer2.setContentHuggingPriority(.defaultLow, for: .horizontal); toolbar.addArrangedSubview(spacer2)
        metronomeButton = PointerButton(image: NSImage(systemSymbolName: "metronome", accessibilityDescription: "Metronome")!, target: self, action: #selector(toggleMetronome))
        metronomeButton.setButtonType(.pushOnPushOff); metronomeButton.isBordered = false; metronomeButton.imagePosition = .imageOnly
        metronomeButton.widthAnchor.constraint(equalToConstant: 20).isActive = true
        metronomeButton.heightAnchor.constraint(equalToConstant: 24).isActive = true
        metronomeButton.setAccessibilityLabel("Metronome")
        (metronomeButton as? PointerButton)?.activeAppearanceColor = .systemOrange
        tempoButton = PointerButton(title: "Tempo", target: self, action: #selector(toggleTempo))
        tempoButton.bezelStyle = .rounded; tempoButton.setButtonType(.pushOnPushOff); tempoButton.controlSize = .small
        tempoButton.font = .systemFont(ofSize: 11, weight: .semibold)
        (tempoButton as? PointerButton)?.activeAppearanceColor = .systemOrange
        tempoButton.widthAnchor.constraint(equalToConstant: 47).isActive = true
        bpmButton = textButton("120 BPM", size: 18, action: #selector(editTempo), cursor: .iBeam)
        bpmButton.contentTintColor = .systemOrange; bpmButton.toolTip = "Edit tempo (4/4)"; bpmButton.isHidden = true
        timeLabel = NSTextField(labelWithString: "00:00.000"); timeLabel.font = .monospacedDigitSystemFont(ofSize: 18, weight: .light); timeLabel.textColor = accent
        bpmButton.font = timeLabel.font
        let positionDisplay = NSStackView(views: [timeLabel, bpmButton]); positionDisplay.spacing = 6; positionDisplay.alignment = .centerY
        let tempoSpacer = NSView()
        tempoSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let tempoRow = NSStackView(views: [positionDisplay, tempoSpacer, metronomeButton, tempoButton])
        tempoRow.orientation = .horizontal; tempoRow.alignment = .centerY; tempoRow.spacing = 2
        tempoRow.setCustomSpacing(6, after: metronomeButton)
        let timelineControls = NSView()
        tempoRow.translatesAutoresizingMaskIntoConstraints = false; timelineControls.addSubview(tempoRow)
        NSLayoutConstraint.activate([
            tempoRow.leadingAnchor.constraint(equalTo: timelineControls.leadingAnchor, constant: 22),
            tempoRow.trailingAnchor.constraint(equalTo: timelineControls.trailingAnchor, constant: -22),
            tempoRow.centerYAnchor.constraint(equalTo: timelineControls.centerYAnchor)
        ])
        add(toolbar, to: stack, height: 84 - (10 - toolbarTopInset))
        let scroll = NSScrollView(); scroll.hasHorizontalScroller = true; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.drawsBackground = false
        timeline = Timeline(editor); scroll.documentView = timeline; timeline.installHeaderControls(timelineControls); add(scroll, to: stack)
        notificationOverlay = ToastOverlay.install(in: content, center: editor.notifications)
        editor.changed = { [weak self] in self?.refresh() }
        buildMenu()
        shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            if self.handleShuttleShortcut(event) { return nil }
            return self.handlePhysicalShortcut(event) ? nil : event
        }
        NotificationCenter.default.addObserver(self, selector: #selector(cancelShuttle), name: NSApplication.didResignActiveNotification, object: NSApp)
        NotificationCenter.default.addObserver(self, selector: #selector(cancelShuttle), name: NSWindow.didResignKeyNotification, object: window)
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); refresh()
        if let index = CommandLine.arguments.firstIndex(of: "--import-ui-test"), index + 1 < CommandLine.arguments.count { importUITest(URL(fileURLWithPath: CommandLine.arguments[index + 1])); return }
        if CommandLine.arguments.contains("--ui-test") { uiTest() }
    }
    private func installTitlebarControls() {
        let icon = Bundle.main.url(forResource: "AppIcon", withExtension: "icns").flatMap { NSImage(contentsOf: $0) }
        if let icon { NSApp.applicationIconImage = icon }
        projectLabel = ProjectNameLabel(labelWithString: "MY PROJECT")
        projectLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        projectLabel.textColor = .secondaryLabelColor
        projectLabel.target = self; projectLabel.action = #selector(renameProject)
        projectLabel.setAccessibilityLabel("Project name")
        projectLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        projectLabel.toolTip = "Rename project"; projectLabel.lineBreakMode = .byTruncatingTail
        projectNameField.font = projectLabel.font; projectNameField.setAccessibilityLabel("Project name")
        projectNameField.textColor = projectLabel.textColor
        projectNameView = ProjectNameView(label: projectLabel, field: projectNameField)
        qualityButton = textButton(ProjectAudioFormat().label, size: 10, action: #selector(audioSettings)); qualityButton.toolTip = "Project audio settings"
        (qualityButton as? PointerButton)?.contentPadding = NSSize(width: 10, height: 5)
        let export = PointerButton(title: "Export", target: self, action: #selector(exportAudio)); export.bezelStyle = .rounded
        export.widthAnchor.constraint(equalToConstant: export.intrinsicContentSize.width + 16).isActive = true
        exportButton = export
        let controls: [(String, String, NSView)] = [
            ("project", "Project name", projectNameView),
            ("quality", "Project audio settings", qualityButton),
            ("open", "Open project", button("Open project", "folder", #selector(openProject))),
            ("save", "Save project", button("Save project", "square.and.arrow.down", #selector(saveProject))),
            ("export", "Export", export)
        ]
        for (id, label, view) in controls {
            let identifier = NSToolbarItem.Identifier(id)
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = label; item.toolTip = label; item.view = view
            // Custom toolbar views still receive the system glass bezel unless explicitly opted out.
            if id == "project" { item.isBordered = false }
            if ["open", "save", "export", "quality"].contains(id) { item.autovalidates = false }
            item.visibilityPriority = .high
            titlebarItems[identifier] = item
        }
        let toolbar = NSToolbar(identifier: "Sounder.ProjectToolbar")
        toolbar.delegate = self; toolbar.displayMode = .iconOnly; toolbar.allowsUserCustomization = false
        window.toolbarStyle = .unifiedCompact; window.toolbar = toolbar
    }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { titlebarOrder }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { titlebarOrder }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? { titlebarItems[identifier] }
    func uiTest() {
        do {
            let url = editor.audio.freshURL()
            let samples = (0..<384_000).map { i -> Float in
                let t = Double(i) / sampleRate
                let envelope = 0.1 + 0.65 * abs(sin(t * 2.3))
                return Float(sin(t * 2 * .pi * 220) * envelope)
            }
            let right = (0..<384_000).map { i -> Float in
                let t = Double(i) / sampleRate
                return Float(sin(t * 2 * .pi * 330) * (0.05 + 0.25 * abs(cos(t * 1.7))))
            }
            try editor.audio.write(AudioSignal(channels: [samples, right]), to: url)
            let a = Clip(name: "Voice · first take", source: url.path, start: 1, duration: 8, order: 1)
            let b = Clip(name: "Retake · newest on top", source: url.path, start: 5, offset: 1, duration: 4, order: 2)
            let parent = Track(name: "Voice", clips: [a, b])
            let child = Track(name: "Room tone", parent: parent.id, clips: [Clip(name: "Atmosphere", source: url.path, start: 0, duration: 8, order: 3)])
            editor.project = Project(tracks: [parent, child, Track(name: "Music")], nextOrder: 4)
            editor.selectedTrack = parent.id; editor.selection = [b.id]; editor.cursor = 5.8
            if let fxIndex = CommandLine.arguments.firstIndex(of: "--fx-ui-test"), fxIndex + 1 < CommandLine.arguments.count {
                let path = CommandLine.arguments[fxIndex + 1]
                let host = try SNPluginHost(path: path, classID: "", state: nil)
                editor.project.tracks[0].effects = [PluginEffect(name: host.pluginName, path: path, classID: host.classID, state: try host.saveState())]
                editor.project.tracks[1].effects = [PluginEffect(name: host.pluginName, path: path, classID: host.classID, state: try host.saveState(), bypassed: true)]
            }
            refresh()
            if CommandLine.arguments.contains("--live-recording-ui-test") { try liveRecordingUITest(originalURL: url); return }
            if CommandLine.arguments.contains("--button-hover-ui-test") { try verifyButtonHoverUI() }
            if CommandLine.arguments.contains("--project-file-controls-ui-test") { try verifyProjectFileControlsUI() }
            if CommandLine.arguments.contains("--fragments-system-menu-ui-test") { try verifyFragmentsSystemMenuUI() }
            if CommandLine.arguments.contains("--fragment-fades-ui-test") { try verifyFragmentFadesUI() }
            if CommandLine.arguments.contains("--track-meters-ui-test") { try verifyTrackMetersUI() }
            if CommandLine.arguments.contains("--track-solo-ui-test") { try verifyTrackSoloUI() }
            if CommandLine.arguments.contains("--tempo-snapping-ui-test") { try verifyTempoSnappingUI() }
            if CommandLine.arguments.contains("--fragment-settings-ui-test") { try verifyFragmentSettingsUI() }
            if CommandLine.arguments.contains("--fragment-mute-ui-test") { try verifyFragmentMuteUI() }
            if CommandLine.arguments.contains("--normalize-ui-test") { try verifyNormalizationUI() }
            if CommandLine.arguments.contains("--stop-return-ui-test") { try verifyStopReturnUI() }
            if CommandLine.arguments.contains("--physical-shortcuts-ui-test") { try verifyPhysicalShortcutsUI() }
            if CommandLine.arguments.contains("--tap-tempo-ui-test") { try verifyTapTempoUI() }
            if CommandLine.arguments.contains("--tempo-ui-test") { try verifyTempoUI() }
            if CommandLine.arguments.contains("--export-ui-test") { try verifyExportUI() }
            if CommandLine.arguments.contains("--restart-ui-test") { try verifyRestartUI() }
            if CommandLine.arguments.contains("--mute-ui-test") { try verifyMuteUI() }
            if CommandLine.arguments.contains("--zoom-ui-test") { try verifyZoomUI() }
            if CommandLine.arguments.contains("--range-ui-test") { try verifyRangeUI() }
            if CommandLine.arguments.contains("--shuttle-ui-test") { try verifyShuttleUI() }
            if CommandLine.arguments.contains("--boundary-seek-ui-test") { try verifyBoundarySeekUI() }
            if CommandLine.arguments.contains("--playhead-ui-test") { try verifyPlayheadUI() }
            if CommandLine.arguments.contains("--track-name-ui-test") { try verifyTrackNameUI() }
            if CommandLine.arguments.contains("--settings-ui-test") { try verifySettingsUI() }
            if CommandLine.arguments.contains("--notifications-ui-test") { try verifyNotificationInteractions(); finishNotificationUITest(audioURL: url); return }
            if CommandLine.arguments.contains("--fragment-clipboard-ui-test") { try verifyFragmentClipboardUI() }
            if CommandLine.arguments.contains("--fragment-menu-ui-test") { try verifyFragmentMenuUI() }
            if CommandLine.arguments.contains("--group-fragment-drag-ui-test") { try verifyGroupFragmentDragUI() }
            if CommandLine.arguments.contains("--import-placement-ui-test") { try verifyImportPlacementUI() }
            if CommandLine.arguments.contains("--fragment-snap-ui-test") { try verifyFragmentSnapUI() }
            if CommandLine.arguments.contains("--fragment-resize-ui-test") { try verifyFragmentResizeUI() }
            if CommandLine.arguments.contains("--marquee-ui-test") { try verifyMarqueeUI() }
            if CommandLine.arguments.contains("--track-drag-ui-test") { try verifyTrackDragUI() }
            if CommandLine.arguments.contains("--pinned-ruler-ui-test") { try verifyPinnedRulerUI() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                self.window.contentView!.layoutSubtreeIfNeeded()
                let content = self.window.contentView!
                let view = CommandLine.arguments.contains("--snapshot-window") ? (content.superview ?? content) : content
                if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    if let pathIndex = CommandLine.arguments.firstIndex(of: "--snapshot"), pathIndex + 1 < CommandLine.arguments.count {
                        try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: CommandLine.arguments[pathIndex + 1]))
                    }
                }
                if CommandLine.arguments.contains("--fx-ui-test"), let snapshotIndex = CommandLine.arguments.firstIndex(of: "--snapshot"), snapshotIndex + 1 < CommandLine.arguments.count {
                    let destination = URL(fileURLWithPath: CommandLine.arguments[snapshotIndex + 1]).deletingPathExtension().appendingPathExtension("rack.png")
                    EffectsWindow(editor: self.editor, trackID: child.id).run(snapshot: destination)
                }
                try? FileManager.default.removeItem(at: url)
                print("PASS: AppKit window and waveform timeline rendered")
                NSApp.terminate(nil)
            }
        } catch { fputs("UI test failed: \(error)\n", stderr); exit(1) }
    }
    func liveRecordingUITest(originalURL: URL) throws {
        let inputFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let session = try LiveRecorder(url: editor.audio.freshURL(), format: editor.project.audioFormat, inputFormat: inputFormat)
        try session.start(); editor.cursor = 1; editor.activateRecording(session)
        let initialClips = editor.project.tracks[0].clips.count
        var inputFrames = 0
        let feed = Timer(timeInterval: 0.04, repeats: true) { timer in
            if inputFrames >= 144_000 { timer.invalidate(); return }
            let count = min(1920, 144_000 - inputFrames)
            session.writer.append(captureTestBuffer(format: inputFormat, start: inputFrames, frames: count))
            inputFrames += count
        }
        RunLoop.main.add(feed, forMode: .common)
        func snapshot(later: Bool) {
            guard let index = CommandLine.arguments.firstIndex(of: "--snapshot"), index + 1 < CommandLine.arguments.count else { return }
            let original = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            let path = later ? original.deletingPathExtension().appendingPathExtension("later.png") : original
            let view = window.contentView!; view.layoutSubtreeIfNeeded()
            if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.effectiveAppearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: bitmap) }
                try? bitmap.representation(using: .png, properties: [:])?.write(to: path)
            }
        }
        var firstPeakCount = 0
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            guard self.editor.isRecording, self.editor.recordingPeaks.contains(where: { $0 > 0.1 }), self.editor.project.tracks[0].clips.count == initialClips else {
                fputs("FAIL: waveform is missing before Stop\n", stderr); exit(1)
            }
            firstPeakCount = self.editor.recordingPeaks.count; snapshot(later: false)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
            guard self.editor.isRecording, self.editor.recordingPeaks.count > firstPeakCount else { fputs("FAIL: live waveform did not grow\n", stderr); exit(1) }
            snapshot(later: true)
            print("PASS: recording waveform renders and grows while the take is still open")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
            feed.invalidate(); self.editor.stop()
            guard !self.editor.isRecording, self.editor.project.tracks[0].clips.count == initialClips + 1 else { fputs("FAIL: Stop did not save the live take\n", stderr); exit(1) }
            try? FileManager.default.removeItem(at: session.url); try? FileManager.default.removeItem(at: originalURL)
            self.editor.dirty = false; NSApp.terminate(nil)
        }
    }
    func verifyLongInlineName(_ field: InlineNameField) throws {
        guard let input = field.currentEditor() as? NSTextView else { throw SounderError.message("Name field has no text editor") }
        let original = input.string
        func replace(_ value: String) { input.selectAll(nil); input.insertText(value, replacementRange: input.selectedRange()) }
        replace(String(repeating: "W", count: 105))
        guard input.string.count == 100, field.stringValue.count == 100 else { throw SounderError.message("Name input exceeds 100 characters") }
        input.insertText("Z", replacementRange: input.selectedRange())
        guard input.string.count == 100 else { throw SounderError.message("Typing beyond 100 characters is accepted") }
        field.revealCaret()
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        let end = NSRange(location: (input.string as NSString).length, length: 0)
        let caret = input.firstRect(forCharacterRange: end, actualRange: nil)
        let visible = window.convertToScreen(field.convert(field.bounds, to: nil))
        guard caret.minX >= visible.minX - 1 && caret.maxX <= visible.maxX + 1 else { throw SounderError.message("End caret is clipped: caret=\(caret), field=\(visible), editor=\(input.visibleRect)") }
        replace(String(repeating: "👩🏽‍💻", count: 101))
        guard input.string.count == 100, input.string == String(repeating: "👩🏽‍💻", count: 100) else { throw SounderError.message("Name limit splits composed Unicode characters") }
        replace(original)
        print("PASS: 100-character name limit, paste, typing, emoji and visible end caret in \(field.accessibilityLabel() ?? "name")")
    }
    func verifyTrackNameUI() throws {
        func event(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: timeline.convert(point, to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        func type(_ text: String, into field: InlineNameField) {
            if let input = field.currentEditor() as? NSTextView { input.selectAll(nil); input.insertText(text, replacementRange: input.selectedRange()) }
            else { field.stringValue = text }
        }
        func nameInkRows() throws -> ClosedRange<Int> {
            let nameRect = timeline.trackNameHitRect(row: 0, depth: 0)
            let crop = NSRect(x: nameRect.minX, y: nameRect.minY - 3, width: max(1, nameRect.width - 3), height: nameRect.height + 6)
            timeline.displayIfNeeded()
            guard let bitmap = timeline.bitmapImageRepForCachingDisplay(in: crop) else { throw SounderError.message("Could not capture the track name") }
            timeline.cacheDisplay(in: crop, to: bitmap)
            var rows: [Int] = []
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.redComponent > 0.65 && color.greenComponent > 0.65 && color.blueComponent > 0.65 {
                        rows.append(y); break
                    }
                }
            }
            guard let low = rows.min(), let high = rows.max() else { throw SounderError.message("Track-name capture contains no text") }
            return low...high
        }
        let inkBefore = try nameInkRows()
        let name = NSPoint(x: 45, y: timeline.ruler + 20)
        timeline.mouseDown(with: event(.leftMouseDown, name)); timeline.mouseUp(with: event(.leftMouseUp, name))
        guard timeline.nameField.isRenaming, NSApp.modalWindow == nil else { throw SounderError.message("Track name did not open inline: track=\(String(describing: timeline.renamingTrack)), field=\(timeline.nameField.isRenaming), frame=\(timeline.nameField.frame), visible=\(timeline.visibleRect), name=\(timeline.trackNameHitRect(row: 0, depth: 0)), modal=\(String(describing: NSApp.modalWindow))") }
        let inkDuring = try nameInkRows()
        guard inkBefore == inkDuring else { throw SounderError.message("Track-name glyphs shift when editing begins: \(inkBefore) → \(inkDuring)") }
        print("PASS: Track-name glyphs retain identical vertical pixel bounds when editing begins")
        let initialNameWidth = timeline.nameField.frame.width
        guard !timeline.nameField.drawsBackground, initialNameWidth <= timeline.trackNameHitRect(row: 0, depth: 0).width + 5,
              (timeline.nameField.currentEditor() as? NSTextView)?.selectedRange().length == 0 else { throw SounderError.message("Track editor changes the label appearance or selects its text") }
        try verifyLongInlineName(timeline.nameField)
        type("Lead Voice", into: timeline.nameField)
        guard timeline.nameField.frame.width > initialNameWidth else { throw SounderError.message("Track editor does not grow with its text") }
        _ = timeline.nameField.control(timeline.nameField, textView: timeline.nameField.currentEditor() as! NSTextView, doCommandBy: #selector(NSResponder.insertNewline(_:)))
        guard editor.project.tracks[0].name == "Lead Voice", editor.dirty else { throw SounderError.message("Inline track rename did not save") }
        editor.undo(); guard editor.project.tracks[0].name == "Voice" else { throw SounderError.message("Track rename cannot be undone") }
        timeline.renameTrack(editor.project.tracks[0].id)
        type("Cancelled", into: timeline.nameField)
        _ = timeline.nameField.control(timeline.nameField, textView: timeline.nameField.currentEditor() as! NSTextView, doCommandBy: #selector(NSResponder.cancelOperation(_:)))
        guard editor.project.tracks[0].name == "Voice" else { throw SounderError.message("Cancelling track rename changed the name") }
        timeline.renameTrack(editor.project.tracks[0].id); type("   ", into: timeline.nameField)
        guard !timeline.nameField.finish(commit: true, requireValid: true), timeline.nameField.isRenaming, editor.project.tracks[0].name == "Voice" else { throw SounderError.message("Empty track name was accepted") }
        type("Focus name", into: timeline.nameField); window.makeFirstResponder(timeline)
        guard editor.project.tracks[0].name == "Focus name", !timeline.nameField.isRenaming else { throw SounderError.message("Track rename did not commit on focus loss") }
        editor.undo()
        if let scroll = timeline.enclosingScrollView {
            scroll.contentView.scroll(to: NSPoint(x: 400, y: 0)); scroll.reflectScrolledClipView(scroll.contentView)
            timeline.renameTrack(editor.project.tracks[0].id)
            guard timeline.nameField.isRenaming, timeline.nameField.frame.minX >= timeline.visibleRect.minX else { throw SounderError.message("Inline editor does not follow pinned track column") }
            timeline.nameField.finish(commit: false)
            scroll.contentView.scroll(to: .zero); scroll.reflectScrolledClipView(scroll.contentView)
        }
        let childID = editor.project.tracks[1].id, targetID = editor.project.tracks[2].id
        let childName = NSPoint(x: 60, y: timeline.ruler + timeline.rowHeight + 28)
        let target = NSPoint(x: 60, y: timeline.ruler + timeline.rowHeight * 2 + 55)
        timeline.mouseDown(with: event(.leftMouseDown, childName)); timeline.mouseDragged(with: event(.leftMouseDragged, target)); timeline.mouseUp(with: event(.leftMouseUp, target))
        guard editor.project.tracks.first(where: { $0.id == childID })?.parent == targetID else { throw SounderError.message("Dragging a track name no longer nests the track") }
        editor.undo(); editor.dirty = false; refresh()
        print("PASS: inline track rename, Enter, Escape, empty-name validation, focus loss, horizontal scrolling, Undo and nesting drag")
    }
    func verifyNotificationInteractions() throws {
        func event(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: timeline.convert(point, to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        let start = NSPoint(x: 190, y: timeline.ruler + 55)
        timeline.mouseDown(with: event(.leftMouseDown, start))
        guard editor.notifications.messages.isEmpty else { throw SounderError.message("Clicking a track must not show the drag hint") }
        for _ in 0..<2 {
            timeline.mouseDragged(with: event(.leftMouseDragged, NSPoint(x: start.x + 10, y: start.y)))
            timeline.mouseUp(with: event(.leftMouseUp, NSPoint(x: start.x + 10, y: start.y)))
            timeline.mouseDown(with: event(.leftMouseDown, start))
        }
        timeline.mouseUp(with: event(.leftMouseUp, start))
        let fragment = NSPoint(x: timeline.header + editor.zoom * 2, y: timeline.ruler + 45)
        for _ in 0..<2 { timeline.mouseDown(with: event(.leftMouseDown, fragment)); timeline.mouseUp(with: event(.leftMouseUp, fragment)) }
        guard editor.notifications.messages.map(\.text) == ["Drag tracks to nest", "Shift click to multi select"] else { throw SounderError.message("UX hints must trigger exactly once at the relevant interaction") }
        print("PASS: real track drag and fragment selection trigger each UX hint once")
        guard notificationOverlay.hitTest(NSPoint(x: 10, y: 10)) == nil else { throw SounderError.message("Notifications intercept editor gestures") }
    }
    func finishNotificationUITest(audioURL: URL) {
        func snapshot(_ suffix: String = "") {
            guard let index = CommandLine.arguments.firstIndex(of: "--snapshot"), index + 1 < CommandLine.arguments.count else { return }
            let original = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            let path = suffix.isEmpty ? original : original.deletingPathExtension().appendingPathExtension(suffix + ".png")
            let view = window.contentView!; view.layoutSubtreeIfNeeded()
            if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.effectiveAppearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: bitmap) }
                try? bitmap.representation(using: .png, properties: [:])?.write(to: path)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            self.editor.renameProject("Studio Session")
            self.editor.error(SounderError.message("Unable to open audio file"))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            guard self.editor.notifications.messages.count == 4 else { fputs("FAIL: Expected four stacked notifications\n", stderr); exit(1) }
            let frames = self.notificationOverlay.visibleFrames
            guard zip(frames, frames.dropFirst()).allSatisfy({ $0.maxY < $1.minY }) else { fputs("FAIL: Notifications overlap\n", stderr); exit(1) }
            snapshot()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.4) {
            let messages = self.editor.notifications.messages
            let frames = self.notificationOverlay.visibleFrames
            guard messages.count == 2, messages[0].style == .success, frames.count == 2, abs(frames[0].minY - 16) < 1 else { fputs("FAIL: Notifications did not expire independently and reflow upward\n", stderr); exit(1) }
            snapshot("reflow")
            print("PASS: five-second timers expire earlier cards and move remaining cards upward")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.5) {
            guard self.editor.notifications.messages.isEmpty else { fputs("FAIL: Notifications did not expire\n", stderr); exit(1) }
            try? FileManager.default.removeItem(at: audioURL)
            self.editor.dirty = false; NSApp.terminate(nil)
        }
    }
    func showSettingsDialog(_ alert: NSAlert) -> NSApplication.ModalResponse {
        if let automate = dialogAutomation {
            let timer = Timer(timeInterval: 0.1, repeats: false) { _ in automate(alert) }
            RunLoop.main.add(timer, forMode: .modalPanel)
        }
        return alert.runModal()
    }
    func verifySettingsUI() throws {
        window.contentView?.superview?.layoutSubtreeIfNeeded()
        let initialWidth = projectNameView.frame.width
        let qualityPosition = qualityButton.convert(NSPoint.zero, to: nil)
        projectLabel.sendAction(projectLabel.action, to: projectLabel.target)
        guard projectNameField.isRenaming, projectLabel.isHidden, NSApp.modalWindow == nil else { throw SounderError.message("Project name did not open inline") }
        window.contentView?.superview?.layoutSubtreeIfNeeded()
        guard abs(projectNameView.frame.width - initialWidth) < 1,
              abs(qualityButton.convert(NSPoint.zero, to: nil).x - qualityPosition.x) < 1,
              !projectNameField.drawsBackground,
              (projectNameField.currentEditor() as? NSTextView)?.selectedRange().length == 0 else { throw SounderError.message("Beginning project rename changes layout or text appearance: \(initialWidth) → \(projectNameView.frame.width), quality \(qualityPosition.x) → \(qualityButton.convert(NSPoint.zero, to: nil).x), selection \(String(describing: (projectNameField.currentEditor() as? NSTextView)?.selectedRange()))") }
        if let input = projectNameField.currentEditor() as? NSTextView { input.insertText(" Extended", replacementRange: input.selectedRange()) }
        window.contentView?.superview?.layoutSubtreeIfNeeded()
        guard projectNameView.frame.width > initialWidth else { throw SounderError.message("Project editor does not grow with its text") }
        try verifyLongInlineName(projectNameField)
        projectNameField.stringValue = "Studio Session"; projectNameField.finish(commit: true, requireValid: true)
        guard editor.projectName == "Studio Session", projectLabel.stringValue.contains("Studio Session"), !projectLabel.isHidden else { throw SounderError.message("Inline project rename did not save") }
        projectLabel.sendAction(projectLabel.action, to: projectLabel.target)
        projectNameField.stringValue = "Cancelled name"; projectNameField.finish(commit: false)
        guard editor.projectName == "Studio Session" else { throw SounderError.message("Cancelling a rename changed the project") }
        projectLabel.sendAction(projectLabel.action, to: projectLabel.target); projectNameField.stringValue = " "
        guard !projectNameField.finish(commit: true, requireValid: true), editor.projectName == "Studio Session" else { throw SounderError.message("Empty project name was accepted") }
        projectNameField.finish(commit: false)
        editor.undo(); guard editor.projectName == "MY PROJECT" else { throw SounderError.message("Inline project rename cannot be undone") }
        editor.redo()
        print("PASS: inline project name editing, Cancel, empty-name validation, Undo and Redo")
        dialogAutomation = { alert in
            let popups = alert.accessoryView!.subviews.compactMap { $0 as? NSPopUpButton }
            popups[0].selectItem(at: 3); popups[1].selectItem(at: 1); popups[2].selectItem(at: 1)
            NSApp.stopModal(withCode: .alertFirstButtonReturn)
        }
        qualityButton.performClick(nil)
        guard editor.project.audioFormat == ProjectAudioFormat(sampleRate: 96_000, channels: 2, bitDepth: 24), qualityButton.title.contains("96 kHz STEREO") else { throw SounderError.message("Audio settings click did not update the project") }
        dialogAutomation = nil
        editor.undo(); guard qualityButton.title.contains("48 kHz STEREO · 24 bit") else { throw SounderError.message("Undo did not update the audio label") }
        editor.redo(); editor.dirty = false; refresh()
        window.contentView?.superview?.layoutSubtreeIfNeeded()
        guard projectNameView.frame.width >= min(640, projectLabel.intrinsicContentSize.width) - 0.5 else { throw SounderError.message("Toolbar clips the committed project name despite available space") }
        print("PASS: clicking audio label edits rate/channels; Undo/Redo updates the label")
    }
    func textButton(_ title: String, size: CGFloat, action: Selector, cursor: NSCursor = .arrow) -> NSButton {
        let button = PointerButton(title: title, target: self, action: action)
        button.interactionCursor = cursor
        button.isBordered = false; button.bezelStyle = .inline
        button.font = .systemFont(ofSize: size, weight: .semibold); button.contentTintColor = .secondaryLabelColor
        button.setAccessibilityLabel(title); button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return button
    }
    @objc func renameProject() {
        guard !editor.busy else { return }
        projectLabel.isHidden = true
        projectNameField.begin(editor.projectName, commit: { [weak self] name in self?.editor.renameProject(name) },
                               end: { [weak self] in self?.projectLabel.isHidden = false; self?.projectNameView.updateSize() })
    }
    @objc func toggleTempo() { editor.toggleTempoMode() }
    @objc func toggleMetronome() { editor.toggleMetronome() }
    @objc func editTempo() {
        if let bpm = TempoDialog(bpm: editor.project.tempo).runModal() { editor.setTempo(bpm) }
    }
    @objc func audioSettings() {
        guard !editor.busy else { return }
        let alert = CompactSettingsAlert(); alert.messageText = "Audio settings"
        alert.icon = NSImage(size: .zero)
        let form = NSView(frame: NSRect(x: 0, y: 0, width: 350, height: 122))
        let rateLabel = NSTextField(labelWithString: "Sample rate"); rateLabel.frame = NSRect(x: 0, y: 90, width: 115, height: 22); form.addSubview(rateLabel)
        let rates = NSPopUpButton(frame: NSRect(x: 124, y: 86, width: 220, height: 28)); rates.setAccessibilityLabel("Sample rate")
        rates.addItems(withTitles: ProjectAudioFormat.supportedRates.map { ProjectAudioFormat(sampleRate: $0).rateLabel })
        rates.selectItem(at: ProjectAudioFormat.supportedRates.firstIndex(of: editor.project.audioFormat.sampleRate) ?? 1); form.addSubview(rates)
        let channelLabel = NSTextField(labelWithString: "Channels"); channelLabel.frame = NSRect(x: 0, y: 50, width: 115, height: 22); form.addSubview(channelLabel)
        let channels = NSPopUpButton(frame: NSRect(x: 124, y: 46, width: 220, height: 28)); channels.setAccessibilityLabel("Channels")
        channels.addItems(withTitles: ["Mono", "Stereo"]); channels.selectItem(at: editor.project.audioFormat.channels - 1); form.addSubview(channels)
        let depthLabel = NSTextField(labelWithString: "Bit depth"); depthLabel.frame = NSRect(x: 0, y: 10, width: 115, height: 22); form.addSubview(depthLabel)
        let depths = NSPopUpButton(frame: NSRect(x: 124, y: 6, width: 220, height: 28)); depths.setAccessibilityLabel("Bit depth")
        depths.addItems(withTitles: ["16 bit", "24 bit", "32 bit (Float)"])
        depths.selectItem(at: [16, 24, 32].firstIndex(of: editor.project.audioFormat.bitDepth) ?? 1); form.addSubview(depths)
        alert.accessoryView = form; alert.addButton(withTitle: "Apply"); alert.addButton(withTitle: "Cancel")
        guard showSettingsDialog(alert) == .alertFirstButtonReturn else { return }
        do { try editor.setAudioFormat(ProjectAudioFormat(sampleRate: ProjectAudioFormat.supportedRates[rates.indexOfSelectedItem], channels: channels.indexOfSelectedItem + 1, bitDepth: [16, 24, 32][depths.indexOfSelectedItem])) }
        catch { editor.error(error) }
    }
    func button(_ title: String, _ icon: String, _ selector: Selector) -> NSButton {
        let button = PointerButton(image: NSImage(systemSymbolName: icon, accessibilityDescription: title) ?? NSImage(), target: self, action: selector)
        button.bezelStyle = .texturedRounded; button.isBordered = false; button.contentTintColor = .labelColor; button.toolTip = title; button.setAccessibilityLabel(title)
        button.widthAnchor.constraint(equalToConstant: 32).isActive = true; button.heightAnchor.constraint(equalToConstant: 28).isActive = true; return button
    }
    func section(_ title: String, _ views: [NSView], headerControl: NSView? = nil) -> NSStackView {
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        let label = NSTextField(labelWithString: title); label.font = .systemFont(ofSize: 9, weight: .semibold); label.textColor = .secondaryLabelColor
        stack.addArrangedSubview(headerControl ?? label); let row = NSStackView(views: views); row.spacing = 6; stack.addArrangedSubview(row); return stack
    }
    func add(_ view: NSView, to stack: NSStackView, height: CGFloat? = nil) {
        stack.addArrangedSubview(view); view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        if let height { view.heightAnchor.constraint(equalToConstant: height).isActive = true }
    }
    func refresh() {
        timeline.refresh()
        let muted = editor.fragmentsAreMuted(editor.selection)
        fragmentMuteButton.toolTip = muted ? "Unmute selected fragments" : "Mute selected fragments"
        fragmentMuteButton.setAccessibilityLabel(muted ? "Unmute selected fragments" : "Mute selected fragments")
        fragmentMuteButton.image = NSImage(systemSymbolName: muted ? "speaker.wave.2" : "speaker.slash", accessibilityDescription: muted ? "Unmute" : "Mute")
        let time = editor.cursor; timeLabel.stringValue = String(format: "%02d:%02d.%03d", Int(time) / 60, Int(time) % 60, Int(time * 1000) % 1000)
        timeLabel.isHidden = editor.project.tempoMode; bpmButton.isHidden = !editor.project.tempoMode
        metronomeButton.isHidden = !editor.project.tempoMode
        let showingBeatPosition = editor.isPlaying || editor.isRecording
        bpmButton.title = showingBeatPosition ? TempoGrid.positionLabel(time: time, bpm: editor.project.tempo) : (editor.project.tempo.rounded() == editor.project.tempo ? String(Int(editor.project.tempo)) : String(format: "%.1f", editor.project.tempo)) + " BPM"
        bpmButton.toolTip = showingBeatPosition ? "Current bar.beat · Click to edit tempo" : "Edit tempo (4/4)"
        bpmButton.setAccessibilityLabel(showingBeatPosition ? "Current bar and beat: \(bpmButton.title)" : "Tempo: \(bpmButton.title)")
        tempoButton.state = editor.project.tempoMode ? .on : .off
        tempoButton.bezelColor = editor.project.tempoMode ? .systemOrange : nil
        tempoButton.contentTintColor = editor.project.tempoMode ? .white : .labelColor
        metronomeButton.state = editor.project.metronomeEnabled ? .on : .off
        metronomeButton.image = NSImage(systemSymbolName: editor.project.metronomeEnabled ? "metronome.fill" : "metronome", accessibilityDescription: "Metronome")
        metronomeButton.contentTintColor = editor.project.metronomeEnabled ? .systemOrange : .secondaryLabelColor
        metronomeButton.toolTip = editor.project.metronomeEnabled ? "Metronome on" : "Metronome off"
        tempoButton.isEnabled = !editor.isImporting && !editor.requestingMic
        bpmButton.isEnabled = tempoButton.isEnabled; metronomeButton.isEnabled = tempoButton.isEnabled
        playButton.image = NSImage(systemSymbolName: editor.isPlaying ? "pause.fill" : "play.fill", accessibilityDescription: "Play / pause")
        playButton.isEnabled = !editor.isRecording && !editor.requestingMic && !editor.isImporting; recordButton.isEnabled = editor.canRecord
        editButtons.forEach { $0.isEnabled = !editor.busy }
        for name in ["open", "save"] {
            let item = titlebarItems[NSToolbarItem.Identifier(name)]
            item?.isEnabled = !editor.busy
            (item?.view as? NSControl)?.isEnabled = !editor.busy
        }
        exportButton.isEnabled = editor.canExport
        titlebarItems[NSToolbarItem.Identifier("export")]?.isEnabled = editor.canExport
        projectLabel.stringValue = editor.projectName + (editor.dirty ? "  •" : "")
        projectNameView.updateSize()
        projectLabel.isEnabled = !editor.busy; qualityButton.isEnabled = !editor.busy
        titlebarItems[NSToolbarItem.Identifier("quality")]?.isEnabled = !editor.busy
        qualityButton.attributedTitle = NSAttributedString(string: editor.project.audioFormat.label, attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor
        ])
        window.title = editor.projectName + " — Sounder"
        window.isDocumentEdited = editor.dirty
    }
    func windowDidResize(_ notification: Notification) { timeline?.refresh() }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if editor.isImporting { editor.importer?.cancel(); return false }
        if editor.isRecording { editor.stop() }
        closingConfirmed = editor.confirmDiscard()
        if closingConfirmed {
            editor.stop(); editor.closePluginWindows(capture: false)
            for panel in Array(editor.effectsWindows.values) { panel.done() }
        }
        return closingConfirmed
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if editor.isImporting { editor.importer?.cancel(); return .terminateCancel }
        if closingConfirmed { return .terminateNow }; if editor.isRecording { editor.stop() }; return editor.confirmDiscard() ? .terminateNow : .terminateCancel
    }
    func buildMenu() {
        let main = NSMenu(); NSApp.mainMenu = main
        func menu(_ title: String, _ items: [(String, Selector, String)]) {
            let root = NSMenuItem(); root.title = title; let submenu = NSMenu(title: title); root.submenu = submenu; main.addItem(root)
            for (title, action, key) in items { let item = NSMenuItem(title: title, action: action, keyEquivalent: key); item.target = self; submenu.addItem(item) }
        }
        menu("Sounder", [("About Sounder", #selector(about), ""), ("Quit Sounder", #selector(quit), "q")])
        menu("File", [("Rename Project…", #selector(renameProject), ""), ("Audio Settings…", #selector(audioSettings), ""), ("Open Project…", #selector(openProject), "o"), ("Save Project…", #selector(saveProject), "s"), ("Save Project As…", #selector(saveAs), ""), ("Import Audio…", #selector(importAudio), "i"), ("Export…", #selector(exportAudio), "e")])
        menu("Edit", [("Undo", #selector(undo), "z"), ("Redo", #selector(redo), "Z"), ("Select All", #selector(selectAll(_:)), "a"), ("Copy", #selector(copy(_:)), "c"), ("Paste", #selector(paste(_:)), "v")])
        menu("Fragments", [("Split at Playhead", #selector(split), "s"), ("Trim to Selection", #selector(trim), ""), ("Join Fragments", #selector(join), "j"), ("Normalize…", #selector(normalize), "n"), ("Mute Fragments", #selector(muteFragments), ""), ("Delete Fragments", #selector(deleteClips), "\u{8}")])
        if let fragments = main.items.last?.submenu { fragments.items.filter { [#selector(split), #selector(normalize)].contains($0.action) }.forEach { $0.keyEquivalentModifierMask = [] } }
        menu("Track", [("Track Effects…", #selector(effects), "f"), ("Add Track", #selector(addTrack), "t"), ("Add Nested Track", #selector(nest), ""), ("Move Track to Root", #selector(unparent), ""), ("Delete Track…", #selector(removeTrack), "")])
        menu("Transport", [("Play / Pause", #selector(play), " "), ("Play from Last Start", #selector(restartPlayback), "\r"), ("Seek Backward", #selector(seekBackward), "\u{f702}"), ("Seek Forward", #selector(seekForward), "\u{f703}"), ("Go to Start", #selector(seekToStart), "\u{f702}"), ("Go to End", #selector(seekToEnd), "\u{f703}"), ("Record", #selector(record), "r"), ("Stop", #selector(stop), "\u{1b}"), ("Return to Start", #selector(rewind), "")])
        if let transport = main.items.last?.submenu { transport.items.forEach { $0.keyEquivalentModifierMask = [#selector(seekToStart), #selector(seekToEnd)].contains($0.action) ? [.command] : [] } }
        menu("View", [("Zoom In", #selector(zoomIn), "\u{f700}"), ("Zoom Out", #selector(zoomOut), "\u{f701}")])
        if let view = main.items.last?.submenu { view.items.forEach { $0.keyEquivalentModifierMask = [] } }
    }
    private var shuttleKey: UInt16?
    private var releasedShuttleKey: UInt16?
    @objc private func cancelShuttle() { shuttleKey = nil; releasedShuttleKey = nil; editor.endShuttle(resume: false) }
    @discardableResult func handleShuttleShortcut(_ event: NSEvent) -> Bool {
        if event.type == .flagsChanged {
            if let key = shuttleKey, !event.modifierFlags.contains(.shift) {
                releasedShuttleKey = key; shuttleKey = nil
                editor.releaseShuttle(); timeline.centerOnPlayhead()
            }
            return false
        }
        guard event.keyCode == 123 || event.keyCode == 124 else { return false }
        if event.type == .keyUp {
            if releasedShuttleKey == event.keyCode { releasedShuttleKey = nil; return true }
            guard shuttleKey == event.keyCode else { return false }
            shuttleKey = nil; editor.releaseShuttle(); timeline.centerOnPlayhead(); return true
        }
        if event.type == .keyDown, releasedShuttleKey == event.keyCode {
            if event.isARepeat { return true }
            releasedShuttleKey = nil
        }
        guard event.type == .keyDown, event.window === window, NSApp.modalWindow == nil,
              !(window.firstResponder is NSTextView), timeline.canSelectRange,
              event.modifierFlags.intersection([.command, .shift, .option, .control]) == [.shift] else { return false }
        if !event.isARepeat || shuttleKey != event.keyCode {
            shuttleKey = event.keyCode
            timeline.beginShuttle(direction: event.keyCode == 123 ? -1 : 1)
        }
        return true
    }
    @discardableResult func handlePhysicalShortcut(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, NSApp.modalWindow == nil,
              event.window === window, !(window.firstResponder is NSTextView) else { return false }
        let flags = event.modifierFlags.intersection([.command, .shift, .control, .option])
        let letters: [UInt16: String] = [0: "a", 1: "s", 3: "f", 6: "z", 8: "c", 9: "v", 12: "q", 14: "e", 15: "r", 17: "t", 31: "o", 34: "i", 38: "j", 45: "n"]
        guard let letter = letters[event.keyCode] else { return false }
        for root in NSApp.mainMenu?.items ?? [] {
            for item in root.submenu?.items ?? [] where item.keyEquivalent.lowercased() == letter {
                var modifiers = item.keyEquivalentModifierMask.intersection([.command, .shift, .control, .option])
                if item.keyEquivalent != item.keyEquivalent.lowercased() { modifiers.insert(.shift) }
                guard flags == modifiers, let action = item.action, validateMenuItem(item) else { continue }
                return NSApp.sendAction(action, to: item.target, from: item)
            }
        }
        return false
    }
    @objc func openProject() { editor.open() }
    private func finishNameEditing() { projectNameField.finish(commit: true); timeline.nameField.finish(commit: true) }
    @objc func saveProject() { guard !editor.busy else { return }; finishNameEditing(); _ = editor.save() }
    @objc func saveAs() { guard !editor.busy else { return }; finishNameEditing(); _ = editor.save(as: true) }
    @objc func importAudio() { editor.importAudio() }
    @objc func exportAudio() { editor.export() }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if [#selector(openProject), #selector(saveProject), #selector(saveAs)].contains(menuItem.action) {
            return !editor.busy && NSApp.modalWindow == nil
        }
        if [#selector(selectAll(_:)), #selector(copy(_:)), #selector(paste(_:))].contains(menuItem.action) {
            if (NSApp.keyWindow ?? window)?.firstResponder is NSTextView { return true }
            guard NSApp.modalWindow == nil, NSApp.keyWindow == nil || NSApp.keyWindow === window else { return false }
            if menuItem.action == #selector(selectAll(_:)) { return timeline.canSelectRange }
            if menuItem.action == #selector(copy(_:)) { return !editor.selection.isEmpty }
            return !editor.busy && NSPasteboard.general.data(forType: Editor.fragmentPasteboardType) != nil
        }
        if [#selector(split), #selector(trim), #selector(join), #selector(normalize), #selector(muteFragments), #selector(deleteClips)].contains(menuItem.action) {
            if menuItem.action == #selector(muteFragments) { menuItem.title = editor.fragmentsAreMuted(editor.selection) ? "Unmute Fragments" : "Mute Fragments" }
            return NSApp.modalWindow == nil && (NSApp.keyWindow == nil || NSApp.keyWindow === window) && !(window.firstResponder is NSTextView) && !editor.busy
                && editor.project.tracks.contains { $0.clips.contains { editor.selection.contains($0.id) } }
        }
        if menuItem.action == #selector(exportAudio) { return editor.canExport }
        if [#selector(zoomIn), #selector(zoomOut)].contains(menuItem.action) {
            return NSApp.modalWindow == nil && (NSApp.keyWindow == nil || NSApp.keyWindow === window) && !(window.firstResponder is NSTextView)
        }
        if menuItem.action == #selector(record) {
            return editor.canRecord && NSApp.modalWindow == nil && (NSApp.keyWindow == nil || NSApp.keyWindow === window) && !(window.firstResponder is NSTextView)
        }
        if [#selector(restartPlayback), #selector(play), #selector(seekBackward), #selector(seekForward), #selector(seekToStart), #selector(seekToEnd), #selector(stop), #selector(record), #selector(rewind)].contains(menuItem.action) {
            return NSApp.modalWindow == nil && (NSApp.keyWindow == nil || NSApp.keyWindow === window) && !(window.firstResponder is NSTextView)
                && (!editor.isRecording || menuItem.action == #selector(restartPlayback) || menuItem.action == #selector(play))
                && !editor.requestingMic && !editor.isImporting
        }
        return true
    }
    @objc func selectAll(_ sender: Any?) {
        if let input = (NSApp.keyWindow ?? window)?.firstResponder as? NSTextView { input.selectAll(sender) }
        else if timeline.canSelectRange { editor.selectAllFragments() }
    }
    @objc func copy(_ sender: Any?) {
        if let input = (NSApp.keyWindow ?? window)?.firstResponder as? NSTextView { input.copy(sender) }
        else { editor.copyFragments() }
    }
    @objc func paste(_ sender: Any?) {
        if let input = (NSApp.keyWindow ?? window)?.firstResponder as? NSTextView { input.paste(sender) }
        else { editor.pasteFragments() }
    }
    @objc func seekToStart() { timeline.seekBoundary(end: false) }
    @objc func seekToEnd() { timeline.seekBoundary(end: true) }
    @objc func seekBackward() { timeline.movePlayhead(direction: -1) }
    @objc func seekForward() { timeline.movePlayhead(direction: 1) }
    @objc func restartPlayback() { editor.restartFromLastStart() }
    @objc func play() { editor.playPause() }
    @objc func stop() { if timeline.cancelFragmentResize() || timeline.cancelMarqueeSelection() { return }; if timeline.trackDrag != nil { timeline.cancelTrackDrag() } else { editor.stopAndReturnToStart(); timeline.centerOnPlayhead() } }
    @objc func record() { editor.record() }
    @objc func rewind() { if editor.isRecording { editor.stop() }; editor.seek(to: 0) }
    func editFragment(_ id: UUID) {
        guard !editor.busy, let clip = editor.project.tracks.flatMap(\.clips).first(where: { $0.id == id }) else { return }
        let dialog = FragmentSettingsDialog(clip: clip, store: editor.audio)
        var timer: Timer?
        if let automate = fragmentDialogAutomation {
            let action = Timer(timeInterval: 0.05, repeats: true) { tick in
                guard dialog.peak != nil else { return }; tick.invalidate(); automate(dialog)
            }
            timer = action; RunLoop.main.add(action, forMode: .common)
        }
        defer { timer?.invalidate() }
        if let settings = dialog.runModal(), let peak = dialog.peak {
            do { try editor.setFragmentSettings(id, settings: settings, peak: peak) } catch { editor.error(error) }
        }
    }
    @objc func muteFragments() { editor.toggleFragmentMute() }
    @objc func normalize() {
        guard !editor.busy else { return }
        guard !editor.selection.isEmpty else { editor.notifications.show("Select fragments to normalize", style: .hint); return }
        if let level = NormalizeDialog(level: editor.project.normalizationLevel).runModal() { editor.normalize(to: level) }
    }
    @objc func split() { editor.split() }
    @objc func trim() { editor.trim() }
    @objc func join() { editor.join() }
    @objc func deleteClips() { editor.deleteClips() }
    @objc func effects() { guard !editor.isRecording, !editor.requestingMic, !editor.isImporting, let id = editor.selectedTrack else { return }; EffectsWindow(editor: editor, trackID: id).run() }
    @objc func addTrack() { editor.addTrack() }
    @objc func nest() { editor.addTrack(nested: true) }
    @objc func removeTrack() { editor.removeTrack() }
    @objc func unparent() { if let id = editor.selectedTrack { editor.reparent(id, to: nil) } }
    @objc func undo() { if let input = window.firstResponder as? NSTextView { input.undoManager?.undo() } else { editor.undo() } }
    @objc func redo() { if let input = window.firstResponder as? NSTextView { input.undoManager?.redo() } else { editor.redo() } }
    @objc func zoomIn() { editor.zoom = min(500, editor.zoom * 1.4); refresh(); timeline.centerOnPlayhead() }
    @objc func zoomOut() { editor.zoom = max(timeline.minimumZoom, editor.zoom / 1.4); refresh(); timeline.centerOnPlayhead() }
    @objc func quit() { NSApp.terminate(nil) }
    @objc func about() { NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "Sounder", .applicationVersion: "1.1.0", .credits: NSAttributedString(string: "Audio recorder & editor\nDzmitry Sharko")]) }
}

if CommandLine.arguments.contains("--microphone-test") {
    do { try runMicrophoneSmokeTest(); exit(0) } catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
}
if let index = CommandLine.arguments.firstIndex(of: "--plugin-test"), index + 1 < CommandLine.arguments.count {
    do { try runPluginTest(path: CommandLine.arguments[index + 1], editorTest: CommandLine.arguments.contains("--editor-test")); exit(0) }
    catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
}
if let index = CommandLine.arguments.firstIndex(of: "--playback-test"), index + 1 < CommandLine.arguments.count {
    let referenceIndex = CommandLine.arguments.firstIndex(of: "--reference")
    let reference = referenceIndex.flatMap { $0 + 1 < CommandLine.arguments.count ? CommandLine.arguments[$0 + 1] : nil }
    do { try runPlaybackContinuityTest(path: CommandLine.arguments[index + 1], reference: reference); exit(0) }
    catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
}
if CommandLine.arguments.contains("--self-test") {
    do { try runAudioTests(); exit(0) } catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
}
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
