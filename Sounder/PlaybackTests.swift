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
        func send(_ type: NSEvent.EventType, _ time: Double, clicks: Int = 1, y: CGFloat? = nil, shift: Bool = false) {
            let point = NSPoint(x: timeline.header + time * editor.zoom, y: y ?? timeline.ruler / 2)
            let event = NSEvent.mouseEvent(with: type, location: timeline.convert(point, to: nil), modifierFlags: shift ? [.shift] : [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
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
        try check(editor.range == 2...5 && editor.cursor == 7, "A single ruler click seeks while preserving the range")
        send(.leftMouseDown, 2, clicks: 2); send(.leftMouseUp, 2, clicks: 2)
        try check(editor.range == nil && editor.cursor == 2, "A double click clears the range even at a range handle")
        let blankY = timeline.ruler + timeline.rowHeight * 2.5
        editor.range = 2...5
        send(.leftMouseDown, 7, y: blankY); send(.leftMouseUp, 7, y: blankY)
        try check(editor.range == 2...5 && editor.cursor == 7, "A single empty-area click preserves the range")
        send(.leftMouseDown, 7, clicks: 2, y: blankY); send(.leftMouseUp, 7, clicks: 2, y: blankY)
        try check(editor.range == nil, "A double empty-area click clears the range")
        let fragmentY = timeline.ruler + timeline.rowHeight / 2
        editor.range = 2...5
        send(.leftMouseDown, 3, y: fragmentY); send(.leftMouseUp, 3, y: fragmentY)
        try check(editor.range == 2...5, "A single fragment click preserves the range")
        fragmentDialogAutomation = { $0.alert.buttons[1].performClick(nil) }
        send(.leftMouseDown, 3, clicks: 2, y: fragmentY); send(.leftMouseUp, 3, clicks: 2, y: fragmentY)
        fragmentDialogAutomation = nil
        try check(editor.range == nil, "A double fragment click clears the range")
        editor.seek(to: 1); editor.playPause()
        guard let playback = editor.player else { throw SounderError.message("Range UI playback did not start") }
        drag(2, 4); drag(4, 5)
        try check(editor.player === playback && editor.range == 2...5, "Selecting and resizing a range keeps the active audio stream")
        RunLoop.current.run(until: Date().addingTimeInterval(0.12))
        try check(editor.player === playback && editor.cursor >= 1 && editor.cursor < 1.5, "Playhead continues to follow playback while a range is selected")
        editor.stop(); editor.seek(to: 5.8); editor.range = nil
        let previousMode = editor.project.tempoMode, previousTempo = editor.project.tempo
        defer { editor.project.tempoMode = previousMode; editor.project.tempo = previousTempo }
        editor.project.tempoMode = true; editor.project.tempo = 120; refresh()
        send(.leftMouseDown, 1.17); send(.leftMouseUp, 1.17)
        try check(editor.cursor == 1, "Tempo ruler clicks seek to the nearest beat start")
        send(.leftMouseDown, 1.17, shift: true); send(.leftMouseUp, 1.17, shift: true)
        try check(abs(editor.cursor - 1.17) < 0.000001, "Shift allows arbitrary ruler seeking in Tempo mode")
        let cursor = editor.cursor
        drag(0.67, 2.18)
        try check(editor.range == 0.5...2 && editor.cursor == cursor, "Tempo range selection snaps both bounds without moving the cursor")
        drag(0.5, 0.88); drag(2, 2.72)
        try check(editor.range == 1...2.5, "Both range handles snap to beat boundaries")
        send(.leftMouseDown, 2.5); send(.leftMouseDragged, 2.72, shift: true); send(.leftMouseUp, 2.72, shift: true)
        try check(abs((editor.range?.upperBound ?? 0) - 2.72) < 0.000001 && editor.range?.lowerBound == 1, "Shift resizes a range freely while preserving its opposite edge")
        editor.range = nil
        send(.leftMouseDown, 2.18, shift: true); send(.leftMouseDragged, 0.67, shift: true)
        let flags = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 56)!
        timeline.flagsChanged(with: flags)
        try check(editor.range == 0.5...2, "Releasing Shift during a reverse range drag immediately restores beat snapping")
        send(.leftMouseUp, 0.67)
        editor.range = nil
        send(.leftMouseDown, 3.17, y: fragmentY); send(.leftMouseUp, 3.17, y: fragmentY)
        try check(editor.cursor == 3, "Fragment clicks use the same Tempo cursor snapping")
        send(.leftMouseDown, 3.17, y: blankY, shift: true); send(.leftMouseUp, 3.17, y: blankY, shift: true)
        try check(abs(editor.cursor - 3.17) < 0.000001, "Shift bypasses Tempo snapping in the empty fragment area")
        editor.project.tempo = 90; editor.range = nil
        drag(0.9, 2.1)
        try check(abs((editor.range?.lowerBound ?? 0) - 2.0 / 3) < 0.000001 && editor.range?.upperBound == 2, "Range snapping follows the current BPM rather than a fixed time grid")
        editor.project.tempoMode = false; editor.range = nil
        drag(0.67, 2.18)
        try check(abs((editor.range?.lowerBound ?? 0) - 0.67) < 0.000001 && abs((editor.range?.upperBound ?? 0) - 2.18) < 0.000001, "Seconds mode retains arbitrary range boundaries")
        editor.seek(to: 5.8); editor.zoom = 70; editor.range = 2...5; refresh()
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
        editor.playPause()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        let stoppedAt = editor.cursor
        RunLoop.current.run(until: Date().addingTimeInterval(0.08))
        try check(editor.cursor == stoppedAt && editor.player == nil, "Stopped cursor remains fixed without a hidden paused stream")
        editor.playPause()
        try check(editor.isPlaying && editor.player?.start == stoppedAt, "Play continues precisely from the visible stopped cursor")
        RunLoop.current.run(until: Date().addingTimeInterval(0.16))
        try check(editor.cursor >= stoppedAt && editor.cursor < stoppedAt + 0.4, "Cursor follows continued playback without jumping to the previous start")
        click(time: 2.5, y: timeline.ruler + timeline.rowHeight / 2)
        try check(editor.isPlaying && editor.player?.start == 2.5 && !editor.selection.isEmpty, "Clicking a fragment seeks and keeps playback active (playing: \(editor.isPlaying), start: \(String(describing: editor.player?.start)), cursor: \(editor.cursor), selection: \(editor.selection.count), visible: \(timeline.visibleRect))")
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
    func verifyAudioAndCursor(blocks: Int, fadeIn: Bool = false, transition: Bool = false) throws {
        guard let playback = editor.player else { throw SounderError.message("Playback did not start") }
        let first = Int((playback.start * sampleRate).rounded())
        let buffer = AVAudioPCMBuffer(pcmFormat: playback.engine.manualRenderingFormat, frameCapacity: 512)!
        var lastCursor = editor.cursor
        for block in 0..<blocks {
            RunLoop.current.run(until: Date().addingTimeInterval(0.001)); playback.queue.sync {}
            guard try playback.engine.renderOffline(512, to: buffer) == .success else { throw SounderError.message("Could not render transport test") }
            if transition && block < 8 { editor.updateTransportPosition(); lastCursor = editor.cursor; continue }
            let sourceFirst = transition ? Int(((Double(buffer.floatChannelData![0][0]) - 0.05) / 0.4 * Double(frames)).rounded()) : first + block * 512
            guard sourceFirst >= first && sourceFirst + 512 <= frames else { throw SounderError.message("Transport resumed an obsolete source position") }
            for channel in 0..<2 { for frame in 0..<512 {
                let actual = buffer.floatChannelData![channel][frame]
                let gain = fadeIn ? Float(min(1, Double(block * 512 + frame) / 479)) : 1
                let expected = source.channels[channel][sourceFirst + frame] * gain
                guard abs(actual - expected) < 0.000001 else { throw SounderError.message("Rendered audio does not match the cursor's selected source position") }
            } }
            editor.updateTransportPosition()
            let end = Double(sourceFirst + 512) / sampleRate
            guard editor.cursor >= lastCursor && abs(editor.cursor - end) <= 512 / sampleRate else { throw SounderError.message("Cursor jumped backwards or diverged from the rendered audio") }
            lastCursor = editor.cursor
        }
    }
    func settlePause(_ playback: LivePlayback) throws {
        let buffer = AVAudioPCMBuffer(pcmFormat: playback.engine.manualRenderingFormat, frameCapacity: 512)!
        for _ in 0..<12 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.002)); playback.queue.sync {}
            if playback.pauseComplete { break }
            guard try playback.engine.renderOffline(512, to: buffer) == .success else { throw SounderError.message("Cannot render Space pause fade") }
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        try check(playback.pauseComplete && playback.engine.isRunning && !playback.node.isPlaying, "Space finishes its fade and pauses only the node, retaining the running engine")
    }
    editor.restartFromLastStart()
    try check(editor.player?.start == 0 && editor.lastPlaybackStart == 0, "Enter before the first start plays from zero")
    editor.stop()
    editor.seek(to: 0.75); editor.playPause()
    try verifyAudioAndCursor(blocks: 19)
    let prepared = editor.player!
    editor.playPause(); try settlePause(prepared)
    let stoppedAt = editor.cursor
    try check(editor.player == nil && !editor.isPlaying, "Space pauses at one audible cursor position")
    RunLoop.current.run(until: Date().addingTimeInterval(0.06))
    try check(editor.cursor == stoppedAt, "Cursor remains exactly at the stopped audio position")
    for _ in 0..<3 {
        let selected = editor.cursor
        editor.playPause()
        try check(editor.player?.start == selected, "Play starts from the stopped cursor on every continuation")
        try check(editor.player === prepared, "Space resumes the same prepared transport")
        try verifyAudioAndCursor(blocks: 21, fadeIn: true)
        editor.playPause(); try settlePause(prepared)
        try check(editor.cursor > selected && editor.player == nil, "Sound and cursor advance together across repeated stop/continue cycles")
    }
    let pausedMarker = editor.lastPlaybackStart!
    editor.seek(to: 0.25); editor.restartFromLastStart()
    try check(editor.player === prepared && editor.player?.start == pausedMarker, "Enter from pause reuses the prepared engine and selects the last-start marker")
    try verifyAudioAndCursor(blocks: 12, fadeIn: true)
    editor.playPause(); try settlePause(prepared)
    editor.seek(to: 0.25); editor.playPause()
    try check(editor.player === prepared, "Moving the paused cursor keeps the prepared engine for Space")
    try verifyAudioAndCursor(blocks: 23, fadeIn: true)
    editor.stop()
    try runLiveSeekAudioTests()
    editor.seek(to: 2.25); editor.playPause()
    try verifyAudioAndCursor(blocks: 17)
    editor.stop()
    editor.seek(to: 3)
    editor.restartFromLastStart()
    try check(editor.player?.start == 2.25 && editor.lastPlaybackStart == 2.25, "Enter ignores a stopped cursor move and plays from the last start")
    try verifyAudioAndCursor(blocks: 17)
    let beforeEnter = editor.player!
    editor.restartFromLastStart()
    try check(editor.player === beforeEnter, "Enter while playing seeks in the same running transport")
    try verifyAudioAndCursor(blocks: 17, transition: true)
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
        try check(editor.cursor > 0 && editor.cursor < editor.duration && !editor.isShuttling, "Unmodified Right retains its original one-percent seek step")
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

