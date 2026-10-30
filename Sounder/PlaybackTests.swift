import AppKit
import AVFoundation

/// Captures the player's rendered PCM, so gaps in queued playback cannot hide
/// behind correct decoder output or an advancing playback clock.
func runPlaybackContinuityTest(path: String, reference: String?) throws {
    _ = NSApplication.shared; NSApp.setActivationPolicy(.accessory)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SounderPlayback-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try AudioStore(directory: directory)
    let decoded = try store.load(path)
    if let reference {
        let expected = try store.load(reference)
        guard decoded.channels.count == expected.channels.count, abs(decoded.frameCount - expected.frameCount) <= 1 else { throw SounderError.message("Imported audio length/channel count differs from independent SRC reference") }
        for channel in decoded.channels.indices {
            var squared = 0.0, maximum = 0.0
            for i in 0..<min(decoded.frameCount, expected.frameCount) {
                let difference = Double(decoded.channels[channel][i] - expected.channels[channel][i])
                squared += difference * difference; maximum = max(maximum, abs(difference))
            }
            let rms = sqrt(squared / Double(decoded.frameCount))
            print(String(format: "SRC channel %d: RMS difference %.9f, max %.9f", channel, rms, maximum))
            guard rms < 0.00001 else { throw SounderError.message("Import SRC differs from independent reference") }
        }
        print("PASS: imported PCM matches independent afconvert Mastering SRC reference")
        store.cache.removeValue(forKey: reference)
    }
    let format = ProjectAudioFormat(bitDepth: 24)
    let start = min(30.0, max(0, Double(decoded.frameCount) / sampleRate - 6))
    let clip = Clip(name: "Continuity", source: path, start: 0, duration: Double(decoded.frameCount) / sampleRate, order: 1)
    let graph = try StreamingGraph(project: Project(tracks: [Track(name: "Audio", clips: [clip])]), store: store) { _ in fatalError("No effects in decoder/playback isolation test") }
    let playback = LivePlayback(graph: graph, format: format, start: start)
    // Render through AVAudioEngine itself at a deterministic rate. Unlike a
    // device tap, this captures every output frame without changing device I/O.
    let pcmFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
    try playback.engine.enableManualRenderingMode(.offline, format: pcmFormat, maximumFrameCount: 512)
    let buffer = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: 512)!
    var output = [[Float]](repeating: [], count: 2)
    defer { playback.stop() }
    try playback.startPlayback()
    for _ in 0..<375 {
        RunLoop.current.run(until: Date().addingTimeInterval(0.001))
        playback.queue.sync {} // Drain scheduling notifications from the preceding cycle.
        let status = try playback.engine.renderOffline(512, to: buffer)
        guard status == .success else { throw SounderError.message("Audio engine could not render the continuity test") }
        for channel in 0..<2 { output[channel].append(contentsOf: UnsafeBufferPointer(start: buffer.floatChannelData![channel], count: Int(buffer.frameLength))) }
    }
    playback.stop()
    let sourceStart = Int(start * sampleRate)
    let frames = min(96_000, output[0].count - 8192, decoded.frameCount - sourceStart)
    guard frames > 48_000 else { throw SounderError.message("Insufficient PCM captured from live playback") }
    var bestOffset = 0, bestError = Double.infinity
    for offset in 0..<min(8192, output[0].count - 512) {
        var error = 0.0
        for frame in 0..<512 {
            let difference = Double(output[0][offset + frame] - decoded.channels[0][sourceStart + frame])
            error += difference * difference
        }
        if error < bestError { bestError = error; bestOffset = offset }
    }
    for channel in 0..<2 {
        var squared = 0.0, maximum = 0.0, incorrect = 0
        for frame in 0..<frames {
            let difference = Double(output[channel][bestOffset + frame] - decoded.channels[channel][sourceStart + frame])
            squared += difference * difference; maximum = max(maximum, abs(difference))
            if abs(difference) > 0.000001 { incorrect += 1 }
        }
        let rms = sqrt(squared / Double(frames))
        print(String(format: "Playback channel %d: RMS difference %.9f, max %.9f, mismatched frames %d/%d, alignment %d", channel, rms, maximum, incorrect, frames, bestOffset))
        guard rms < 0.000001 && incorrect == 0 else { throw SounderError.message("Live playback introduces missing, repeated or altered PCM frames") }
    }
    print("PASS: live playback reproduces the imported stereo PCM without gaps, repeated frames or timing drift")
}

