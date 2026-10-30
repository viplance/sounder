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

extension AppDelegate {
    func verifyTrackDragUI() throws {
        func check(_ value: Bool, _ message: String) throws {
            guard value else { throw SounderError.message(message) }; print("PASS: \(message)")
        }
        let original = editor.project
        let root = original.tracks[0], child = original.tracks[1], other = original.tracks[2]
        func point(_ row: Int, fraction: CGFloat) -> NSPoint {
            NSPoint(x: timeline.pinnedHeaderX + 165, y: timeline.ruler + (CGFloat(row) + fraction) * timeline.rowHeight)
        }
        func send(_ type: NSEvent.EventType, _ point: NSPoint) {
            let event = NSEvent.mouseEvent(with: type, location: timeline.convert(point, to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            if type == .leftMouseDown { timeline.mouseDown(with: event) }
            else if type == .leftMouseDragged { timeline.mouseDragged(with: event) }
            else { timeline.mouseUp(with: event) }
        }
        refresh()
        let top = point(0, fraction: 0.1)
        send(.leftMouseDown, point(2, fraction: 0.4)); send(.leftMouseDragged, top)
        try check(timeline.rows.map { $0.0.id } == [other.id, root.id, child.id] && editor.project.tracks.map { $0.id } == original.tracks.map { $0.id }, "Dragging above a track previews its new order before mouse-up without editing the project")
        send(.leftMouseDragged, top)
        try check(timeline.rows.map { $0.0.id } == [other.id, root.id, child.id], "Repeated drag events at the same position keep a stable preview")
        send(.leftMouseUp, top)
        try check(editor.project.tracks.map { $0.id } == [other.id, root.id, child.id], "Mouse-up commits exactly the previewed track order")
        editor.undo()
        try check(editor.project.tracks.map { $0.id } == original.tracks.map { $0.id }, "One Undo restores the full track arrangement")
        editor.redo(); try check(editor.project.tracks.first?.id == other.id, "Redo restores the drag arrangement")
        editor.undo()
        let bottom = point(2, fraction: 0.9)
        send(.leftMouseDown, point(0, fraction: 0.4)); send(.leftMouseDragged, bottom)
        try check(timeline.rows.map { $0.0.id } == [other.id, root.id, child.id] && timeline.rows[2].1 == 1, "Dragging downward moves a parent and its complete subtree together in the preview")
        send(.leftMouseUp, bottom); editor.undo()
        let middle = point(2, fraction: 0.5)
        send(.leftMouseDown, point(0, fraction: 0.4)); send(.leftMouseDragged, middle)
        try check(timeline.rows.map { $0.0.id } == [other.id, root.id, child.id] && timeline.rows.map { $0.1 } == [0, 1, 2] && editor.project.tracks[0].parent == nil, "Dragging into a row previews nesting and updates indentation for the entire subtree")
        send(.leftMouseUp, middle)
        try check(editor.project.tracks.first(where: { $0.id == root.id })?.parent == other.id && editor.project.tracks.first(where: { $0.id == child.id })?.parent == root.id, "Nesting commits the preview while preserving existing child relationships")
        editor.undo()
        send(.leftMouseDown, point(0, fraction: 0.4)); send(.leftMouseDragged, point(1, fraction: 0.5))
        try check(timeline.trackPreview == nil && timeline.rows.map { $0.0.id } == original.tracks.map { $0.id }, "A parent cannot be dragged into its own descendant")
        send(.leftMouseUp, point(1, fraction: 0.5))
        send(.leftMouseDown, point(2, fraction: 0.4)); send(.leftMouseDragged, top)
        stop()
        try check(timeline.trackDrag == nil && timeline.trackPreview == nil && editor.project.tracks.map { $0.id } == original.tracks.map { $0.id }, "Escape/Stop cancels the preview without changing the project")
        let blank = point(3, fraction: 0.3)
        send(.leftMouseDown, point(1, fraction: 0.4)); send(.leftMouseDragged, blank)
        try check(timeline.rows.last?.0.id == child.id && timeline.rows.last?.1 == 0, "Dragging into empty space previews moving a nested track to the root at the bottom")
        send(.leftMouseUp, blank)
        try check(editor.project.tracks.last?.id == child.id && editor.project.tracks.last?.parent == nil, "Moving a nested track to the bottom commits the shown root position")
        editor.undo()
        let grandchild = Track(name: "Grandchild", parent: child.id)
        let otherChild = Track(name: "Other child", parent: other.id)
        let fixture = [root, child, grandchild, other, otherChild]
        editor.project.tracks = fixture; refresh()
        let initialUndoCount = editor.undoStack.count
        send(.leftMouseDown, point(3, fraction: 0.4)); send(.leftMouseDragged, point(1, fraction: 0.5))
        try check(timeline.trackPreview == nil && timeline.rows.map { $0.0.id } == fixture.map { $0.id }, "Live drag rejects a subtree whose child would reach depth three")
        send(.leftMouseUp, point(1, fraction: 0.5))
        try check(editor.undoStack.count == initialUndoCount && editor.project.tracks[3].parent == nil, "Invalid subtree drop leaves routing and Undo history unchanged")
        send(.leftMouseDown, point(4, fraction: 0.4)); send(.leftMouseDragged, point(2, fraction: 0.5))
        try check(timeline.trackPreview == nil, "A leaf cannot preview nesting under a second-level child")
        send(.leftMouseUp, point(2, fraction: 0.5))
        send(.leftMouseDown, point(4, fraction: 0.4)); send(.leftMouseDragged, point(1, fraction: 0.5))
        try check(timeline.rows.last(where: { $0.0.id == otherChild.id })?.1 == 2, "Dragging a leaf to the second nested level still previews live")
        send(.leftMouseUp, point(1, fraction: 0.5))
        try check(editor.project.tracks.first(where: { $0.id == otherChild.id })?.parent == child.id, "A valid second-level drop commits successfully")
        editor.undo(); editor.project = original; editor.dirty = false; refresh()
    }
}

extension AppDelegate {
    func verifyMarqueeUI() throws {
        func check(_ condition: Bool, _ message: String) throws {
            guard condition else { throw SounderError.message(message) }; print("PASS: \(message)")
        }
        func point(_ time: Double, _ row: CGFloat, _ offset: CGFloat) -> NSPoint {
            NSPoint(x: timeline.header + time * editor.zoom, y: timeline.ruler + row * timeline.rowHeight + offset)
        }
        func send(_ type: NSEvent.EventType, _ p: NSPoint, shift: Bool = false) {
            let event = NSEvent.mouseEvent(with: type, location: timeline.convert(p, to: nil), modifierFlags: shift ? [.shift] : [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            if type == .leftMouseDown { timeline.mouseDown(with: event) }
            else if type == .leftMouseDragged { timeline.mouseDragged(with: event) }
            else { timeline.mouseUp(with: event) }
        }
        let all = Set(editor.project.tracks.flatMap { $0.clips.map { $0.id } })
        let first = editor.project.tracks[0].clips[0].id, child = editor.project.tracks[1].clips[0].id
        let initialUndo = editor.undoStack.count
        editor.seek(to: 4); editor.selection = []; refresh()
        let start = point(0.5, 0, 1), end = point(6, 2, 20)
        send(.leftMouseDown, start); send(.leftMouseDragged, end)
        try check(timeline.marqueeRect != nil && editor.selection == all && editor.cursor == 4, "Marquee selects intersecting fragments across tracks live without moving the playhead")
        send(.leftMouseUp, end)
        try check(timeline.marqueeRect == nil && editor.selection == all && editor.undoStack.count == initialUndo, "Mouse-up removes the rectangle while retaining selection without an Undo entry")
        editor.selection = []; send(.leftMouseDown, end); send(.leftMouseDragged, start); send(.leftMouseUp, start)
        try check(editor.selection == all, "Rectangle selection works when dragging upward and leftward")
        editor.selection = [child]
        let oneEnd = point(3, 0, timeline.rowHeight - 1)
        send(.leftMouseDown, start, shift: true); send(.leftMouseDragged, oneEnd, shift: true)
        try check(editor.selection == Set([child, first]), "Shift-marquee adds intersecting fragments to the original selection")
        send(.leftMouseUp, oneEnd, shift: true)
        editor.selection = [child]; editor.range = 1...2; refresh()
        send(.leftMouseDown, start); send(.leftMouseDragged, oneEnd); stop()
        try check(editor.selection == [child] && editor.range == 1...2 && timeline.marqueeAnchor == nil && editor.cursor == 4, "Escape/Stop restores selection and range without seeking")
        editor.range = nil; editor.selection = []
        let horizontal = point(0.5, 0, 30), horizontalEnd = point(3, 0, 30)
        send(.leftMouseDown, horizontal); send(.leftMouseDragged, horizontalEnd); send(.leftMouseUp, horizontalEnd)
        try check(editor.selection == [first], "A thin horizontal marquee still selects crossed fragments")
        let below = point(12, 3, 30)
        send(.leftMouseDown, below); send(.leftMouseDragged, start); send(.leftMouseUp, start)
        try check(editor.selection == all && editor.cursor == 4, "Marquee can start below all tracks and reach the fragment rows")
        editor.seek(to: 1); editor.playPause()
        guard let player = editor.player else { throw SounderError.message("Marquee playback test did not start") }
        send(.leftMouseDown, start); send(.leftMouseDragged, end); send(.leftMouseUp, end)
        try check(editor.isPlaying && editor.player === player && editor.selection == all, "Marquee selection leaves active playback running without replacing its stream")
        editor.stop()
        let click = point(11, 2, 25)
        send(.leftMouseDown, click); send(.leftMouseUp, click)
        try check(editor.cursor == 11 && editor.selection.isEmpty, "A plain background click still seeks and clears selection")
        let clipPoint = point(2, 0, 30), movedPoint = point(3, 0, 30)
        send(.leftMouseDown, clipPoint); send(.leftMouseDragged, movedPoint); send(.leftMouseUp, movedPoint)
        try check(editor.project.tracks[0].clips[0].start == 2 && timeline.marqueeAnchor == nil, "Dragging a fragment still moves it instead of starting a marquee")
        editor.undo(); editor.selection = []; editor.seek(to: 5.8); editor.dirty = false; refresh()
    }
}
