import AppKit
import AVFoundation

final class PointerButton: NSButton {
    var interactionCursor: NSCursor = .pointingHand {
        didSet { window?.invalidateCursorRects(for: self) }
    }
    override var isEnabled: Bool {
        didSet {
            if isEnabled != oldValue { window?.invalidateCursorRects(for: self) }
        }
    }
    override func resetCursorRects() {
        super.resetCursorRects()
        if isEnabled { addCursorRect(bounds, cursor: interactionCursor) }
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
    var projectLabel: NSButton!
    var qualityButton: NSButton!
    var playButton: NSButton!
    var recordButton: NSButton!
    var exportButton: NSButton!
    var editButtons: [NSButton] = []
    private var titlebarItems: [NSToolbarItem.Identifier: NSToolbarItem] = [:]
    private let titlebarOrder: [NSToolbarItem.Identifier] = [NSToolbarItem.Identifier("project"), NSToolbarItem.Identifier("quality"), .flexibleSpace, NSToolbarItem.Identifier("open"), NSToolbarItem.Identifier("save"), NSToolbarItem.Identifier("export")]
    var closingConfirmed = false
    var dialogAutomation: ((NSAlert) -> Void)?
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
        let toolbar = NSStackView(); toolbar.orientation = .horizontal; toolbar.spacing = 14; toolbar.edgeInsets = NSEdgeInsets(top: 10, left: 22, bottom: 12, right: 22)
        playButton = button("Play / pause · Space", "play.fill", #selector(play))
        recordButton = button("Record · R", "record.circle", #selector(record)); recordButton.contentTintColor = .systemRed
        toolbar.addArrangedSubview(section("PLAYER", [button("Return to start", "backward.end.fill", #selector(rewind)), playButton, button("Stop · Escape", "stop.fill", #selector(stop)), recordButton]))
        let split = button("Split at playhead · ⌘B", "scissors", #selector(split)); let trim = button("Trim to ruler selection", "crop", #selector(trim)); let delete = button("Delete fragments · Delete", "trash", #selector(deleteClips))
        let join = button("Join selected fragments · ⌘J", "link", #selector(join))
        let importButton = button("Import audio · ⌘I", "square.and.arrow.down.on.square", #selector(importAudio))
        toolbar.addArrangedSubview(section("FRAGMENTS", [split, trim, delete, join, importButton]))
        let addTrack = button("Add track · ⌘T", "plus", #selector(addTrack)); let nest = button("Add nested track", "arrow.turn.down.right", #selector(nest)); let removeTrack = button("Delete track", "minus", #selector(removeTrack))
        toolbar.addArrangedSubview(section("TRACKS", [addTrack, nest, removeTrack])); editButtons = [split, trim, delete, join, addTrack, nest, removeTrack, importButton]
        toolbar.addArrangedSubview(section("VIEW", [button("Zoom out", "minus.magnifyingglass", #selector(zoomOut)), button("Zoom in", "plus.magnifyingglass", #selector(zoomIn))]))
        let spacer2 = NSView(); spacer2.setContentHuggingPriority(.defaultLow, for: .horizontal); toolbar.addArrangedSubview(spacer2)
        metronomeButton = PointerButton(title: "Metronome", target: self, action: #selector(toggleMetronome))
        metronomeButton.setButtonType(.switch); metronomeButton.font = .systemFont(ofSize: 10)
        metronomeButton.setAccessibilityLabel("Metronome")
        tempoButton = PointerButton(title: "Tempo", target: self, action: #selector(toggleTempo))
        tempoButton.bezelStyle = .rounded; tempoButton.setButtonType(.pushOnPushOff)
        let tempoControls = NSStackView(views: [metronomeButton, tempoButton]); tempoControls.orientation = .horizontal; tempoControls.alignment = .centerY; tempoControls.spacing = 8
        toolbar.addArrangedSubview(tempoControls)
        bpmButton = textButton("120 BPM", size: 25, action: #selector(editTempo), cursor: .iBeam)
        bpmButton.contentTintColor = accent; bpmButton.toolTip = "Edit tempo (4/4)"; bpmButton.isHidden = true
        timeLabel = NSTextField(labelWithString: "00:00.000"); timeLabel.font = .monospacedDigitSystemFont(ofSize: 25, weight: .light); timeLabel.textColor = accent
        bpmButton.font = timeLabel.font
        let positionDisplay = NSStackView(views: [timeLabel, bpmButton]); positionDisplay.spacing = 6
        toolbar.addArrangedSubview(positionDisplay); add(toolbar, to: stack, height: 84)
        let scroll = NSScrollView(); scroll.hasHorizontalScroller = true; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.drawsBackground = false
        timeline = Timeline(editor); scroll.documentView = timeline; add(scroll, to: stack)
        notificationOverlay = ToastOverlay.install(in: content, center: editor.notifications)
        editor.changed = { [weak self] in self?.refresh() }
        buildMenu(); window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); refresh()
        if let index = CommandLine.arguments.firstIndex(of: "--import-ui-test"), index + 1 < CommandLine.arguments.count { importUITest(URL(fileURLWithPath: CommandLine.arguments[index + 1])); return }
        if CommandLine.arguments.contains("--ui-test") { uiTest() }
    }
    private func installTitlebarControls() {
        let icon = Bundle.main.url(forResource: "AppIcon", withExtension: "icns").flatMap { NSImage(contentsOf: $0) }
        if let icon { NSApp.applicationIconImage = icon }
        projectLabel = textButton("MY PROJECT", size: 10, action: #selector(renameProject), cursor: .iBeam)
        projectLabel.toolTip = "Rename project"; projectLabel.lineBreakMode = .byTruncatingTail
        projectLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 320).isActive = true
        qualityButton = textButton(ProjectAudioFormat().label, size: 9, action: #selector(audioSettings)); qualityButton.toolTip = "Project audio settings"
        let export = PointerButton(title: "Export", target: self, action: #selector(exportAudio)); export.bezelStyle = .rounded
        export.widthAnchor.constraint(equalToConstant: export.intrinsicContentSize.width + 16).isActive = true
        exportButton = export
        let controls: [(String, String, NSView)] = [
            ("project", "Project name", projectLabel),
            ("quality", "Project audio settings", qualityButton),
            ("open", "Open project", button("Open project", "folder", #selector(openProject))),
            ("save", "Save project", button("Save project", "square.and.arrow.down", #selector(saveProject))),
            ("export", "Export", export)
        ]
        for (id, label, view) in controls {
            let identifier = NSToolbarItem.Identifier(id)
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = label; item.toolTip = label; item.view = view
            if id == "export" || id == "quality" { item.autovalidates = false }
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
            if CommandLine.arguments.contains("--tempo-ui-test") { try verifyTempoUI() }
            if CommandLine.arguments.contains("--export-ui-test") { try verifyExportUI() }
            if CommandLine.arguments.contains("--restart-ui-test") { try verifyRestartUI() }
            if CommandLine.arguments.contains("--mute-ui-test") { try verifyMuteUI() }
            if CommandLine.arguments.contains("--zoom-ui-test") { try verifyZoomUI() }
            if CommandLine.arguments.contains("--range-ui-test") { try verifyRangeUI() }
            if CommandLine.arguments.contains("--playhead-ui-test") { try verifyPlayheadUI() }
            if CommandLine.arguments.contains("--track-name-ui-test") { try verifyTrackNameUI() }
            if CommandLine.arguments.contains("--settings-ui-test") { try verifySettingsUI() }
            if CommandLine.arguments.contains("--notifications-ui-test") { try verifyNotificationInteractions(); finishNotificationUITest(audioURL: url); return }
            if CommandLine.arguments.contains("--pinned-ruler-ui-test") { try verifyPinnedRulerUI() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                self.window.contentView!.layoutSubtreeIfNeeded()
                let view = self.window.contentView!
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
    func verifyTrackNameUI() throws {
        func event(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: timeline.convert(point, to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        func answerRename(_ response: NSApplication.ModalResponse) {
            let timer = Timer(timeInterval: 0.1, repeats: false) { _ in
                func findField(_ view: NSView) -> NSTextField? {
                    if let field = view as? NSTextField, field.isEditable { return field }
                    for child in view.subviews { if let field = findField(child) { return field } }
                    return nil
                }
                if let root = NSApp.modalWindow?.contentView { findField(root)?.stringValue = "Lead Voice" }
                NSApp.stopModal(withCode: response)
            }
            RunLoop.main.add(timer, forMode: .modalPanel)
        }
        let name = NSPoint(x: 45, y: timeline.ruler + 28)
        timeline.mouseDown(with: event(.leftMouseDown, name)); answerRename(.alertFirstButtonReturn)
        timeline.mouseUp(with: event(.leftMouseUp, name))
        guard editor.project.tracks[0].name == "Lead Voice", editor.dirty else { throw SounderError.message("Single click on track name did not open rename") }
        editor.undo(); guard editor.project.tracks[0].name == "Voice" else { throw SounderError.message("Track rename cannot be undone") }
        timeline.mouseDown(with: event(.leftMouseDown, name)); answerRename(.alertSecondButtonReturn)
        timeline.mouseUp(with: event(.leftMouseUp, name))
        guard editor.project.tracks[0].name == "Voice" else { throw SounderError.message("Cancelling track rename changed the name") }
        let childID = editor.project.tracks[1].id, targetID = editor.project.tracks[2].id
        let childName = NSPoint(x: 60, y: timeline.ruler + timeline.rowHeight + 28)
        let target = NSPoint(x: 60, y: timeline.ruler + timeline.rowHeight * 2 + 55)
        timeline.mouseDown(with: event(.leftMouseDown, childName)); timeline.mouseDragged(with: event(.leftMouseDragged, target)); timeline.mouseUp(with: event(.leftMouseUp, target))
        guard editor.project.tracks.first(where: { $0.id == childID })?.parent == targetID else { throw SounderError.message("Dragging a track name no longer nests the track") }
        editor.undo(); editor.dirty = false; refresh()
        print("PASS: single-click track rename, Cancel, Undo and dragging the name to nest")
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
        dialogAutomation = { alert in
            (alert.accessoryView as? NSTextField)?.stringValue = "Studio Session"
            NSApp.stopModal(withCode: .alertFirstButtonReturn)
        }
        projectLabel.performClick(nil)
        guard editor.projectName == "Studio Session", projectLabel.title.contains("Studio Session") else { throw SounderError.message("Project title click did not rename the project") }
        print("PASS: clicking project title edits its name")
        dialogAutomation = { alert in
            (alert.accessoryView as? NSTextField)?.stringValue = "Cancelled name"
            NSApp.stopModal(withCode: .alertSecondButtonReturn)
        }
        projectLabel.performClick(nil)
        guard editor.projectName == "Studio Session" else { throw SounderError.message("Cancelling a rename changed the project") }
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
        print("PASS: clicking audio label edits rate/channels; Undo/Redo updates the label")
    }
    func textButton(_ title: String, size: CGFloat, action: Selector, cursor: NSCursor = .pointingHand) -> NSButton {
        let button = PointerButton(title: title, target: self, action: action)
        button.interactionCursor = cursor
        button.isBordered = false; button.bezelStyle = .inline
        button.font = .systemFont(ofSize: size, weight: .semibold); button.contentTintColor = .secondaryLabelColor
        button.setAccessibilityLabel(title); button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return button
    }
    @objc func renameProject() {
        guard !editor.busy else { return }
        let alert = NSAlert(); alert.messageText = "Project name"; alert.informativeText = "Enter a name for this project."
        let field = NSTextField(string: editor.projectName); field.frame = NSRect(x: 0, y: 0, width: 320, height: 26)
        field.setAccessibilityLabel("Project name"); alert.accessoryView = field
        alert.addButton(withTitle: "Rename"); alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard showSettingsDialog(alert) == .alertFirstButtonReturn else { return }
        editor.renameProject(field.stringValue)
    }
    @objc func toggleTempo() { editor.toggleTempoMode() }
    @objc func toggleMetronome() { editor.toggleMetronome() }
    @objc func editTempo() {
        let alert = NSAlert(); alert.messageText = "Tempo"; alert.informativeText = "Beats per minute · 4 beats per bar (4/4)"
        let field = NSTextField(string: String(format: "%g", editor.project.tempo))
        field.frame = NSRect(x: 0, y: 0, width: 220, height: 26); field.setAccessibilityLabel("BPM")
        alert.accessoryView = field; alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel"); alert.window.initialFirstResponder = field
        while alert.runModal() == .alertFirstButtonReturn {
            let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
            if let value = Double(text), value.isFinite, (20...300).contains(value) { editor.setTempo(value); return }
            alert.informativeText = "Enter a tempo between 20 and 300 BPM."
        }
    }
    @objc func audioSettings() {
        guard !editor.busy else { return }
        let alert = NSAlert(); alert.messageText = "Audio settings"
        alert.informativeText = "Choose the sample rate and channels. Bit depth applies to new recordings and WAV export. Existing audio files are preserved."
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
        let time = editor.cursor; timeLabel.stringValue = String(format: "%02d:%02d.%03d", Int(time) / 60, Int(time) % 60, Int(time * 1000) % 1000)
        timeLabel.isHidden = editor.project.tempoMode; bpmButton.isHidden = !editor.project.tempoMode
        metronomeButton.isHidden = !editor.project.tempoMode
        bpmButton.title = (editor.project.tempo.rounded() == editor.project.tempo ? String(Int(editor.project.tempo)) : String(format: "%.1f", editor.project.tempo)) + " BPM"
        tempoButton.state = editor.project.tempoMode ? .on : .off
        metronomeButton.state = editor.project.metronomeEnabled ? .on : .off
        tempoButton.isEnabled = !editor.isImporting && !editor.requestingMic
        bpmButton.isEnabled = tempoButton.isEnabled; metronomeButton.isEnabled = tempoButton.isEnabled
        playButton.image = NSImage(systemSymbolName: editor.isPlaying ? "pause.fill" : "play.fill", accessibilityDescription: "Play / pause")
        playButton.isEnabled = !editor.isRecording && !editor.requestingMic && !editor.isImporting; recordButton.isEnabled = !editor.busy
        editButtons.forEach { $0.isEnabled = !editor.busy }
        exportButton.isEnabled = editor.canExport
        titlebarItems[NSToolbarItem.Identifier("export")]?.isEnabled = editor.canExport
        projectLabel.title = editor.projectName + (editor.dirty ? "  •" : "")
        projectLabel.isEnabled = !editor.busy; qualityButton.isEnabled = !editor.busy
        titlebarItems[NSToolbarItem.Identifier("quality")]?.isEnabled = !editor.busy
        qualityButton.title = editor.project.audioFormat.label
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
        menu("Edit", [("Undo", #selector(undo), "z"), ("Redo", #selector(redo), "Z"), ("Split at Playhead", #selector(split), "b"), ("Trim to Selection", #selector(trim), ""), ("Join Fragments", #selector(join), "j"), ("Delete Fragments", #selector(deleteClips), "\u{8}")])
        menu("Track", [("Track Effects…", #selector(effects), "f"), ("Add Track", #selector(addTrack), "t"), ("Add Nested Track", #selector(nest), ""), ("Move Track to Root", #selector(unparent), ""), ("Delete Track…", #selector(removeTrack), "")])
        menu("Transport", [("Play / Pause", #selector(play), " "), ("Play from Last Start", #selector(restartPlayback), "\r"), ("Seek Backward", #selector(seekBackward), "\u{f702}"), ("Seek Forward", #selector(seekForward), "\u{f703}"), ("Record", #selector(record), "r"), ("Stop", #selector(stop), "\u{1b}"), ("Return to Start", #selector(rewind), "")])
        if let transport = main.items.last?.submenu { transport.items.forEach { $0.keyEquivalentModifierMask = [] } }
        menu("View", [("Zoom In", #selector(zoomIn), "\u{f700}"), ("Zoom Out", #selector(zoomOut), "\u{f701}")])
        if let view = main.items.last?.submenu { view.items.forEach { $0.keyEquivalentModifierMask = [] } }
    }
    @objc func openProject() { editor.open() }
    @objc func saveProject() { _ = editor.save() }
    @objc func saveAs() { _ = editor.save(as: true) }
    @objc func importAudio() { editor.importAudio() }
    @objc func exportAudio() { editor.export() }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(exportAudio) { return editor.canExport }
        if [#selector(zoomIn), #selector(zoomOut)].contains(menuItem.action) {
            return NSApp.modalWindow == nil && (NSApp.keyWindow == nil || NSApp.keyWindow === window) && !(window.firstResponder is NSTextView)
        }
        if [#selector(restartPlayback), #selector(play), #selector(seekBackward), #selector(seekForward)].contains(menuItem.action) {
            return NSApp.modalWindow == nil && (NSApp.keyWindow == nil || NSApp.keyWindow === window) && !(window.firstResponder is NSTextView)
                && (!editor.isRecording || menuItem.action == #selector(restartPlayback) || menuItem.action == #selector(play))
                && !editor.requestingMic && !editor.isImporting
        }
        return true
    }
    @objc func seekBackward() { timeline.movePlayhead(direction: -1) }
    @objc func seekForward() { timeline.movePlayhead(direction: 1) }
    @objc func restartPlayback() { editor.restartFromLastStart() }
    @objc func play() { editor.playPause() }
    @objc func stop() { editor.stop() }
    @objc func record() { editor.record() }
    @objc func rewind() { if editor.isRecording { editor.stop() }; editor.seek(to: 0) }
    @objc func split() { editor.split() }
    @objc func trim() { editor.trim() }
    @objc func join() { editor.join() }
    @objc func deleteClips() { editor.deleteClips() }
    @objc func effects() { guard !editor.isRecording, !editor.requestingMic, !editor.isImporting, let id = editor.selectedTrack else { return }; EffectsWindow(editor: editor, trackID: id).run() }
    @objc func addTrack() { editor.addTrack() }
    @objc func nest() { editor.addTrack(nested: true) }
    @objc func removeTrack() { editor.removeTrack() }
    @objc func unparent() { if let id = editor.selectedTrack { editor.reparent(id, to: nil) } }
    @objc func undo() { editor.undo() }
    @objc func redo() { editor.redo() }
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