extension AppDelegate {
    func verifyRestartUI() throws {
        func check(_ condition: Bool, _ message: String) throws {
            guard condition else { throw SounderError.message(message) }; print("PASS: \(message)")
        }
        editor.stop(); editor.seek(to: 2.25); editor.playPause()
        try check(editor.lastPlaybackStart == 2.25, "Play records its actual start for the timeline notch")
        RunLoop.current.run(until: Date().addingTimeInterval(0.12)); editor.stop()
        try check(editor.cursor > 2.25 && editor.lastPlaybackStart == 2.25, "Stop preserves the last-start marker while the cursor stays at the audio position")
        editor.seek(to: 4)
        window.makeKeyAndOrderFront(nil); window.makeFirstResponder(timeline)
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        let enter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
        try check(NSApp.mainMenu?.performKeyEquivalent(with: enter) == true, "Return invokes Play from Last Start through the application menu")
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        try check(editor.isPlaying && editor.player?.start == 2.25, "Enter starts from the marker after stopped seeking elsewhere (cursor: \(editor.cursor), start: \(String(describing: editor.player?.start)), key window: \(NSApp.keyWindow === window))")
        RunLoop.current.run(until: Date().addingTimeInterval(0.08))
        timeline.keyDown(with: enter)
        try check(editor.isPlaying && editor.player?.start == 2.25, "Enter during playback restarts from the marker without pausing")
        editor.effectsChanged()
        try check(editor.isPlaying && editor.lastPlaybackStart == 2.25, "Internal effect restarts preserve the last user start")
        editor.seek(to: 1.5)
        try check(editor.lastPlaybackStart == 1.5 && editor.isPlaying, "Live seeking updates the last-start marker")
        editor.stop(); editor.seek(to: 3); editor.playPause()
        try check(editor.lastPlaybackStart == 3, "A new Play updates the timeline notch")
        let keypad = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: "\u{3}", charactersIgnoringModifiers: "\u{3}", isARepeat: false, keyCode: 76)!
        timeline.keyDown(with: keypad)
        try check(editor.isPlaying && editor.player?.start == 3, "Keypad Enter also restarts from the last start")
        RunLoop.current.run(until: Date().addingTimeInterval(0.15)); editor.stop()
        editor.seek(to: 8.8); editor.playPause()
        let deadline = Date().addingTimeInterval(2)
        while editor.player != nil && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        try check(editor.player == nil && editor.cursor == 8.8 && editor.lastPlaybackStart == 8.8, "Natural playback completion returns the visible cursor to the last-start notch")
        refresh()
    }

    func verifyMuteUI() throws {
        func check(_ condition: Bool, _ message: String) throws {
            guard condition else { throw SounderError.message(message) }; print("PASS: \(message)")
        }
        func clickMute(_ row: Int) {
            let rect = timeline.trackMuteRect(row: row, depth: timeline.rows[row].1)
            let point = NSPoint(x: rect.midX, y: rect.midY)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = NSEvent.mouseEvent(with: type, location: timeline.convert(point, to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
                if type == .leftMouseDown { timeline.mouseDown(with: event) } else { timeline.mouseUp(with: event) }
            }
        }
        editor.seek(to: 1); editor.playPause()
        guard let playback = editor.player else { throw SounderError.message("Mute UI playback did not start") }
        let messages = editor.notifications.messages.count
        for row in [0, 1] {
            clickMute(row)
            try check(editor.project.tracks[row].muted && editor.player === playback && editor.isPlaying, "MUTE works during playback without replacing the stream")
            clickMute(row)
            try check(!editor.project.tracks[row].muted && editor.player === playback, "Unmute works during playback without replacing the stream")
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        try check(editor.cursor >= 1 && editor.cursor < 1.5, "Mute toggles preserve the advancing playhead")
        try check(editor.notifications.messages.count == messages, "Mute toggles remain silent without notifications")
        editor.stop(); editor.undo()
        try check(editor.project.tracks[1].muted, "Live mute changes remain undoable after stopping")
        editor.redo()
        try check(!editor.project.tracks[1].muted, "Live unmute changes remain redoable")
        editor.seek(to: 5.8); editor.dirty = false; refresh()
    }

    func verifyZoomUI() throws {
        let original = editor.project
        defer { editor.project = original; editor.cursor = 5.8; editor.zoom = 70; refresh() }
        func check(_ condition: Bool, _ message: String) throws {
            guard condition else { throw SounderError.message(message) }; print("PASS: \(message)")
        }
        for duration in [9.0, 244.333, 7200] {
            editor.project = original
            editor.project.tracks[0].clips[0].start = duration - 8
            editor.cursor = 0; editor.zoom = 70; refresh()
            if let scroll = timeline.enclosingScrollView {
                scroll.contentView.scroll(to: NSPoint(x: 400, y: 0))
            }
            for _ in 0..<40 { zoomOut() }
            try check(abs(timeline.frame.width - timeline.viewportSize.width) < 0.01, "Zoom out fits the full timeline to the viewport for \(duration) seconds")
            try check(timeline.header + editor.duration * editor.zoom <= timeline.visibleRect.maxX + 0.01 && abs(timeline.visibleRect.minX) < 0.01, "All fragments fit onscreen from time zero")
            let minimum = editor.zoom; zoomOut()
            try check(editor.zoom == minimum && timeline.rulerStep * editor.zoom >= 79.99, "Zoom stops at viewport width with readable ruler labels")
            zoomIn()
            try check(editor.zoom > minimum && timeline.frame.width > timeline.viewportSize.width, "Zoom in expands the timeline again")
        }
        try check(timeline.minimumZoom < 1, "Long projects can zoom out below the old fixed limit")
        editor.project.tracks = []; editor.cursor = 0; refresh()
        for _ in 0..<40 { zoomOut() }
        try check(editor.zoom.isFinite && abs(timeline.frame.width - timeline.viewportSize.width) < 0.01, "Empty projects have a finite zoom and fit the viewport")
    }

    func verifyRangeUI() throws {
        func check(_ condition: Bool, _ message: String) throws {
            guard condition else { throw SounderError.message(message) }; print("PASS: \(message)")
        }
        func send(_ type: NSEvent.EventType, _ time: Double) {
            let point = NSPoint(x: timeline.header + time * editor.zoom, y: timeline.ruler / 2)
            let event = NSEvent.mouseEvent(with: type, location: timeline.convert(point, to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            switch type {
            case .leftMouseDown: timeline.mouseDown(with: event)
            case .leftMouseDragged: timeline.mouseDragged(with: event)
            default: timeline.mouseUp(with: event)
            }
        }
        func drag(_ from: Double, _ to: Double) {
            send(.leftMouseDown, from); send(.leftMouseDragged, to); send(.leftMouseUp, to)
        }
        editor.zoom = 100; editor.seek(to: 5.8); editor.range = nil; refresh()
        send(.leftMouseDown, 1)
        try check(editor.cursor == 5.8, "Ruler mouse-down does not move the playhead")
        send(.leftMouseDragged, 4); send(.leftMouseUp, 4)
        try check(editor.range == 1...4 && editor.cursor == 5.8, "Selecting a range preserves the stopped playhead")
        drag(1, 0.5)
        try check(editor.range == 0.5...4 && editor.cursor == 5.8, "Dragging the left edge preserves the right edge and playhead")
        drag(4, 6)
        try check(editor.range == 0.5...6 && editor.cursor == 5.8, "Dragging the right edge preserves the left edge and playhead")
        drag(0.5, -1)
        try check(editor.range == 0...6, "Range resizing cannot select negative time")
        drag(6, 8); drag(5, 2)
        try check(editor.range == 2...5 && editor.cursor == 5.8, "Reverse selection creates an ordered range without seeking")
        send(.leftMouseDown, 2); send(.leftMouseUp, 2)
        try check(editor.range == 2...5 && editor.cursor == 5.8, "Clicking a range handle does not seek or discard the range")
        send(.leftMouseDown, 7)
        try check(editor.cursor == 5.8, "A potential ruler click defers seeking until mouse-up")
        send(.leftMouseUp, 7)
        try check(editor.range == nil && editor.cursor == 7, "An ordinary ruler click still selects the playback position")
        editor.seek(to: 1); editor.playPause()
        guard let playback = editor.player else { throw SounderError.message("Range UI playback did not start") }
        drag(2, 4); drag(4, 5)
        try check(editor.player === playback && editor.range == 2...5, "Selecting and resizing a range keeps the active audio stream")
        RunLoop.current.run(until: Date().addingTimeInterval(0.12))
        try check(editor.player === playback && editor.cursor >= 1 && editor.cursor < 1.5, "Playhead continues to follow playback while a range is selected")
        editor.stop(); editor.seek(to: 5.8); editor.zoom = 70; editor.range = 2...5; refresh()
    }
    func verifyPlayheadUI() throws {
        func check(_ condition: Bool, _ message: String) throws {
            guard condition else { throw SounderError.message(message) }; print("PASS: \(message)")
        }
        func click(time: Double, y: CGFloat) {
            let point = NSPoint(x: timeline.header + time * editor.zoom, y: y)
            func event(_ type: NSEvent.EventType) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: timeline.convert(point, to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            }
            timeline.mouseDown(with: event(.leftMouseDown)); timeline.mouseUp(with: event(.leftMouseUp))
        }
        func pauseOffscreen() throws {
            editor.seek(to: 7.2); editor.playPause()
            RunLoop.current.run(until: Date().addingTimeInterval(0.04))
            editor.playPause()
            try check(editor.player == nil && !editor.isPlaying, "Offscreen playback stops at its cursor and releases the old stream")
            if let scroll = timeline.enclosingScrollView {
                scroll.contentView.scroll(to: .zero); scroll.reflectScrolledClipView(scroll.contentView)
            }
            try check(timeline.header + editor.cursor * editor.zoom > timeline.visibleRect.maxX, "Paused playhead is outside the currently visible timeline")
        }
        editor.zoom = 240; refresh(); window.contentView?.layoutSubtreeIfNeeded()
        try pauseOffscreen()
        click(time: 1.25, y: timeline.ruler / 2)
        try check(editor.cursor == 1.25 && editor.player == nil, "Ruler click replaces the hidden paused position and discards its queued audio")
        editor.playPause()
        try check(editor.isPlaying && editor.player?.start == 1.25, "Play starts exactly at the ruler's selected time")
        RunLoop.current.run(until: Date().addingTimeInterval(0.04))
        editor.playPause(); let stoppedAt = editor.cursor
        RunLoop.current.run(until: Date().addingTimeInterval(0.08))
        try check(editor.cursor == stoppedAt && editor.player == nil, "Stopped cursor remains fixed without a hidden paused stream")
        editor.playPause()
        try check(editor.isPlaying && editor.player?.start == stoppedAt, "Play continues precisely from the visible stopped cursor")
        RunLoop.current.run(until: Date().addingTimeInterval(0.16))
        try check(editor.cursor >= stoppedAt && editor.cursor < stoppedAt + 0.4, "Cursor follows continued playback without jumping to the previous start")
        click(time: 2.5, y: timeline.ruler + timeline.rowHeight / 2)
        try check(editor.isPlaying && editor.player?.start == 2.5 && editor.cursor == 2.5 && !editor.selection.isEmpty, "Clicking a fragment seeks and keeps playback active")
        click(time: 1, y: timeline.ruler / 2)
        try check(editor.isPlaying && editor.player?.start == 1, "Clicking the ruler during playback immediately plays from the selected time")
        click(time: 3, y: timeline.ruler + timeline.rowHeight * 2.5)
        try check(editor.isPlaying && editor.player?.start == 3, "Clicking empty timeline space during playback immediately plays from the selected time")
        RunLoop.current.run(until: Date().addingTimeInterval(0.12))
        try check(editor.cursor >= 3 && editor.cursor < 3.4, "The cursor follows audio from the new position without jumping back")
        editor.stop()
        try pauseOffscreen()
        click(time: 1.75, y: timeline.ruler + timeline.rowHeight * 2.5)
        editor.playPause()
        try check(editor.player?.start == 1.75, "Clicking empty timeline space starts playback there even when the old cursor was offscreen")
        editor.playPause()
        editor.cursor = 3.25
        editor.playPause()
        try check(editor.player?.start == 3.25, "Play also invalidates stale paused audio when another control changes the cursor")
        editor.stop(); editor.seek(to: 12); editor.playPause()
        try check(editor.cursor == 12 && editor.player == nil, "A cursor beyond the audio end never jumps back to zero")
        editor.seek(to: 0); editor.zoom = 70; refresh()
    }
}

func runTransportPositionTests() throws {
    func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw SounderError.message(message) }; print("PASS: \(message)")
    }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SounderTransport-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try AudioStore(directory: directory)
    let frames = 192_000
    // Distinct values at each frame let the test identify the actual audio position.
    let source = AudioSignal(channels: [(0..<frames).map { 0.05 + Float($0) / Float(frames) * 0.4 },
                                        (0..<frames).map { -0.05 - Float($0) / Float(frames) * 0.2 }])
    let url = store.freshURL(); try store.write(source, to: url)
    let editor = Editor(store: store, makePlayback: { graph, format, start in
        let playback = LivePlayback(graph: graph, format: format, start: start)
        try playback.engine.enableManualRenderingMode(.offline, format: AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: AVAudioChannelCount(format.channels))!, maximumFrameCount: 512)
        return playback
    })
    editor.project.tracks[0].clips = [Clip(name: "Position marker", source: url.path, start: 0, duration: 4, order: 1)]
    func verifyAudioAndCursor(blocks: Int) throws {
        guard let playback = editor.player else { throw SounderError.message("Playback did not start") }
        let first = Int((playback.start * sampleRate).rounded())
        let buffer = AVAudioPCMBuffer(pcmFormat: playback.engine.manualRenderingFormat, frameCapacity: 512)!
        var lastCursor = editor.cursor
        for block in 0..<blocks {
            RunLoop.current.run(until: Date().addingTimeInterval(0.001)); playback.queue.sync {}
            guard try playback.engine.renderOffline(512, to: buffer) == .success else { throw SounderError.message("Could not render transport test") }
            for channel in 0..<2 { for frame in 0..<512 {
                let actual = buffer.floatChannelData![channel][frame]
                let expected = source.channels[channel][first + block * 512 + frame]
                guard abs(actual - expected) < 0.000001 else { throw SounderError.message("Rendered audio does not match the cursor's selected source position") }
            } }
            editor.updateTransportPosition()
            let end = Double(first + (block + 1) * 512) / sampleRate
            guard editor.cursor >= lastCursor && abs(editor.cursor - end) <= 512 / sampleRate else { throw SounderError.message("Cursor jumped backwards or diverged from the rendered audio") }
            lastCursor = editor.cursor
        }
    }
    editor.restartFromLastStart()
    try check(editor.player?.start == 0 && editor.lastPlaybackStart == 0, "Enter before the first start plays from zero")
    editor.stop()
    editor.seek(to: 0.75); editor.playPause()
    try verifyAudioAndCursor(blocks: 19)
    editor.playPause()
    let stoppedAt = editor.cursor
    try check(editor.player == nil && !editor.isPlaying, "Stopping releases all queued audio and stores one cursor position")
    RunLoop.current.run(until: Date().addingTimeInterval(0.06))
    try check(editor.cursor == stoppedAt, "Cursor remains exactly at the stopped audio position")
    for _ in 0..<3 {
        let selected = editor.cursor
        editor.playPause()
        try check(editor.player?.start == selected, "Play starts from the stopped cursor on every continuation")
        try verifyAudioAndCursor(blocks: 21)
        editor.playPause()
        try check(editor.cursor > selected && editor.player == nil, "Sound and cursor advance together across repeated stop/continue cycles")
    }
    editor.seek(to: 0.25); editor.playPause()
    try verifyAudioAndCursor(blocks: 23)
    editor.seek(to: 2.25)
    try check(editor.isPlaying && editor.player?.start == 2.25, "Seeking forward during playback stays active at the new position")
    try verifyAudioAndCursor(blocks: 17)
    editor.seek(to: 0.5)
    try check(editor.isPlaying && editor.player?.start == 0.5, "Seeking backward during playback stays active at the new position")
    try verifyAudioAndCursor(blocks: 17)
    editor.seek(to: 2.25)
    try verifyAudioAndCursor(blocks: 17)
    editor.stop()
    try check(editor.cursor > 2.25, "Seeking backwards and forwards starts both rendered channels and the cursor at the selected frame")
    editor.seek(to: 3)
    editor.restartFromLastStart()
    try check(editor.player?.start == 2.25 && editor.lastPlaybackStart == 2.25, "Enter ignores a stopped cursor move and plays from the last start")
    try verifyAudioAndCursor(blocks: 17)
    editor.restartFromLastStart()
    try verifyAudioAndCursor(blocks: 17)
    editor.stop()
    try check(editor.lastPlaybackStart == 2.25, "Repeated Enter preserves the marked start and renders the corresponding PCM")
    editor.restartFromLastStart()
    let completing = editor.player!
    let buffer = AVAudioPCMBuffer(pcmFormat: completing.engine.manualRenderingFormat, frameCapacity: 512)!
    for _ in 0..<200 {
        guard editor.player === completing else { break }
        RunLoop.current.run(until: Date().addingTimeInterval(0.001)); completing.queue.sync {}
        guard editor.player === completing else { break }
        guard try completing.engine.renderOffline(512, to: buffer) == .success else { throw SounderError.message("Could not render the natural completion test") }
    }
    RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    try check(editor.player == nil && editor.cursor == 2.25 && editor.lastPlaybackStart == 2.25, "Natural completion returns to the last start after rendering the entire remaining audio")
    editor.playPause()
    try check(editor.player?.start == 2.25, "Play after natural completion starts from the returned cursor")
    try verifyAudioAndCursor(blocks: 3)
    editor.stop(); let manualStop = editor.cursor
    completing.finished?(nil)
    try check(editor.cursor == manualStop && manualStop > 2.25, "Manual Stop stays at its position and ignores stale completion callbacks")
}