extension AppDelegate {
    func verifyStopReturnUI() throws {
        func check(_ value: Bool, _ message: String) throws {
            guard value else { throw SounderError.message(message) }; print("PASS: \(message)")
        }
        func buttons(_ view: NSView) -> [NSButton] {
            (view as? NSButton).map { [$0] } ?? view.subviews.flatMap { buttons($0) }
        }
        guard let stopButton = buttons(window.contentView!).first(where: { $0.action == #selector(stop) }) else { throw SounderError.message("No Stop icon") }
        let history = editor.undoStack.count
        editor.seek(to: 4); stopButton.performClick(nil)
        try check(editor.cursor == 0 && editor.player == nil, "Stop returns to zero before the first playback start")
        editor.seek(to: 1.25); editor.playPause()
        RunLoop.main.run(until: Date().addingTimeInterval(0.12))
        editor.playPause(); let paused = editor.cursor
        try check(paused > 1.25 && editor.player == nil, "Play/Pause still pauses at the actual audio position")
        stopButton.performClick(nil)
        try check(editor.cursor == 1.25 && editor.lastPlaybackStart == 1.25, "Stop icon returns a paused cursor to its last playback start")
        editor.playPause()
        try check(editor.player?.start == 1.25 && editor.isPlaying, "Play after Stop starts from the returned cursor")
        editor.seek(to: 2.5)
        RunLoop.main.run(until: Date().addingTimeInterval(0.08))
        stopButton.performClick(nil)
        try check(editor.cursor == 2.5 && editor.player == nil && !editor.isPlaying && editor.lastPlaybackStart == 2.5, "Stop ends active playback and returns to the latest successful live-seek start")
        RunLoop.main.run(until: Date().addingTimeInterval(0.12))
        try check(editor.cursor == 2.5, "Stopped callbacks do not move the returned cursor")
        editor.seek(to: 5); stopButton.performClick(nil)
        try check(editor.cursor == 2.5 && editor.undoStack.count == history, "Stop also returns a manually repositioned cursor without changing project history")
        editor.seek(to: 5.8); editor.dirty = false; refresh()
    }
}

extension AppDelegate {
    func verifyTrackMetersUI() throws {
        func check(_ value: Bool, _ message: String) throws {
            guard value else { throw SounderError.message(message) }; print("PASS: \(message)")
        }
        let original = editor.project
        let originalSelection = editor.selection, originalTrack = editor.selectedTrack
        defer { editor.stop(); editor.project = original; editor.selection = originalSelection; editor.selectedTrack = originalTrack; editor.dirty = false; refresh() }
        var files: [URL] = []
        defer { for file in files { try? FileManager.default.removeItem(at: file) } }
        var tracks: [Track] = []
        for (name, amplitude) in [("Green level", Float(0.1)), ("Yellow level", 0.6), ("Red level", 0.95)] {
            let url = editor.audio.freshURL(); files.append(url)
            try editor.audio.write(AudioSignal(channels: [Array(repeating: amplitude, count: 96_000), Array(repeating: -amplitude * 0.5, count: 96_000)]), to: url)
            tracks.append(Track(name: name, clips: [Clip(name: name, source: url.path, start: 0, duration: 2, order: tracks.count)]))
        }
        editor.project = Project(tracks: tracks); editor.selection = []; editor.selectedTrack = tracks[0].id
        editor.seek(to: 0); editor.playPause()
        RunLoop.current.run(until: Date().addingTimeInterval(0.25)); editor.updateTransportPosition()
        try check(recordButton.isEnabled && editor.canRecord, "Record icon remains enabled during playback")
        let recordMenu = NSApp.mainMenu!.items.compactMap { $0.submenu }.flatMap { $0.items }.first { $0.action == #selector(record) }!
        try check(validateMenuItem(recordMenu), "Record menu and R shortcut remain available during playback")
        try check(editor.isPlaying && zip(tracks, [0.1, 0.6, 0.95]).allSatisfy { abs((editor.trackMeters[$0.0.id]?.peak ?? 0) - $0.1) < 1e-5 }, "Header meters follow actual playback peaks for green, yellow and red levels")
        try check(zip(tracks, [0.05, 0.3, 0.475]).allSatisfy { abs((editor.trackMeters[$0.0.id]?.right.peak ?? 0) - $0.1) < 1e-5 }, "Header meters preserve separate right-channel levels")
        for row in tracks.indices {
            try check(timeline.trackNameRect(row: row, depth: 0).maxX < timeline.fragmentLeft - 74, "Track name leaves room for its peak readout")
        }
        func snapshot(_ suffix: String) {
            guard let index = CommandLine.arguments.firstIndex(of: "--snapshot"), index + 1 < CommandLine.arguments.count else { return }
            let path = URL(fileURLWithPath: CommandLine.arguments[index + 1]).deletingPathExtension().appendingPathExtension(suffix + ".png")
            let content = window.contentView!; content.layoutSubtreeIfNeeded()
            if let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                content.cacheDisplay(in: content.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?.write(to: path)
            }
        }
        snapshot("meters")
        editor.toggleMute(tracks[1].id)
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        guard let playback = editor.player else { throw SounderError.message("Meter UI playback stopped unexpectedly") }
        let mutedPeak = playback.queue.sync { playback.graph.trackPeaks[tracks[1].id] }
        try check(mutedPeak == StereoLevels(), "Muted tracks report zero signal without restarting playback")
        editor.stop(); refresh()
        try check(editor.trackMeters.values.allSatisfy { $0.level == 0 }, "Stopping clears every header fill immediately")
        RunLoop.current.run(until: Date().addingTimeInterval(1.05))
        try check(editor.trackMeters.values.allSatisfy { $0.peak == 0 }, "Stopped peak readouts clear after the one-second hold")
        editor.selectedTrack = tracks[0].id; editor.cursor = 0
        let input = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let recorder = try LiveRecorder(url: editor.audio.freshURL(), format: editor.project.audioFormat, inputFormat: input)
        files.append(recorder.url); try recorder.start(); editor.activateRecording(recorder)
        recorder.writer.append(captureTestBuffer(format: input, start: 0, frames: 12_000)); recorder.writer.waitForPendingWrites()
        editor.updateTransportPosition()
        try check(!recordButton.isEnabled && !editor.canRecord, "Record icon disables after capture has started")
        try check(editor.isRecording && (editor.trackMeters[tracks[0].id]?.peak ?? 0) > 0.4, "Recording peak readout measures actual captured microphone-format PCM")
        guard let recordingMeter = editor.trackMeters[tracks[0].id] else { throw SounderError.message("Missing stereo recording meter") }
        try check(abs(recordingMeter.right.peak - recordingMeter.left.peak * 0.25) < 1e-5, "Recording meters preserve independent captured left and right peaks")
        snapshot("recording")
    }
}

extension AppDelegate {
    func verifyProjectFileControlsUI() throws {
        func check(_ value: Bool, _ message: String) throws {
            guard value else { throw SounderError.message(message) }; print("PASS: \(message)")
        }
        let original = editor.project
        defer { editor.stop(); editor.project = original; editor.dirty = false; refresh() }
        window.makeKeyAndOrderFront(nil); window.makeFirstResponder(timeline)
        func verifyEnabled(_ enabled: Bool) throws {
            refresh()
            let items = window.toolbar!.items.filter { ["open", "save"].contains($0.itemIdentifier.rawValue) }
            try check(items.count == 2 && items.allSatisfy { $0.isEnabled == enabled && ($0.view as? NSControl)?.isEnabled == enabled }, "Titlebar Open/Save controls and toolbar items are \(enabled ? "enabled" : "disabled") together")
            let file = NSApp.mainMenu!.items.first { $0.title == "File" }!.submenu!
            file.update()
            let actions = file.items.filter { [#selector(openProject), #selector(saveProject), #selector(saveAs)].contains($0.action) }
            try check(actions.count == 3 && actions.allSatisfy { $0.isEnabled == enabled }, "File menu Open, Save and Save As follow transport availability")
        }
        try verifyEnabled(true)
        editor.seek(to: 1); editor.playPause()
        guard let playback = editor.player else { throw SounderError.message("File controls playback did not start") }
        try verifyEnabled(false)
        openProject(); saveProject(); saveAs()
        try check(editor.player === playback && editor.isPlaying && NSApp.modalWindow == nil && !editor.save(), "Open/Save actions cannot show dialogs or interrupt playback")
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("SounderBusySave-" + UUID().uuidString + ".sounder")
        var rejected = false; do { try editor.save(to: temporary) } catch { rejected = true }
        try check(rejected && !FileManager.default.fileExists(atPath: temporary.path), "Programmatic Save also refuses to write during playback")
        editor.stop(); try verifyEnabled(true)
        let input = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let recorder = try LiveRecorder(url: editor.audio.freshURL(), format: editor.project.audioFormat, inputFormat: input)
        try recorder.start(); editor.activateRecording(recorder)
        recorder.writer.append(captureTestBuffer(format: input, start: 0, frames: 4096)); recorder.writer.waitForPendingWrites()
        try verifyEnabled(false)
        openProject(); saveProject(); saveAs()
        try check(editor.isRecording && NSApp.modalWindow == nil && !editor.save(), "Open/Save stay disabled while recording without stopping capture")
        editor.stop(); try verifyEnabled(true)
    }
}

func runShuttleAudioTests() throws {
    func check(_ value: Bool, _ message: String) throws {
        guard value else { throw SounderError.message(message) }; print("PASS: \(message)")
    }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SounderShuttle-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try AudioStore(directory: directory)
    let format = ProjectAudioFormat(sampleRate: 48_000, channels: 2, bitDepth: 32)
    store.configure(format)
    let url = store.freshURL()
    let left = (0..<192_000).map { Float(0.1 + Double($0) / 480_000) }
    try store.write(AudioSignal(channels: [left, left.map { -$0 * 0.5 }]), to: url)
    var clip = Clip(name: "Shuttle", source: url.path, start: 0, duration: 4, order: 1)
    clip.fadeInMS = 0; clip.fadeOutMS = 0
    let effect = PluginEffect(name: "Never instantiate during shuttle", path: "/missing-shuttle-plugin.vst3", classID: "test")
    let track = Track(name: "Source", clips: [clip], effects: [effect])
    let project = Project(tracks: [track], audioFormat: format)
    let dry = DryShuttleSource(project: project, store: store)
    for direction in [-1.0, 1.0] {
        let playback = ShuttlePlayback(source: dry, start: 1, direction: direction, initialSpeed: direction)
        let buffer = try playback.render(frames: 512)!
        var error = 0.0
        for i in 250..<512 {
            let t = Double(i) / format.sampleRate
            let expected = 0.1 + playback.motion.position(at: t) / 10
            error = max(error, abs(Double(buffer.floatChannelData![0][i]) - expected), abs(Double(buffer.floatChannelData![1][i]) + expected * 0.5))
        }
        try check(error < 0.00001, "Shuttle renders real stereo PCM in the correct direction without loading plug-ins (\(direction))")
        playback.stop()
    }
    // Exercise the actual queued AVAudioEngine output across multiple refills.
    let queued = ShuttlePlayback(source: dry, start: 1, direction: -1)
    let pcm = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    try queued.engine.enableManualRenderingMode(.offline, format: pcm, maximumFrameCount: 512)
    queued.start()
    let deadline = Date().addingTimeInterval(2)
    while !queued.isPlaying && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    try check(queued.isPlaying, "Shuttle starts its audio engine asynchronously")
    let captured = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: 512)!
    var previous: Float?, discontinuity: Float = 0, silent = 0
    for block in 0..<32 {
        RunLoop.current.run(until: Date().addingTimeInterval(0.001))
        queued.queue.sync {}
        guard try queued.engine.renderOffline(512, to: captured) == .success else { throw SounderError.message("Cannot render queued shuttle audio") }
        if block >= 8 {
            for i in 0..<512 {
                let value = captured.floatChannelData![0][i]
                if value < 0.05 { silent += 1 }
                if let previous { discontinuity = max(discontinuity, abs(value - previous)) }
                previous = value
            }
        }
    }
    queued.stop()
    try check(silent == 0 && discontinuity < 0.001, "Actual reverse audio stays continuous across scheduled buffer refills (silent: \(silent), discontinuity: \(discontinuity))")
    // Capture the join itself through the existing live engine. An engine
    // restart, position jump or silent buffer cannot hide behind UI state.
    for direction in [-1.0, 1.0] {
        let liveGraph = try StreamingGraph(project: project, store: store) { _ in StreamingEffect(latency: 0, tail: 0) { $0 } }
        let live = LivePlayback(graph: liveGraph, format: format, start: 0.5)
        try live.engine.enableManualRenderingMode(.offline, format: pcm, maximumFrameCount: 512)
        try live.startPlayback()
        var output: [Float] = []
        func capture(_ blocks: Int) throws {
            for _ in 0..<blocks {
                RunLoop.current.run(until: Date().addingTimeInterval(0.001)); live.queue.sync {}
                guard try live.engine.renderOffline(512, to: captured) == .success else { throw SounderError.message("Cannot render live-to-shuttle transition") }
                output.append(contentsOf: UnsafeBufferPointer(start: captured.floatChannelData![0], count: 512))
            }
        }
        try capture(16)
        let source = DryShuttleSource(project: project, store: store, processed: liveGraph.outputCache)
        live.beginShuttle(source: source, direction: direction); live.queue.sync {}
        let anchor = liveGraph.position - 512
        let boundary = anchor - 24_000
        let plan = ShuttleMotion(start: Double(anchor) / format.sampleRate, direction: direction, end: 4, initialSpeed: 1)
        try capture(40)
        var maximum = 0.0
        for i in max(512, boundary - 128)..<min(output.count, boundary + 1024) {
            let position = i < boundary ? 0.5 + Double(i) / format.sampleRate : plan.position(at: Double(i - boundary) / format.sampleRate)
            maximum = max(maximum, abs(Double(output[i]) - (0.1 + position / 10)))
        }
        try check(live.isPlaying && maximum < 0.00001, "Live-to-shuttle join preserves every output sample without silence or a position jump (\(direction), error: \(maximum))")
        live.stop()
    }
    for direction in [-1.0, 1.0] {
        let stopping = ShuttlePlayback(source: dry, start: 2, direction: direction, initialSpeed: direction)
        let before = try stopping.render(frames: 512)!
        let position = stopping.renderedPosition, speed = stopping.renderedSpeed
        stopping.retarget(0)
        try check(stopping.motion.position(at: 0) == position && stopping.motion.speed(at: 0) == speed && stopping.motion.settlingDuration == 0.5, "Release-to-pause takes 0.5 seconds and preserves position and signed speed (\(direction))")
        let first = try stopping.render(frames: 512)!
        try check(abs(first.floatChannelData![0][0] - before.floatChannelData![0][511]) < 0.0001, "Release-to-pause has no sample discontinuity (\(direction))")
        var last = first, blocks = 0
        while let buffer = try stopping.render(frames: 512), blocks < 200 { last = buffer; blocks += 1 }
        try check(stopping.reachedEnd && stopping.hasSettled && abs(last.floatChannelData![0][Int(last.frameLength) - 1]) < 0.001, "Paused shuttle drains a smooth stop ending at silence (\(direction))")
        stopping.stop()
    }
    for initial in [-8.0, -4.0, 0.0, 4.0, 8.0] {
        let returning = ShuttleMotion(start: 10, direction: 1, end: 100, initialSpeed: initial, target: 1)
        let duration = returning.settlingDuration
        try check(duration == 0.5 && returning.speed(at: 0) == initial && returning.speed(at: duration) == 1 && returning.speed(at: duration + 2) == 1, "Release-to-Play continuously reaches and maintains exactly 1x (\(initial))")
        if initial < 0 { try check(returning.speed(at: 0.25) < 0 && returning.speed(at: duration) > 0, "Releasing reverse playback brakes through zero before going forward") }
    }
    for direction in [-1.0, 1.0] {
        let old = try StreamingGraph(project: project, store: store) { _ in StreamingEffect(latency: 0, tail: 0) { $0 } }
        let live = LivePlayback(graph: old, format: format, start: 1.5)
        try live.engine.enableManualRenderingMode(.offline, format: pcm, maximumFrameCount: 512)
        try live.startPlayback()
        func block() throws -> [Float] {
            RunLoop.current.run(until: Date().addingTimeInterval(0.001)); live.queue.sync {}
            guard try live.engine.renderOffline(512, to: captured) == .success else { throw SounderError.message("Cannot render shuttle release") }
            return Array(UnsafeBufferPointer(start: captured.floatChannelData![0], count: 512))
        }
        for _ in 0..<8 { _ = try block() }
        live.beginShuttle(source: DryShuttleSource(project: project, store: store, processed: old.outputCache), direction: direction)
        for _ in 0..<(direction < 0 ? 80 : 40) { _ = try block() }
        var previous = try block().last!, maximum: Float = 0
        let engine = live.engine, node = live.node
        live.releaseShuttle { cancelled in
            guard !cancelled() else { throw CancellationError() }
            return try StreamingGraph(project: project, store: store, dryGraph: old) { _ in StreamingEffect(latency: 0, tail: 0) { $0 } }
        }
        var blocks = 0
        while (!live.returnReady || abs(live.currentSpeed - 1) > 1e-8) && blocks < 180 {
            for value in try block() { maximum = max(maximum, abs(value - previous)); previous = value }
            blocks += 1
        }
        try check(live.returnReady && live.engine === engine && live.node === node && abs(live.currentSpeed - 1) < 1e-8, "Audible shuttle release returns to 1x without restarting the engine/node (\(direction))")
        try check(maximum < 0.005, "Actual release audio has no gap or hard join across braking, reversal and effect restoration (\(direction), jump: \(maximum))")
        live.completeReturn()
        let restored = live.snapshotGraph
        live.setMuted(true, trackID: track.id)
        for _ in 0..<12 { _ = try block() }
        let silence = try block()
        try check(live.snapshotGraph === restored && silence.allSatisfy { abs($0) < 1e-6 }, "Mute remains live on the restored DSP graph after shuttle release (\(direction))")
        live.stop()
    }
    let fullDry = try store.renderAudio(project, onlyTrack: track.id)
    for first in [1, 511, 1023, 47_999, 80_013] {
        let window = try dry.read(first..<(first + 513))
        try check(window.count == 1026 && (0..<513).allSatisfy { window[$0 * 2] == fullDry.channels[0][first + $0] }, "Integer source windows preserve every sample across arbitrary boundaries (\(first))")
    }
    let motion = ShuttleMotion(start: 100, direction: -1, end: 200)
    try check(motion.speed(at: 0) == 0 && motion.speed(at: 0.5) == -1 && motion.speed(at: 1) == -4 && motion.speed(at: 20) == -8, "Paused shuttle starts at zero speed and accelerates continuously to a bounded 8x")
    try check(abs((motion.position(at: 1.001) - motion.position(at: 0.999)) / 0.002 - motion.speed(at: 1)) < 0.00001 && motion.position(at: 100) == 0, "Cursor motion integrates audible speed and clamps exactly at timeline boundaries")
    let brake = ShuttleMotion(start: 100, direction: -1, end: 200, initialSpeed: 1)
    try check(brake.speed(at: 0) == 1 && brake.speed(at: 0.5) == 0 && brake.speed(at: 0.6) < 0 && brake.position(at: 0.5) > 100, "Rewind from Play brakes through zero before reversing, without changing the initial position or velocity")
    let accelerate = ShuttleMotion(start: 100, direction: 1, end: 200, initialSpeed: 1)
    try check(accelerate.position(at: 0) == 100 && accelerate.speed(at: 0) == 1 && accelerate.speed(at: 0.1) > 1, "Forward shuttle starts at the existing speed immediately and smoothly accelerates")
    var calls = 0
    let graph = try StreamingGraph(project: project, store: store) { _ in
        StreamingEffect(latency: 0, tail: 0) { samples in calls += 1; return samples.map { $0 * 0.25 } }
    }
    for _ in 0..<8 { _ = try graph.render(frames: 512) }
    let count = calls
    let cached = DryShuttleSource(project: project, store: store, processed: graph.outputCache)
    let wet = try cached.read(512..<1024), uncached = try cached.read(5000..<5512)
    try check(abs(wet[0] - left[512] * 0.25) < 1e-6 && abs(uncached[0] - left[5000]) < 1e-6 && calls == count, "Rendered regions reuse cached effects; unrendered regions use dry audio with zero plug-in calls")
    let transition = try cached.read(3500..<4500)
    let jump = zip(transition.dropFirst(2), transition).enumerated().filter { $0.offset % 2 == 0 }.map { abs($0.element.0 - $0.element.1) }.max() ?? 0
    try check(jump < 0.001, "A 10 ms transition avoids a hard discontinuity between cached effects and dry shuttle audio")
    var muted = track; muted.muted = true
    let mutedSource = DryShuttleSource(project: Project(tracks: [muted], audioFormat: format), store: store)
    try check(try mutedSource.read(1000..<1512).allSatisfy { $0 == 0 }, "Dry shuttle respects track mute")
    let cacheURL: URL = try {
        let cache = try ProcessedMixCache(channels: 2)
        try cache.append([0.25, -0.5]); try check(try cache.read(0..<1) == [0.25, -0.5], "Disk mix cache preserves exact channel samples")
        return cache.url
    }()
    try check(!FileManager.default.fileExists(atPath: cacheURL.path), "Temporary processed mix files are deleted when the cache is released")
}

extension AppDelegate {
    func verifyShuttleUI() throws {
        func check(_ value: Bool, _ message: String) throws {
            guard value else { throw SounderError.message(message) }; print("PASS: \(message)")
        }
        func key(_ type: NSEvent.EventType, _ code: UInt16, repeatKey: Bool = false, flags: NSEvent.ModifierFlags = [.shift]) -> NSEvent {
            NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: repeatKey, keyCode: code)!
        }
        func waitFor(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(4)
            while !condition() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        }
        func centered() -> Bool {
            let expected = min(max(0, timeline.frame.width - timeline.viewportSize.width), max(0, editor.cursor * editor.zoom - (timeline.viewportSize.width - timeline.header) / 2))
            return abs(timeline.visibleRect.minX - expected) < 2
        }
        window.makeKeyAndOrderFront(nil); window.makeFirstResponder(timeline)
        editor.stop(); editor.zoom = 500; editor.seek(to: 5); refresh()
        let originalTempo = editor.project.tempoMode
        for tempo in [false, true] {
            editor.project.tempoMode = tempo; editor.seek(to: 5); refresh()
            let step = (timeline.visibleRect.width - timeline.header) / editor.zoom * 0.01
            let right = key(.keyDown, 124, flags: [])
            try check(!handleShuttleShortcut(right), "Plain arrows never enter shuttle (Tempo: \(tempo))")
            timeline.keyDown(with: right)
            try check(abs(editor.cursor - (5 + step)) < 1e-6 && !editor.isShuttling && !editor.isPlaying, "Plain Right restores the historical viewport step (Tempo: \(tempo))")
            timeline.keyDown(with: key(.keyDown, 123, flags: []))
            try check(abs(editor.cursor - 5) < 1e-6, "Plain Left restores the same step in the opposite direction (Tempo: \(tempo))")
            editor.playPause(); timeline.keyDown(with: right)
            try check(editor.isPlaying && !editor.isShuttling && editor.player?.isShuttling == false, "Plain seeking preserves normal playback (Tempo: \(tempo))")
            editor.stop()
        }
        editor.project.tempoMode = originalTempo; editor.seek(to: 5); refresh()
        let before = editor.cursor
        try check(handleShuttleShortcut(key(.keyDown, 123)), "Shift-Left is captured before native menu key equivalents")
        try check(editor.player == nil && editor.shuttle != nil && editor.isShuttling && editor.cursor == before && centered(), "Arrow-down immediately creates shuttle at the exact paused cursor, without a step or hold timer")
        _ = handleShuttleShortcut(key(.keyUp, 123))
        waitFor { !editor.isShuttling }
        try check(!editor.isPlaying && !editor.isShuttling, "Releasing an arrow while initially paused glides to a stopped cursor")
        editor.playPause(); RunLoop.current.run(until: Date().addingTimeInterval(0.12))
        try check(editor.isPlaying && centered(), "Ordinary playback keeps the cursor centered horizontally")
        let originalPlayer = editor.player!
        let positionAtPress = originalPlayer.currentTime
        _ = handleShuttleShortcut(key(.keyDown, 123))
        try check(editor.player === originalPlayer && originalPlayer.isPlaying && originalPlayer.isShuttling && abs(editor.cursor - positionAtPress) < 0.03, "Rewind keeps the current engine/node playing and does not jump the cursor")
        try check(originalPlayer.shuttleUsesProcessedCache, "Rewind reuses processed audio from the preceding playback")
        RunLoop.current.run(until: Date().addingTimeInterval(0.25)); editor.updateTransportPosition()
        try check(editor.cursor > positionAtPress && centered(), "Rewind initially continues forward while braking, like an analog tape")
        RunLoop.current.run(until: Date().addingTimeInterval(0.55)); editor.updateTransportPosition()
        let first = editor.cursor
        _ = handleShuttleShortcut(key(.keyDown, 123, repeatKey: true))
        RunLoop.current.run(until: Date().addingTimeInterval(0.15)); editor.updateTransportPosition()
        try check(editor.player === originalPlayer && editor.isPlaying && editor.cursor < first && centered(), "The same live stream reverses after braking; key repeat never restarts it")
        _ = handleShuttleShortcut(key(.keyUp, 123))
        try check(editor.player === originalPlayer && editor.isPlaying && editor.isShuttling, "Releasing rewind keeps the same stream running while braking and turning forward")
        waitFor { !editor.isShuttling }
        try check(editor.isPlaying && editor.player === originalPlayer && abs(originalPlayer.currentSpeed - 1) < 1e-8, "Reverse release smoothly returns to ordinary playback without replacing the player")
        let restoredGraph = originalPlayer.snapshotGraph
        editor.toggleMute(editor.project.tracks[0].id)
        RunLoop.current.run(until: Date().addingTimeInterval(0.12))
        try check(editor.player === originalPlayer && originalPlayer.snapshotGraph === restoredGraph && editor.isPlaying, "Live Mute still works on the restored graph without interrupting playback")
        editor.toggleMute(editor.project.tracks[0].id)
        _ = handleShuttleShortcut(key(.keyDown, 124)); RunLoop.current.run(until: Date().addingTimeInterval(0.45)); editor.updateTransportPosition()
        let forward = editor.cursor
        RunLoop.current.run(until: Date().addingTimeInterval(0.2)); editor.updateTransportPosition()
        try check(editor.player?.isShuttling == true && editor.cursor > forward && centered(), "Holding Right auditions forward audio with the same acceleration and centered scrolling")
        let speedAtRelease = editor.player!.currentSpeed
        _ = handleShuttleShortcut(key(.keyUp, 124))
        try check(editor.player === originalPlayer && editor.isShuttling && speedAtRelease > 1, "Forward release keeps accelerated playback alive while it slows down")
        waitFor { !editor.isShuttling }
        try check(editor.player === originalPlayer && abs(originalPlayer.currentSpeed - 1) < 1e-8, "Forward release settles at exactly 1x in the same stream")
        editor.stop()
        editor.seek(to: 5); _ = handleShuttleShortcut(key(.keyDown, 123))
        _ = handleShuttleShortcut(key(.keyDown, 124))
        try check(!handleShuttleShortcut(key(.keyUp, 123)) && editor.isShuttling, "Releasing the older opposite arrow does not cancel the current direction")
        _ = handleShuttleShortcut(key(.keyUp, 124)); editor.stop()
        try check(!handleShuttleShortcut(key(.keyDown, 123, flags: [.command])), "Command-arrows retain the separate start/end shortcuts")
        window.makeFirstResponder(projectNameField)
        try check(!handleShuttleShortcut(key(.keyDown, 123)), "Arrow text editing never starts audio shuttle")
        window.makeFirstResponder(timeline)
        editor.stop(); editor.checkpoint(); editor.project.tracks[0].clips[0].volumeDB = -6
        editor.seek(to: 5); _ = handleShuttleShortcut(key(.keyDown, 123))
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        try check(editor.shuttle?.source.processed == nil, "An audio edit invalidates previously processed mix regions")
        let positionAtRelease = editor.cursor
        _ = handleShuttleShortcut(key(.keyUp, 123))
        try check(editor.isShuttling && editor.shuttle != nil, "Paused audition retains its audio node for the release glide")
        waitFor { !editor.isShuttling }
        try check(!editor.isPlaying && !editor.isShuttling && editor.cursor < positionAtRelease, "Paused reverse audition smoothly stops farther along its motion")
        let stopped = editor.cursor
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        try check(editor.cursor == stopped, "After the glide, the paused cursor stays exactly at the final audible position")
        editor.undo()
        editor.seek(to: 5); _ = handleShuttleShortcut(key(.keyDown, 123)); editor.stop()
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        try check(!editor.isShuttling && editor.shuttle == nil && !editor.isPlaying, "Stop cancels pending shuttle preparation and prevents delayed audio restart")
        _ = handleShuttleShortcut(key(.keyUp, 123))
        editor.seek(to: 5); editor.playPause()
        let interrupted = editor.player!
        _ = handleShuttleShortcut(key(.keyDown, 123))
        RunLoop.current.run(until: Date().addingTimeInterval(0.65))
        _ = handleShuttleShortcut(key(.keyUp, 123))
        _ = handleShuttleShortcut(key(.keyDown, 124))
        RunLoop.current.run(until: Date().addingTimeInterval(0.12))
        try check(editor.player === interrupted && editor.isPlaying && editor.isShuttling, "A new direction retargets an unfinished release in the same audio stream")
        _ = handleShuttleShortcut(key(.keyUp, 124)); editor.stop()
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        try check(editor.player == nil && editor.shuttle == nil && !editor.isShuttling && !editor.isPlaying, "Stop cancels background effect restoration without a delayed playback restart")
        editor.seek(to: 5)
        _ = handleShuttleShortcut(key(.keyDown, 124))
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        let shiftUp = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 56)!
        _ = handleShuttleShortcut(shiftUp)
        try check(handleShuttleShortcut(key(.keyDown, 124, repeatKey: true, flags: [])), "Releasing Shift suppresses repeats from the already-held arrow during braking")
        waitFor { !editor.isShuttling }
        try check(!editor.isPlaying && !editor.isShuttling, "Releasing Shift alone smoothly ends paused shuttle")
        _ = handleShuttleShortcut(key(.keyUp, 124, flags: []))
        editor.seek(to: 5.8); editor.zoom = 70; refresh()
    }
}


// Inspect actual device-graph output, including the old queued samples and the
// complete crossfade. A correct cursor alone must not mask a silent restart.
func runLiveSeekAudioTests() throws {
    func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw SounderError.message(message) }; print("PASS: \(message)")
    }
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SounderLiveSeek-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = try AudioStore(directory: dir)
    let format = ProjectAudioFormat(bitDepth: 32)
    store.configure(format)
    let samples = (0..<192_000).map { Float(0.1 + Double($0) / 480_000) }
    let url = store.freshURL()
    try store.write(AudioSignal(channels: [samples, samples.map { -$0 * 0.5 }]), to: url)
    let effect = PluginEffect(name: "Live gain", path: "test", classID: "test")
    let track = Track(name: "Seek", clips: [Clip(name: "Seek", source: url.path, start: 0, duration: 4, order: 1)], effects: [effect])
    let project = Project(tracks: [track], audioFormat: format)
    var instances = 0, calls = 0
    let graph = try StreamingGraph(project: project, store: store) { _ in
        instances += 1
        return StreamingEffect(latency: 0, tail: 0) { samples in calls += 1; return samples.map { $0 * 0.5 } }
    }
    let playback = LivePlayback(graph: graph, format: format, start: 0.5)
    let pcm = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    try playback.engine.enableManualRenderingMode(.offline, format: pcm, maximumFrameCount: 512)
    let buffer = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: 512)!
    try playback.startPlayback()
    defer { playback.stop() }
    let engine = playback.engine, node = playback.node
    var outputFrames = 0
    func capture() throws -> [Float] {
        RunLoop.current.run(until: Date().addingTimeInterval(0.001)); playback.queue.sync {}
        guard try engine.renderOffline(512, to: buffer) == .success else { throw SounderError.message("Cannot render in-place seek") }
        outputFrames += 512
        return (0..<512).flatMap { i in [buffer.floatChannelData![0][i], buffer.floatChannelData![1][i]] }
    }
    for _ in 0..<12 { _ = try capture() }
    var sourceOrigin = 24_000, outputOrigin = 0
    for target in [96_000, 12_000, 144_000] {
        playback.queue.sync {}
        let oldNext = graph.position
        let boundary = outputOrigin + oldNext - sourceOrigin
        let callsBefore = calls
        let began = ProcessInfo.processInfo.systemUptime
        playback.seek(to: Double(target) / 48_000)
        playback.queue.sync {}
        let elapsed = ProcessInfo.processInfo.systemUptime - began
        try check(engine.isRunning && node.isPlaying && playback.engine === engine && playback.node === node && playback.graph === graph && instances == 1,
                  "Live seek retains the running engine, player, graph and effect instances")
        try check(calls - callsBefore <= 2, "Live seek processes only the short transition, never project history")
        try check(elapsed < 0.1, "Live seek preparation finishes without a main-thread rebuild (\(elapsed * 1000) ms)")
        var maximum = 0.0, previous: Float?
        for _ in 0..<14 {
            let first = outputFrames
            let values = try capture()
            for i in 0..<512 {
                let index = first + i
                let delta = index - boundary
                let oldFrame = oldNext + delta
                let expected: Double
                if delta < 0 { expected = Double(samples[sourceOrigin + index - outputOrigin]) * 0.5 }
                else if delta < 480 {
                    let blend = Double(delta) / 479
                    expected = Double(samples[oldFrame]) * 0.5 * (1 - blend) + Double(samples[target + delta]) * 0.5 * blend
                } else { expected = Double(samples[target + delta]) * 0.5 }
                maximum = max(maximum, abs(Double(values[i * 2]) - expected), abs(Double(values[i * 2 + 1]) + expected * 0.5))
                if let previous { try checkSeekStep(abs(values[i * 2] - previous) < 0.001) }
                previous = values[i * 2]
            }
            // The visible cursor must follow the source actually being heard.
            let audible = playback.currentTime * 48_000
            let expectedCursor = outputFrames < boundary ? sourceOrigin + outputFrames - outputOrigin : target + outputFrames - boundary
            try checkSeekStep(abs(audible - Double(expectedCursor)) <= 512)
        }
        try check(maximum < 0.000001, "Both rendered channels preserve queued audio and a sample-accurate 10 ms seek crossfade (error: \(maximum))")
        sourceOrigin = target; outputOrigin = boundary
    }
    // Latest pending request wins, without reviving any discarded stream.
    playback.queue.suspend()
    playback.seek(to: 2); playback.seek(to: 0.25); playback.seek(to: 1.5)
    playback.queue.resume(); playback.queue.sync {}
    try check(playback.seekPosition == 1.5 && graph.position == 72_000, "Rapid pending seeks coalesce to the latest position")
    for _ in 0..<12 { _ = try capture() }
    try check(playback.currentTime >= 1.5 && playback.currentTime < 1.8, "Rapid seeking leaves cursor and audio on the latest destination")
    var completions = 0
    playback.finished = { _ in completions += 1 }
    playback.seek(to: Double(graph.totalFrames - 700) / 48_000); playback.queue.sync {}
    for _ in 0..<2 { _ = try capture() }
    playback.seek(to: 0.5); playback.queue.sync {}
    for _ in 0..<16 { _ = try capture() }
    try check(completions == 0 && playback.isPlaying && playback.currentTime >= 0.5 && playback.currentTime < 0.8,
              "Seeking away from an already queued final buffer does not stop the new destination")
    // A processor with real delay must receive only its latency worth of
    // pre-roll, without rebuilding or replaying earlier project audio.
    let latency = 2048
    var delay = [Float](repeating: 0, count: latency * 2), delayPosition = 0, delayedCalls = 0
    let delayed = try StreamingGraph(project: project, store: store) { _ in
        StreamingEffect(latency: latency, tail: 0) { input in
            delayedCalls += 1
            return input.map { value in
                let output = delay[delayPosition]
                delay[delayPosition] = value; delayPosition = (delayPosition + 1) % delay.count
                return output
            }
        }
    }
    _ = try delayed.render(frames: 512)
    let before = delayedCalls
    try delayed.seek(to: 96_000)
    let delayedOutput = try delayed.render(frames: 512)
    try check(delayedCalls - before == 5 && (0..<512).allSatisfy { abs(delayedOutput[$0 * 2] - samples[96_000 + $0]) < 1e-6 },
              "Declared effect latency is compensated after seeking with bounded pre-roll")
    playback.stop()
    for rate in [44_100.0, 192_000.0] {
        let settings = ProjectAudioFormat(sampleRate: rate, bitDepth: 32)
        store.configure(settings)
        let formatProject = Project(tracks: [Track(name: "Format", clips: track.clips)], audioFormat: settings)
        let reference = try store.renderAudio(formatProject, onlyTrack: formatProject.tracks[0].id)
        let formatGraph = try StreamingGraph(project: formatProject, store: store) { _ in fatalError("No effects") }
        let live = LivePlayback(graph: formatGraph, format: settings, start: 0)
        let pcm = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        try live.engine.enableManualRenderingMode(.offline, format: pcm, maximumFrameCount: 512)
        let captured = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: 512)!
        try live.startPlayback()
        var frame = 0
        func block() throws {
            RunLoop.current.run(until: Date().addingTimeInterval(0.001)); live.queue.sync {}
            guard try live.engine.renderOffline(512, to: captured) == .success else { throw SounderError.message("Cannot render format seek") }
        }
        for _ in 0..<10 { try block(); frame += 512 }
        // AVAudioPlayerNode delivers consumption notifications asynchronously
        // after offline rendering returns. Drain them before fixing the queue
        // boundary; no output clock runs while this offline engine is idle.
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        live.queue.sync {}
        let boundary = formatGraph.position
        // Both requests are processed before any new audio is queued. The
        // second must fade from the audible stream, never the unheard target.
        live.seek(to: 1); live.queue.sync {}
        live.seek(to: 2); live.queue.sync {}
        let target = Int(2 * rate), fade = Int(rate * 0.010)
        var maximum = 0.0, detail = ""
        for _ in 0..<26 {
            try block()
            for i in 0..<512 {
                let delta = frame + i - boundary
                for ch in 0..<2 {
                    let expected: Float
                    if delta < 0 { expected = reference.channels[ch][frame + i] }
                    else if delta < fade {
                        let blend = Float(delta) / Float(fade - 1)
                        expected = reference.channels[ch][boundary + delta] * (1 - blend) + reference.channels[ch][target + delta] * blend
                    } else { expected = reference.channels[ch][target + delta] }
                    let difference = abs(Double(captured.floatChannelData![ch][i] - expected))
                    if difference > maximum { maximum = difference; detail = "index=\(frame + i) boundary=\(boundary) ch=\(ch) actual=\(captured.floatChannelData![ch][i]) expected=\(expected) cursor=\(live.currentTime) graph=\(formatGraph.position)" }
                }
            }
            frame += 512
        }
        try check(maximum < 1e-6 && live.isPlaying && live.currentTime >= 2,
                  "Repeated processed seeks preserve the audible crossfade at \(Int(rate)) Hz (error: \(maximum), \(detail))")
        live.stop()
    }
    let cache = try ProcessedMixCache(channels: 2)
    try cache.write([0.25, -0.5, 0.1, -0.2], at: 1000)
    try check(cache.cachedRegions(in: 0..<2000) == [1000..<1002] && cache.cachedRegions(in: 0..<512).isEmpty,
              "Sparse processed cache never treats skipped audio as cached silence")
    try check(try cache.read(1000..<1002) == [0.25, -0.5, 0.1, -0.2], "Sparse cache retains exact processed samples at their source positions")
}

