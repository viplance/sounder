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

extension AppDelegate {
    func verifyFragmentResizeUI() throws {
        func check(_ value: Bool, _ message: String) throws {
            guard value else { throw SounderError.message(message) }; print("PASS: \(message)")
        }
        let original = editor.project
        var clip = original.tracks[0].clips[0]
        clip.start = 2; clip.offset = 1; clip.duration = 3
        let track = Track(name: "Resize", clips: [clip])
        editor.project.tracks = [track]; editor.zoom = 70; editor.cursor = 6; editor.selection = []
        refresh(); window.contentView?.layoutSubtreeIfNeeded()
        let scroll = timeline.enclosingScrollView!
        scroll.contentView.scroll(to: .zero); scroll.reflectScrolledClipView(scroll.contentView)
        func current() -> Clip { editor.project.tracks[0].clips[0] }
        func send(_ type: NSEvent.EventType, x: CGFloat, y: CGFloat? = nil) {
            let point = NSPoint(x: x, y: y ?? timeline.clipRect(clip, row: 0, layer: 0).midY)
            let event = NSEvent.mouseEvent(with: type, location: timeline.convert(point, to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            if type == .leftMouseDown { timeline.mouseDown(with: event) }
            else if type == .leftMouseDragged { timeline.mouseDragged(with: event) }
            else { timeline.mouseUp(with: event) }
        }
        let rect = timeline.clipRect(clip, row: 0, layer: 0)
        let history = editor.undoStack.count
        let left = rect.minX + 1
        send(.leftMouseDown, x: left); send(.leftMouseDragged, x: left + 70)
        try check(timeline.resizedFragment?.start == 3 && timeline.resizedFragment?.offset == 2 && timeline.resizedFragment?.duration == 2 && current().duration == 3 && editor.cursor == 6, "Left-edge drag previews trimmed audio live without changing the project or playhead")
        send(.leftMouseUp, x: left + 70)
        try check(current().start == 3 && current().offset == 2 && current().end == 5 && editor.undoStack.count == history + 1, "Resizing commits once and keeps the opposite edge fixed")
        editor.undo(); try check(current().start == 2 && current().offset == 1 && current().duration == 3, "One Undo restores original fragment bounds")
        editor.redo(); try check(current().duration == 2, "Redo restores resized fragment bounds"); editor.undo()
        let right = rect.maxX - 1
        send(.leftMouseDown, x: right); send(.leftMouseDragged, x: right + 700)
        try check(abs((timeline.resizedFragment?.duration ?? 0) - 7) < 1e-9, "Right-edge preview cannot exceed the eight-second recording with a one-second source offset")
        send(.leftMouseUp, x: right + 700)
        try check(current().offset + current().duration == 8 && current().start == 2, "Right-edge drop remains bounded by the recording")
        editor.undo(); scroll.contentView.scroll(to: .zero); scroll.reflectScrolledClipView(scroll.contentView)
        send(.leftMouseDown, x: right); send(.leftMouseDragged, x: left - 100)
        try check(abs((timeline.resizedFragment?.duration ?? 0) - 0.010) < 1e-9, "Crossing the left edge clamps the live fragment to 10 ms")
        send(.leftMouseUp, x: left - 100); editor.undo()
        send(.leftMouseDown, x: left); send(.leftMouseDragged, x: right + 100)
        try check(abs((timeline.resizedFragment?.duration ?? 0) - 0.010) < 1e-9, "Crossing the right edge also clamps the live fragment to 10 ms")
        let beforeCancel = editor.undoStack.count
        stop()
        try check(timeline.resizedFragment == nil && current().duration == 3 && editor.undoStack.count == beforeCancel, "Escape/Stop cancels edge resizing without changing audio or Undo history")
        send(.leftMouseDown, x: left); send(.leftMouseUp, x: left)
        try check(editor.undoStack.count == beforeCancel, "An edge click without resizing does not create an Undo entry")
        send(.leftMouseDown, x: rect.midX); send(.leftMouseDragged, x: rect.midX + 35); send(.leftMouseUp, x: rect.midX + 35)
        try check(current().start == 2.5 && current().offset == 1 && current().duration == 3, "Dragging the fragment body still moves it without resizing")
        editor.undo(); editor.project = original; editor.selectedTrack = original.tracks[0].id; editor.dirty = false; refresh()
    }
}

extension AppDelegate {
    func verifyFragmentSnapUI() throws {
        func check(_ value: Bool, _ message: String) throws {
            guard value else { throw SounderError.message(message) }; print("PASS: \(message)")
        }
        let original = editor.project
        var moving = original.tracks[0].clips[0]; moving.start = 2; moving.offset = 1; moving.duration = 1
        var target = moving; target.id = UUID(); target.start = 4; target.duration = 2
        let sourceTrack = Track(name: "Source", clips: [moving])
        let targetTrack = Track(name: "Target", clips: [target])
        let emptyTrack = Track(name: "Empty")
        editor.project.tracks = [sourceTrack, targetTrack, emptyTrack]; editor.zoom = 70; refresh()
        let scroll = timeline.enclosingScrollView!
        scroll.contentView.scroll(to: .zero); scroll.reflectScrolledClipView(scroll.contentView)
        func send(_ type: NSEvent.EventType, proposed: Double, row: Int) {
            let point = NSPoint(x: timeline.header + (proposed + moving.duration / 2) * editor.zoom,
                                y: timeline.ruler + CGFloat(row) * timeline.rowHeight + 30)
            let event = NSEvent.mouseEvent(with: type, location: timeline.convert(point, to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            if type == .leftMouseDown { timeline.mouseDown(with: event) }
            else if type == .leftMouseDragged { timeline.mouseDragged(with: event) }
            else { timeline.mouseUp(with: event) }
        }
        func liveStart() -> Double { editor.project.tracks[0].clips[0].start }
        let tolerance = timeline.fragmentSnapTolerance
        try check(abs(tolerance - (timeline.visibleRect.width - timeline.header) / editor.zoom * 0.01) < 1e-9, "Snap tolerance uses one percent of visible time excluding the pinned sidebar")
        let history = editor.undoStack.count
        send(.leftMouseDown, proposed: 2, row: 0)
        send(.leftMouseDragged, proposed: 2 + tolerance / 2, row: 1)
        timeline.displayIfNeeded()
        try check(liveStart() == 2 && timeline.fragmentSnapTime == 2 && timeline.displayedClips(for: targetTrack).contains(where: { $0.id == moving.id }), "Cross-track drag preserves near-vertical alignment and displays a live guide with the fragment")
        send(.leftMouseDragged, proposed: 2 + tolerance * 1.1, row: 1)
        try check(abs(liveStart() - (2 + tolerance * 1.1)) < 1e-9 && timeline.fragmentSnapTime == nil, "Moving outside the threshold releases the fragment and removes the guide")
        send(.leftMouseDragged, proposed: 4 - tolerance / 2, row: 1)
        try check(liveStart() == 4 && timeline.fragmentSnapTime == 4, "Moving start snaps to another fragment start")
        send(.leftMouseDragged, proposed: 5 + tolerance / 2, row: 1)
        try check(liveStart() == 5 && timeline.fragmentSnapTime == 6, "Moving end snaps to another fragment end")
        send(.leftMouseDragged, proposed: 3 + tolerance / 2, row: 2)
        try check(liveStart() == 3 && timeline.fragmentSnapTime == 4, "Moving end can snap to a start boundary on a different track from the drop target")
        send(.leftMouseUp, proposed: 3 + tolerance / 2, row: 2)
        let dropped = editor.project.tracks[2].clips.first!
        try check(dropped.start == 3 && dropped.offset == 1 && dropped.duration == 1 && timeline.fragmentSnapTime == nil && editor.undoStack.count == history + 1, "Drop keeps the exact aligned time and original audio bounds, clears the guide and adds one Undo step")
        editor.undo()
        try check(editor.project.tracks[0].clips[0].start == 2 && editor.project.tracks[2].clips.isEmpty, "One Undo restores the original time and track")
        editor.zoom = 140; refresh()
        try check(abs(timeline.fragmentSnapTolerance - tolerance / 2) < 1e-9, "Zoom updates snapping tolerance to the visible time span")
        send(.leftMouseDown, proposed: 2, row: 0)
        send(.leftMouseDragged, proposed: 2 + timeline.fragmentSnapTolerance / 2, row: 0)
        try check(timeline.fragmentSnapTime == nil && liveStart() > 2, "Same-track body dragging retains free horizontal positioning")
        send(.leftMouseUp, proposed: 2 + timeline.fragmentSnapTolerance / 2, row: 0)
        editor.undo(); editor.project = original; editor.zoom = 70; editor.selectedTrack = original.tracks[0].id; editor.dirty = false; refresh()
    }
}