extension AppDelegate {
    func verifyBoundarySeekUI() throws {
        func check(_ condition: Bool, _ message: String) throws {
            guard condition else { throw SounderError.message(message) }; print("PASS: \(message)")
        }
        func key(_ code: UInt16, command: Bool = true) {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: command ? [.command] : [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: code == 123 ? "\u{f702}" : "\u{f703}", charactersIgnoringModifiers: code == 123 ? "\u{f702}" : "\u{f703}", isARepeat: false, keyCode: code)!
            timeline.keyDown(with: event)
        }
        editor.seek(to: 4); key(124)
        try check(editor.cursor == editor.duration && !editor.isPlaying, "Command-Right seeks to the exact audio end while stopped")
        let endX = timeline.header + editor.duration * editor.zoom
        try check(endX >= timeline.visibleFragmentRect.minX && endX <= timeline.visibleFragmentRect.maxX, "Boundary seeking scrolls the destination into view")
        key(123)
        try check(editor.cursor == 0 && !editor.isPlaying, "Command-Left seeks to zero while stopped")
        key(124, command: false)
        try check(editor.cursor > 0 && editor.cursor < editor.duration, "Unmodified Right retains its one-percent seek step")
        editor.seek(to: 3); editor.playPause(); key(123)
        try check(editor.isPlaying && editor.player?.start == 0, "Command-Left restarts active playback at the beginning without pausing")
        key(124)
        try check(editor.cursor == editor.duration, "Command-Right places the cursor at the end during playback without jumping back")
        let transport = NSApp.mainMenu!.items.compactMap { $0.submenu }.first { $0.title == "Transport" }!
        for selector in [#selector(seekToStart), #selector(seekToEnd)] {
            let item = transport.items.first { $0.action == selector }!
            try check(item.keyEquivalentModifierMask == [.command], "Boundary menu shortcut uses the Command modifier")
            projectLabel.sendAction(projectLabel.action, to: projectLabel.target)
            try check(!validateMenuItem(item), "Boundary shortcut leaves Command-arrow text editing to the field editor")
            projectNameField.finish(commit: false)
        }
        editor.stop(); editor.seek(to: 5.8); editor.dirty = false; refresh()
    }
}