private func checkSeekStep(_ value: Bool) throws {
    guard value else { throw SounderError.message("Seek output clicks, contains a gap, or diverges from its audible cursor") }
}

func runPauseContinuityTests() throws {
    func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw SounderError.message(message) }; print("PASS: \(message)")
    }
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SounderPause-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = try AudioStore(directory: dir)
    let format = ProjectAudioFormat(bitDepth: 32)
    let values = (0..<192_000).map { Float(0.1 + Double($0) / 480_000) }
    let url = store.freshURL()
    try store.write(AudioSignal(channels: [values, values.map { -$0 * 0.5 }]), to: url)
    let project = Project(tracks: [Track(name: "Pause", clips: [Clip(name: "Pause", source: url.path, start: 0, duration: 4, order: 1)])], audioFormat: format)
    let graph = try StreamingGraph(project: project, store: store) { _ in fatalError("No effects") }
    let live = LivePlayback(graph: graph, format: format, start: 0.5)
    let pcm = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    try live.engine.enableManualRenderingMode(.offline, format: pcm, maximumFrameCount: 512)
    let buffer = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: 512)!
    try live.startPlayback()
    defer { live.stop() }
    func block() throws -> [Float] {
        RunLoop.current.run(until: Date().addingTimeInterval(0.002)); live.queue.sync {}
        guard try live.engine.renderOffline(512, to: buffer) == .success else { throw SounderError.message("Cannot render pause audio") }
        return (0..<512).flatMap { [buffer.floatChannelData![0][$0], buffer.floatChannelData![1][$0]] }
    }
    for _ in 0..<10 { _ = try block() }
    RunLoop.current.run(until: Date().addingTimeInterval(0.01)); live.queue.sync {}
    try live.pause()
    let end = Int((live.pausePosition * 48_000).rounded()), fadeStart = end - 480
    var sourceFrame = 24_000 + 5120, error = 0.0
    for _ in 0..<10 {
        if live.pauseComplete { break }
        let output = try block()
        for i in 0..<512 {
            let frame = sourceFrame + i
            let gain = frame < fadeStart ? 1 : max(0, 1 - Double(frame - fadeStart) / 479)
            let expected = Float(Double(values[frame]) * gain)
            error = max(error, abs(Double(output[i * 2] - expected)), abs(Double(output[i * 2 + 1] + expected * 0.5)))
        }
        sourceFrame += 512
    }
    try check(error < 1e-6 && live.pauseComplete && live.engine.isRunning && !live.node.isPlaying && live.currentTime == live.pausePosition,
              "Space renders a sample-accurate stereo fade-out and freezes at its audible end (error: \(error))")
    let frozen = live.currentTime, rendered = live.renderedFrames
    RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    try check(live.currentTime == frozen && live.renderedFrames == rendered, "Paused transport does not advance the cursor or process audio")
    let engine = live.engine, node = live.node
    try live.resume(to: frozen)
    error = 0
    for n in 0..<12 {
        let output = try block()
        for i in 0..<512 {
            let frame = n * 512 + i
            let gain = min(1, Double(frame) / 479)
            let expected = Float(Double(values[end + frame]) * gain)
            error = max(error, abs(Double(output[i * 2] - expected)), abs(Double(output[i * 2 + 1] + expected * 0.5)))
        }
    }
    try check(error < 1e-6 && live.engine === engine && live.node === node && live.graph === graph && live.isPlaying,
              "Space resumes with a sample-accurate fade-in on the same engine, node and graph (error: \(error))")
    // Resume before the pause fade is presented: the fade-in must already be
    // queued, so waiting for a presentation callback cannot leave a silent gap.
    try live.pause(); try live.resume(to: live.pausePosition)
    var previous: Float?, jump: Float = 0, zeros = 0, longestSilence = 0
    for _ in 0..<20 {
        let output = try block()
        for i in 0..<512 {
            let value = output[i * 2]
            if abs(value) < 1e-6 { zeros += 1; longestSilence = max(longestSilence, zeros) } else { zeros = 0 }
            if let previous { jump = max(jump, abs(value - previous)) }
            previous = value
        }
    }
    try check(live.isPlaying && live.engine === engine && longestSilence <= 2 && jump < 0.001,
              "Rapid Space pause/resume joins fades without a gap or obsolete pause callback (silence: \(longestSilence), jump: \(jump))")
}

