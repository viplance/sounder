import AppKit

extension AppDelegate {
    func verifyPinnedRulerUI() throws {
        func check(_ condition: Bool, _ message: String) throws {
            guard condition else { throw SounderError.message(message) }; print("PASS: \(message)")
        }
        func event(_ type: NSEvent.EventType, point: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: timeline.convert(point, to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        func send(_ type: NSEvent.EventType, time: Double) {
            let point = NSPoint(x: timeline.header + time * editor.zoom, y: timeline.pinnedRulerRect.midY)
            let e = event(type, point: point)
            if type == .leftMouseDown { timeline.mouseDown(with: e) }
            else if type == .leftMouseDragged { timeline.mouseDragged(with: e) }
            else { timeline.mouseUp(with: e) }
        }
        guard let scroll = timeline.enclosingScrollView, let source = editor.project.tracks.first?.clips.first else { throw SounderError.message("Timeline fixture is unavailable") }
        for index in 3..<20 {
            var clip = source; clip.id = UUID(); clip.start = 1 + Double(index) * 0.1; clip.name = "Take \(index + 1)"
            editor.project.tracks.append(Track(name: "Track \(index + 1)", clips: [clip]))
        }
        editor.zoom = 140; refresh(); window.contentView?.layoutSubtreeIfNeeded()
        scroll.contentView.scroll(to: .zero); scroll.reflectScrolledClipView(scroll.contentView)
        let headerBefore = timeline.convert(timeline.trackMuteRect(row: 6, depth: 0).origin, to: window.contentView)
        let before = timeline.convert(NSPoint(x: 0, y: timeline.pinnedRulerRect.minY), to: window.contentView)
        let clipBefore = timeline.convert(NSPoint(x: 0, y: timeline.clipRect(source, row: 0, layer: 0).minY), to: window.contentView)
        let hiddenMute = timeline.trackMuteRect(row: 4, depth: 0)
        let scrollY = floor(hiddenMute.midY - timeline.ruler / 2)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: scrollY)); scroll.reflectScrolledClipView(scroll.contentView)
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        let after = timeline.convert(NSPoint(x: 0, y: timeline.pinnedRulerRect.minY), to: window.contentView)
        let clipAfter = timeline.convert(NSPoint(x: 0, y: timeline.clipRect(source, row: 0, layer: 0).minY), to: window.contentView)
        print("Scroll geometry: ruler \(before.y) → \(after.y), fragment \(clipBefore.y) → \(clipAfter.y), bounds \(scroll.contentView.bounds), visible \(timeline.visibleRect)")
        try check(abs(before.y - after.y) < 0.01 && abs(abs(clipBefore.y - clipAfter.y) - scrollY) < 0.01, "Vertical scrolling moves fragments while the ruler stays at the same window position")
        let mutedBefore = editor.project.tracks[4].muted
        let covered = NSPoint(x: hiddenMute.midX, y: timeline.pinnedRulerRect.midY)
        timeline.mouseDown(with: event(.leftMouseDown, point: covered)); timeline.mouseUp(with: event(.leftMouseUp, point: covered))
        try check(editor.project.tracks[4].muted == mutedBefore && timeline.menu(for: event(.rightMouseDown, point: covered)) == nil, "Pinned ruler intercepts clicks instead of activating covered track controls")
        send(.leftMouseDown, time: 2.5); send(.leftMouseUp, time: 2.5)
        try check(editor.cursor == 2.5, "Clicking the pinned ruler after scrolling seeks to the selected time")
        send(.leftMouseDown, time: 1); send(.leftMouseDragged, time: 3); send(.leftMouseUp, time: 3)
        try check(editor.range == 1...3 && editor.cursor == 2.5 && abs(scroll.contentView.bounds.minY - scrollY) < 0.01, "Pinned range selection preserves the cursor and does not vertically autoscroll")
        send(.leftMouseDown, time: 3); send(.leftMouseDragged, time: 4); send(.leftMouseUp, time: 4)
        try check(editor.range == 1...4 && timeline.rangeHandleRects().allSatisfy { abs($0.minY - timeline.visibleRect.minY) < 0.01 }, "Range edges remain draggable on the pinned ruler")
        scroll.contentView.scroll(to: NSPoint(x: 160, y: scrollY)); scroll.reflectScrolledClipView(scroll.contentView)
        send(.leftMouseDown, time: 5); send(.leftMouseUp, time: 5)
        let rulerX = timeline.convert(NSPoint(x: timeline.header + source.start * editor.zoom, y: timeline.pinnedRulerRect.midY), to: window.contentView).x
        let fragmentX = timeline.convert(NSPoint(x: timeline.clipRect(source, row: 0, layer: 0).minX, y: 0), to: window.contentView).x
        try check(editor.cursor == 5 && abs(rulerX - fragmentX) < 0.01, "Horizontal scrolling keeps ruler times aligned with fragment positions")
        // Keep the sidebar fixed even after scrolling farther than its full width.
        scroll.contentView.scroll(to: NSPoint(x: 640, y: scrollY)); scroll.reflectScrolledClipView(scroll.contentView)
        let muteRect = timeline.trackMuteRect(row: 6, depth: 0)
        let headerAfter = timeline.convert(muteRect.origin, to: window.contentView)
        try check(abs(headerBefore.x - headerAfter.x) < 0.01 && abs(abs(headerBefore.y - headerAfter.y) - scrollY) < 0.01, "Track controls stay fixed horizontally and follow tracks vertically")
        let oldCursor = editor.cursor, wasMuted = editor.project.tracks[6].muted
        let mutePoint = NSPoint(x: muteRect.midX, y: muteRect.midY)
        timeline.mouseDown(with: event(.leftMouseDown, point: mutePoint)); timeline.mouseUp(with: event(.leftMouseUp, point: mutePoint))
        try check(editor.project.tracks[6].muted != wasMuted && editor.cursor == oldCursor && timeline.dragClip == nil, "Pinned MUTE control toggles the correct track without seeking or selecting a covered fragment")
        let name = timeline.trackNameHitRect(row: 6, depth: 0)
        let namePoint = NSPoint(x: name.midX, y: name.midY)
        timeline.mouseDown(with: event(.leftMouseDown, point: namePoint))
        try check(timeline.pendingTrackRename == editor.project.tracks[6].id && timeline.trackDrag == editor.project.tracks[6].id, "Pinned track name retains its rename and nesting hit targets")
        timeline.pendingTrackRename = nil; timeline.trackDrag = nil
        let blankPoint = NSPoint(x: timeline.pinnedHeaderX + 30, y: timeline.ruler + CGFloat(timeline.rows.count) * timeline.rowHeight + 20)
        try check(timeline.menu(for: event(.rightMouseDown, point: blankPoint))?.items.first?.title == "Add track", "Blank pinned sidebar still offers Add track after horizontal scrolling")
        let cursorBeforeArrow = editor.cursor
        timeline.movePlayhead(direction: 1)
        try check(abs(editor.cursor - cursorBeforeArrow - (timeline.visibleRect.width - timeline.header) / editor.zoom * 0.01) < 0.00001, "Arrow seeking measures only the visible fragment area beside the pinned sidebar")
        editor.cursor = 10; timeline.centerOnPlayhead()
        let cursorX = timeline.header + editor.cursor * editor.zoom
        try check(abs(cursorX - timeline.visibleFragmentRect.midX) < 1, "Zoom centering accounts for the pinned sidebar after horizontal scrolling")
        editor.toggleTempoMode()
        let ticks = timeline.rulerTicks(in: timeline.visibleRect)
        try check(editor.project.tempoMode && ticks.contains { $0.isBar && !$0.label.isEmpty }, "Pinned ruler supports the 4/4 tempo grid after vertical and horizontal scrolling")
        editor.dirty = false; refresh()
    }
}