func runLoopPlaybackTests() throws {
    func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw SounderError.message(message) }; print("PASS: \(message)")
    }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SounderLoop-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try AudioStore(directory: directory)
    let format = ProjectAudioFormat(bitDepth: 32)
    store.configure(format)
    let values = (0..<48_000).map { Float(0.15 + Double($0) / 240_000) }
    let source = store.freshURL()
    try store.write(AudioSignal(channels: [values, values.map { -$0 * 0.5 }]), to: source, bitDepth: 32)
    var track = Track(name: "Loop", clips: [Clip(name: "Loop", source: source.path, start: 0, duration: 1, order: 1)])
    track.effects = [PluginEffect(name: "Identity", path: "test", classID: "identity")]
    let project = Project(tracks: [track], audioFormat: format)
    let dry = try store.renderAudio(project, onlyTrack: track.id)
    let cases: [(Range<Double>, Double)] = [(0.123..<0.187, 0.123), (0.031..<0.034, 0.031), (0..<1, 0), (1.2..<1.3, 1.2), (0.123..<0.187, 0.02)]
    for (region, start) in cases {
        var instances = 0
        let graph = try StreamingGraph(project: project, store: store) { _ in
            instances += 1; return StreamingEffect(latency: 0, tail: 4096) { $0 }
        }
        let live = LivePlayback(graph: graph, format: format, start: start)
        let pcm = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        try live.engine.enableManualRenderingMode(.offline, format: pcm, maximumFrameCount: 512)
        let buffer = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: 512)!
        var finished = 0
        live.finished = { _ in finished += 1 }
        live.setLoop(region); try live.startPlayback()
        defer { live.stop() }
        let first = Int((region.lowerBound * 48_000).rounded()), last = Int((region.upperBound * 48_000).rounded()), length = last - first
        let fade = Double(max(1, min(480, length / 2)))
        let startFrame = Int((start * 48_000).rounded())
        var count = 0, maximumError = 0.0, wraps = false, previous = start
        func block() throws {
            RunLoop.current.run(until: Date().addingTimeInterval(0.001)); live.queue.sync {}
            guard try live.engine.renderOffline(512, to: buffer) == .success else { throw SounderError.message("Cannot render Loop audio") }
        }
        for _ in 0..<(length >= 48_000 ? 210 : 75) {
            try block()
            for i in 0..<512 {
                let elapsed = count + i, firstPass = elapsed < last - startFrame
                let frame = firstPass ? startFrame + elapsed : first + (elapsed - (last - startFrame)) % length
                let incoming = !firstPass || startFrame == first ? Double(frame - first) / fade : 1
                let gain = min(1, max(0, min(incoming, Double(last - 1 - frame) / fade)))
                for channel in 0..<2 {
                    let expected = frame < dry.frameCount ? dry.channels[channel][frame] * Float(gain) : 0
                    maximumError = max(maximumError, abs(Double(buffer.floatChannelData![channel][i] - expected)))
                }
            }
            count += 512
            let position = live.currentTime
            if position < previous { wraps = true }
            previous = position
            try checkPosition(position, in: min(start, region.lowerBound)..<region.upperBound)
            _ = live.consumeTrackPeaks(at: position)
        }
        try check(maximumError < 1e-6 && wraps && live.isPlaying && finished == 0 && live.graph === graph && instances == 1,
                  "Loop \(region), starting at \(start), repeats exact stereo frames with edge smoothing and an audible cursor, retaining the engine and effects (error: \(maximumError))")
        try live.pause()
        for _ in 0..<12 where !live.pauseComplete { try block() }
        try check(live.pauseComplete && live.engine.isRunning && !live.node.isPlaying, "Space can pause looping playback without restarting hardware")
        try live.resume(to: live.pausePosition)
        for _ in 0..<6 { try block() }
        try check(live.isPlaying && live.graph === graph, "Space resumes the prepared looping transport")
        live.setLoop(nil)
        for _ in 0..<180 where finished == 0 { try block() }
        try check(finished == 1, "Disabling Loop restores natural playback completion")
        live.stop()
    }
    do {
        let graph = try StreamingGraph(project: project, store: store) { _ in StreamingEffect(latency: 0, tail: 0) { $0 } }
        let live = LivePlayback(graph: graph, format: format, start: 0.3)
        let pcm = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        try live.engine.enableManualRenderingMode(.offline, format: pcm, maximumFrameCount: 512)
        let buffer = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: 512)!
        var finished = false, error = 0.0
        live.finished = { _ in finished = true }
        live.setLoop(0.123..<0.187); try live.startPlayback()
        func block() throws {
            RunLoop.current.run(until: Date().addingTimeInterval(0.001)); live.queue.sync {}
            guard try live.engine.renderOffline(512, to: buffer) == .success else { throw SounderError.message("Cannot render playback after Loop region") }
        }
        for n in 0..<45 {
            try block()
            for i in 0..<512 { for ch in 0..<2 {
                error = max(error, abs(Double(buffer.floatChannelData![ch][i] - dry.channels[ch][14_400 + n * 512 + i])))
            } }
        }
        try check(error < 1e-6 && live.currentTime > 0.3, "Starting after the selected Loop range plays forward without relocation or attenuation")
        for _ in 0..<75 where !finished { try block() }
        try check(finished, "Starting after the Loop range completes normally at the project end")
        live.stop()
    }
    for direction in [-1.0, 1.0] {
        let graph = try StreamingGraph(project: project, store: store) { _ in StreamingEffect(latency: 0, tail: 0) { $0 } }
        let live = LivePlayback(graph: graph, format: format, start: 0.2)
        let pcm = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        try live.engine.enableManualRenderingMode(.offline, format: pcm, maximumFrameCount: 512)
        let buffer = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: 512)!
        live.setLoop(0..<1); try live.startPlayback()
        let engine = live.engine, node = live.node
        var previous: Float?, jump: Float = 0
        func block() throws {
            RunLoop.current.run(until: Date().addingTimeInterval(0.002)); live.queue.sync {}
            guard try live.engine.renderOffline(512, to: buffer) == .success else { throw SounderError.message("Cannot render looping shuttle return") }
            for i in 0..<512 {
                let sample = buffer.floatChannelData![0][i]
                if let previous { jump = max(jump, abs(sample - previous)) }
                previous = sample
            }
        }
        for _ in 0..<8 { try block() }
        live.beginShuttle(source: DryShuttleSource(project: project, store: store, processed: graph.outputCache), direction: direction)
        for _ in 0..<8 { try block() }
        live.releaseShuttle { _ in
            try StreamingGraph(project: project, store: store, dryGraph: graph) { _ in StreamingEffect(latency: 0, tail: 0) { $0 } }
        }
        var restored = false
        for _ in 0..<160 {
            try block()
            if !restored, live.returnReady, abs(live.currentSpeed - 1) < 1e-8 { live.completeReturn(); restored = true }
        }
        try check(restored && live.isPlaying && (0..<1).contains(live.currentTime) && live.engine === engine && live.node === node && jump < 0.01,
                  "Loop survives shuttle release on the same engine without a hard join (\(direction), jump: \(jump))")
        live.stop()
    }
    let editor = Editor(store: store)
    editor.project = project
    editor.toggleLoop()
    try check(editor.loopRange == 0..<1 && editor.project.loopEnabled, "Loop defaults to audio bounds, excluding effect tails")
    editor.range = 0.2...0.4
    try check(editor.loopRange == 0.2..<0.4, "Loop uses the selected timeline period")
    editor.range = 0.3...0.3
    try check(editor.loopRange == 0..<1, "An empty selection falls back to the whole project")
    let saved = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(editor.project))
    try check(saved.loopEnabled, "Project serialization preserves Loop mode")
    func checkPosition(_ position: Double, in region: Range<Double>) throws {
        guard position >= region.lowerBound - 1e-8 && position <= region.upperBound + 1e-8 else { throw SounderError.message("Loop cursor escaped its audible range: \(position), \(region)") }
    }
}

extension AppDelegate {
    func verifyLoopUI() throws {
        let original = editor.project, originalRange = editor.range
        defer {
            editor.stop(); editor.project = original; editor.range = originalRange
            editor.cursor = 0; editor.dirty = false; editor.undoStack = []; editor.redoStack = []; refresh()
        }
        editor.project.loopEnabled = false; editor.range = 1...1.2; editor.cursor = 0; refresh()
        loopButton.performClick(nil)
        guard editor.project.loopEnabled, loopButton.state == .on else { throw SounderError.message("Loop button did not activate") }
        editor.playPause()
        guard let live = editor.player, live.start == 0 else { throw SounderError.message("Loop moved the cursor to the selected period on Play") }
        let engine = live.engine, node = live.node, graph = live.snapshotGraph
        RunLoop.current.run(until: Date().addingTimeInterval(0.25)); editor.updateTransportPosition()
        guard (0..<1).contains(editor.cursor) else { throw SounderError.message("Loop skipped the lead-in before the selected period") }
        RunLoop.current.run(until: Date().addingTimeInterval(1.2)); editor.updateTransportPosition()
        guard editor.isPlaying, (1..<1.2).contains(editor.cursor), editor.player === live, editor.lastPlaybackStart == 0 else { throw SounderError.message("Selected Loop did not wrap at its right edge while preserving the start marker") }
        editor.range = 1.25...1.35
        RunLoop.current.run(until: Date().addingTimeInterval(0.55)); editor.updateTransportPosition()
        guard (1.25..<1.35).contains(editor.cursor) else { throw SounderError.message("Loop did not follow a live range edit") }
        editor.range = nil
        guard editor.loopRange == 0..<editor.duration else { throw SounderError.message("Clearing the selection did not restore full-project Loop") }
        loopButton.performClick(nil)
        guard !editor.project.loopEnabled, loopButton.state == .off, editor.player === live,
              live.engine === engine, live.node === node, live.snapshotGraph === graph else { throw SounderError.message("Loop toggle restarted the transport") }
        editor.stopAndReturnToStart()
        guard !editor.isPlaying else { throw SounderError.message("Stop did not end looping playback") }
        editor.range = 1...1.2; editor.cursor = 2; loopButton.performClick(nil); editor.playPause()
        guard editor.player?.start == 2 else { throw SounderError.message("Starting after Loop moved the cursor backward") }
        RunLoop.current.run(until: Date().addingTimeInterval(0.15)); editor.updateTransportPosition()
        editor.playPause()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1)); editor.updateTransportPosition()
        let paused = editor.cursor
        editor.playPause()
        guard paused >= 2, editor.player?.start == paused else { throw SounderError.message("Resuming outside Loop relocated the cursor") }
        editor.stop()
        print("PASS: Loop starts and resumes at the cursor, plays the lead-in, wraps only at the right edge, preserves the start marker, and does not jump backward from after the period")
    }
}
