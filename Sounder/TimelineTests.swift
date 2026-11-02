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

extension AppDelegate {
    func verifyGroupFragmentDragUI() throws {
        func check(_ value: Bool, _ message: String) throws {
            guard value else { throw SounderError.message(message) }; print("PASS: \(message)")
        }
        let original = editor.project
        var a = original.tracks[0].clips[0]; a.start = 1; a.duration = 1; a.offset = 0
        var b = a; b.id = UUID(); b.start = 3; b.duration = 0.5; b.offset = 0.25
        var c = a; c.id = UUID(); c.start = 5
        var fixed = a; fixed.id = UUID(); fixed.start = 7
        let tracks = [Track(name: "First", clips: [a, c]), Track(name: "Second", clips: [b]), Track(name: "Third"), Track(name: "Fourth", clips: [fixed])]
        let selected: Set<UUID> = [a.id, b.id, c.id]
        editor.project.tracks = tracks; editor.selection = selected; editor.zoom = 70; refresh()
        let scroll = timeline.enclosingScrollView!
        scroll.contentView.scroll(to: .zero); scroll.reflectScrolledClipView(scroll.contentView)
        func clip(_ id: UUID) -> Clip { editor.project.tracks.flatMap(\.clips).first { $0.id == id }! }
        func send(_ type: NSEvent.EventType, time: Double, row: Int, shift: Bool = false, command: Bool = false) {
            let point = NSPoint(x: timeline.header + time * editor.zoom, y: timeline.ruler + CGFloat(row) * timeline.rowHeight + 30)
            var flags: NSEvent.ModifierFlags = []; if shift { flags.insert(.shift) }; if command { flags.insert(.command) }
            let event = NSEvent.mouseEvent(with: type, location: timeline.convert(point, to: nil), modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            if type == .leftMouseDown { timeline.mouseDown(with: event) }
            else if type == .leftMouseDragged { timeline.mouseDragged(with: event) }
            else { timeline.mouseUp(with: event) }
        }
        let clickHistory = editor.undoStack.count
        send(.leftMouseDown, time: 3.25, row: 1)
        try check(editor.selection == selected, "Mouse-down preserves the group until a click can be distinguished from dragging")
        send(.leftMouseUp, time: 3.25, row: 1)
        try check(editor.selection == [b.id] && editor.undoStack.count == clickHistory, "A single click selects only the clicked member of a group without an Undo entry")
        send(.leftMouseDown, time: 1.5, row: 0, shift: true); send(.leftMouseUp, time: 1.5, row: 0, shift: true)
        try check(editor.selection == [a.id, b.id], "Shift-click still adds a fragment without collapsing the selection")
        send(.leftMouseDown, time: 3.25, row: 1, shift: true); send(.leftMouseUp, time: 3.25, row: 1, shift: true)
        try check(editor.selection == [a.id], "Shift-click still toggles a selected fragment off")
        editor.selection = selected
        send(.leftMouseDown, time: 1 + 1 / editor.zoom, row: 0); send(.leftMouseUp, time: 1 + 1 / editor.zoom, row: 0)
        try check(editor.selection == [a.id] && clip(a.id).duration == 1, "A plain click on a fragment edge also selects that fragment without resizing")
        editor.selection = selected
        let history = editor.undoStack.count
        send(.leftMouseDown, time: 3.25, row: 1); send(.leftMouseDragged, time: 4.25, row: 1)
        try check(clip(a.id).start == 2 && clip(b.id).start == 4 && clip(c.id).start == 6 && clip(fixed.id).start == 7 && editor.selection == selected, "Dragging any selected fragment moves the whole selection by the same time delta and leaves unselected audio fixed")
        send(.leftMouseUp, time: 4.25, row: 1)
        try check(clip(b.id).duration == 0.5 && clip(b.id).offset == 0.25 && editor.undoStack.count == history + 1, "Group dragging preserves source bounds and creates one Undo step")
        editor.undo(); try check(clip(a.id).start == 1 && clip(b.id).start == 3 && clip(c.id).start == 5, "One Undo restores every selected fragment")
        editor.redo(); try check(clip(a.id).start == 2 && clip(c.id).start == 6, "Redo restores the entire group move"); editor.undo()
        send(.leftMouseDown, time: 3.25, row: 1); send(.leftMouseDragged, time: -1.75, row: 1); send(.leftMouseUp, time: -1.75, row: 1)
        try check(clip(a.id).start == 0 && clip(b.id).start == 2 && clip(c.id).start == 4, "Timeline zero clamps the whole group without compressing its time spacing")
        editor.undo(); scroll.contentView.scroll(to: .zero); scroll.reflectScrolledClipView(scroll.contentView)
        let near = timeline.fragmentSnapTolerance / 2
        send(.leftMouseDown, time: 1.5, row: 0); send(.leftMouseDragged, time: 1.5 + near, row: 1)
        try check(clip(a.id).start == 1 && clip(b.id).start == 3 && clip(c.id).start == 5 && timeline.fragmentSnapTime == 1, "Cross-track snapping applies one shared time delta to the whole group")
        try check(timeline.displayedClips(for: tracks[0]).isEmpty && Set(timeline.displayedClips(for: tracks[1]).map(\.id)) == [a.id, c.id] && timeline.displayedClips(for: tracks[2]).first?.id == b.id, "All selected waveforms preview on their destination tracks while preserving their row spacing")
        send(.leftMouseUp, time: 1.5 + near, row: 1)
        try check(Set(editor.project.tracks[1].clips.map(\.id)) == [a.id, c.id] && editor.project.tracks[2].clips.first?.id == b.id && editor.selection == selected && timeline.fragmentSnapTime == nil, "Drop transfers every selected fragment and retains the selection")
        editor.undo(); try check(editor.project.tracks[0].clips.count == 2 && editor.project.tracks[1].clips.first?.id == b.id && editor.project.tracks[2].clips.isEmpty, "Undo restores both time positions and original tracks for the entire group")
        send(.leftMouseDown, time: 3.25, row: 1); send(.leftMouseDragged, time: 3.25, row: 3); send(.leftMouseUp, time: 3.25, row: 3)
        try check(Set(editor.project.tracks[2].clips.map(\.id)) == [a.id, c.id] && editor.project.tracks[3].clips.contains(where: { $0.id == b.id }) && editor.project.tracks[3].clips.contains(where: { $0.id == fixed.id }), "Group moves preserve row offsets at the bottom and retain destination audio")
        editor.undo()
        send(.leftMouseDown, time: 3.25, row: 1, shift: true); send(.leftMouseDragged, time: 4.25, row: 1, shift: true); send(.leftMouseUp, time: 4.25, row: 1, shift: true)
        try check(editor.selection == selected && clip(a.id).start == 2 && clip(b.id).start == 4, "Shift-drag retains the group while moving freely")
        editor.undo()
        editor.selection = selected
        let beforeCopy = editor.undoStack.count
        send(.leftMouseDown, time: 1.5, row: 0, command: true); send(.leftMouseDragged, time: 2.5, row: 1, command: true)
        try check(clip(a.id).start == 1 && clip(b.id).start == 3 && clip(c.id).start == 5 && editor.project.tracks.flatMap(\.clips).count == 4 && timeline.displayedClips(for: tracks[1]).count == 3, "Command-drag previews copies while every original remains untouched")
        send(.leftMouseUp, time: 2.5, row: 1, command: true)
        let duplicates = editor.project.tracks.flatMap(\.clips).filter { editor.selection.contains($0.id) }
        try check(duplicates.count == 3 && duplicates.map(\.start).sorted() == [2, 4, 6] && editor.selection.isDisjoint(with: selected) && editor.project.tracks.flatMap(\.clips).count == 7, "Command-drag commits fresh copies with the group's original time spacing")
        try check(editor.project.tracks[1].clips.filter { editor.selection.contains($0.id) }.count == 2 && editor.project.tracks[2].clips.first?.start == 4 && editor.undoStack.count == beforeCopy + 1, "Command-drag copies preserve relative track rows in one Undo step")
        editor.undo(); try check(editor.project.tracks.flatMap(\.clips).count == 4 && clip(a.id).start == 1, "Undo removes the copies without moving or removing originals")
        editor.redo(); try check(editor.project.tracks.flatMap(\.clips).count == 7, "Redo restores Command-drag copies")
        editor.undo()
        editor.project = original; editor.selectedTrack = original.tracks[0].id; editor.selection = []; editor.dirty = false; refresh()
    }
}

extension AppDelegate {
    func verifyFragmentMenuUI() throws {
        func check(_ value: Bool, _ message: String) throws {
            guard value else { throw SounderError.message(message) }; print("PASS: \(message)")
        }
        let original = editor.project
        var lower = original.tracks[0].clips[0]; lower.start = 1; lower.duration = 3; lower.order = 1
        var middle = lower; middle.id = UUID(); middle.order = 2
        var upper = lower; upper.id = UUID(); upper.order = 3
        var isolated = lower; isolated.id = UUID(); isolated.start = 7; isolated.duration = 1; isolated.order = 4
        editor.project = Project(tracks: [Track(name: "Layers", clips: [lower, middle, upper, isolated])], nextOrder: 5)
        editor.zoom = 70; editor.cursor = 6; refresh()
        timeline.enclosingScrollView?.contentView.scroll(to: .zero)
        func menu(time: Double, y: CGFloat) -> NSMenu? {
            let point = NSPoint(x: timeline.header + time * editor.zoom, y: y)
            let event = NSEvent.mouseEvent(with: .rightMouseDown, location: timeline.convert(point, to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            return timeline.menu(for: event)
        }
        func perform(_ item: NSMenuItem) { _ = NSApp.sendAction(item.action!, to: item.target, from: item) }
        func order() -> [UUID] { editor.project.tracks[0].clips.sorted { $0.order < $1.order }.map(\.id) }
        let bottom = menu(time: 2, y: timeline.ruler + 9)!
        try check(bottom.items.map(\.title) == ["Edit…", "Move up", "Move down", "Normalize…", "Mute", "Delete"] && bottom.items[1].isEnabled && !bottom.items[2].isEnabled && editor.selection == [lower.id] && editor.cursor == 6, "Right-clicking an exposed lower fragment opens its own menu without moving the playhead")
        let history = editor.undoStack.count
        perform(bottom.items[1])
        try check(order() == [middle.id, lower.id, upper.id, isolated.id] && editor.undoStack.count == history + 1, "Move up raises the context fragment exactly one overlapping level and leaves other relative ordering intact")
        perform(bottom.items[1])
        let top = menu(time: 2, y: timeline.ruler + 25)!
        try check(!top.items[1].isEnabled && top.items[2].isEnabled && editor.selection == [lower.id], "Top layer disables Move up and enables Move down")
        perform(top.items[2])
        try check(order() == [middle.id, lower.id, upper.id, isolated.id], "Move down lowers the selected fragment exactly one overlapping level")
        editor.undo(); try check(order() == [middle.id, upper.id, lower.id, isolated.id], "Undo restores the previous layer priority")
        editor.redo()
        let alone = menu(time: 7.5, y: timeline.ruler + 25)!
        try check(!alone.items[1].isEnabled && !alone.items[2].isEnabled, "Both layer actions are disabled for an isolated fragment")
        editor.selection.insert(upper.id)
        perform(alone.items[5])
        try check(editor.project.tracks[0].clips.count == 3 && !editor.project.tracks[0].clips.contains(where: { $0.id == isolated.id }) && editor.project.tracks[0].clips.contains(where: { $0.id == upper.id }), "Context Delete removes only its fragment even when another fragment is selected")
        editor.undo(); try check(editor.project.tracks[0].clips.count == 4, "Context fragment deletion can be undone")
        try check(menu(time: 6, y: timeline.ruler + 25) == nil, "Empty fragment space does not open the track menu")
        editor.selection = [lower.id, upper.id]
        let group = menu(time: 2, y: timeline.ruler + 25)!
        try check(editor.selection == [lower.id, upper.id] && !group.items[1].isEnabled && group.items[2].isEnabled, "Right-clicking a selected fragment preserves the group and enables layer actions for the whole selection")
        let groupHistory = editor.undoStack.count
        perform(group.items[2])
        try check(order() == [lower.id, upper.id, middle.id, isolated.id] && editor.selection == [lower.id, upper.id] && editor.undoStack.count == groupHistory + 1, "Group Move down moves selected layers together without swapping them and creates one Undo step")
        editor.undo(); editor.redo(); editor.undo()
        perform(group.items[5])
        try check(Set(editor.project.tracks[0].clips.map(\.id)) == [middle.id, isolated.id], "Context Delete removes every selected fragment and preserves unselected audio")
        editor.undo()
        var secondLower = lower; secondLower.id = UUID(); secondLower.order = 10
        var secondUpper = upper; secondUpper.id = UUID(); secondUpper.order = 11
        editor.project.tracks.append(Track(name: "Other layers", clips: [secondLower, secondUpper])); refresh()
        editor.selection = [lower.id, secondLower.id]
        let across = menu(time: 2, y: timeline.ruler + 11)!
        try check(editor.selection == [lower.id, secondLower.id] && across.items[1].isEnabled, "Context selection is retained across different tracks")
        let batchHistory = editor.undoStack.count
        perform(across.items[1])
        try check(order() == [middle.id, upper.id, lower.id, isolated.id] && editor.project.tracks[1].clips.sorted(by: { $0.order < $1.order }).last?.id == secondLower.id && editor.undoStack.count == batchHistory + 1, "One menu action changes layers on every selected track with one Undo step")
        editor.undo()
        perform(across.items[5])
        try check(!editor.project.tracks.flatMap(\.clips).contains(where: { $0.id == lower.id || $0.id == secondLower.id }) && editor.project.tracks[1].clips.first?.id == secondUpper.id, "Group context deletion applies across tracks")
        editor.undo()
        editor.selection = [lower.id, upper.id]
        _ = menu(time: 7.5, y: timeline.ruler + 25)
        try check(editor.selection == [isolated.id], "Right-clicking an unselected fragment selects only that fragment")
        editor.project = original; editor.selectedTrack = original.tracks[0].id; editor.selection = []; editor.dirty = false; refresh()
    }
}

extension AppDelegate {
    func verifyFragmentClipboardUI() throws {
        func check(_ value: Bool, _ message: String) throws {
            guard value else { throw SounderError.message(message) }; print("PASS: \(message)")
        }
        let original = editor.project
        let pasteboard = NSPasteboard.general
        let saved = (pasteboard.pasteboardItems ?? []).map { item in item.types.compactMap { type in item.data(forType: type).map { (type, $0) } } }
        defer {
            pasteboard.clearContents()
            let restored = saved.map { values -> NSPasteboardItem in
                let item = NSPasteboardItem(); for (type, data) in values { item.setData(data, forType: type) }; return item
            }
            pasteboard.writeObjects(restored)
        }
        window.makeKeyAndOrderFront(nil); window.makeFirstResponder(timeline)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        func key(_ text: String, code: UInt16) throws {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)!
            try check(NSApp.mainMenu!.performKeyEquivalent(with: event), "Command-\(text.uppercased()) is handled by the Edit menu")
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        try key("a", code: 0)
        let ids = Set(original.tracks.flatMap(\.clips).map(\.id))
        try check(editor.selection == ids, "Command-A selects every fragment")
        try key("c", code: 8)
        let data = pasteboard.data(forType: Editor.fragmentPasteboardType)!
        let payload = try JSONDecoder().decode(FragmentClipboard.self, from: data)
        try check(payload.items.count == ids.count, "Command-C writes the whole selected group to the system clipboard")
        editor.cursor = 12; editor.selectedTrack = original.tracks[0].id
        try key("v", code: 9)
        let copies = editor.project.tracks.flatMap(\.clips).filter { editor.selection.contains($0.id) }
        try check(copies.map(\.start).sorted() == [12, 13, 17] && editor.selection.isDisjoint(with: ids), "Command-V pastes at the cursor with the group's relative timing intact")
        editor.undo()
        timeline.renameTrack(original.tracks[0].id)
        guard let input = timeline.nameField.currentEditor() as? NSTextView else { throw SounderError.message("No inline name editor") }
        let text = input.string; let fragmentSelection = editor.selection
        try key("a", code: 0); try key("c", code: 8)
        try check(input.selectedRange().length == (text as NSString).length && pasteboard.string(forType: .string) == text && editor.selection == fragmentSelection, "Text editors retain native Command-A and Command-C behavior")
        input.insertText("Temporary", replacementRange: input.selectedRange()); input.selectAll(nil)
        try key("v", code: 9)
        try check(input.string == text && editor.project.tracks.flatMap(\.clips).count == ids.count, "Command-V pastes text in name editors without creating audio fragments")
        timeline.nameField.finish(commit: false); window.makeFirstResponder(timeline)
        editor.project = original; editor.selectedTrack = original.tracks[0].id; editor.selection = []; editor.dirty = false; refresh()
    }
}

extension AppDelegate {
    func verifyPhysicalShortcutsUI() throws {
        func check(_ value: Bool, _ message: String) throws {
            guard value else { throw SounderError.message(message) }; print("PASS: \(message)")
        }
        let original = editor.project
        window.makeKeyAndOrderFront(nil); window.makeFirstResponder(timeline)
        func event(_ text: String, code: UInt16, flags: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)!
        }
        let clip = original.tracks[0].clips[0]
        let count = original.tracks[0].clips.count
        editor.selection = [clip.id]; editor.cursor = clip.start + 0.5
        try check(handlePhysicalShortcut(event("s", code: 1)) && editor.project.tracks[0].clips.count == count + 1, "Physical S splits a selected fragment without modifiers")
        editor.undo(); editor.selection = [clip.id]
        try check(handlePhysicalShortcut(event("ы", code: 1)) && editor.project.tracks[0].clips.count == count + 1, "Russian ы on the same physical key performs Split")
        editor.undo()
        try check(!handlePhysicalShortcut(event("ы", code: 1, flags: [.option])) && !handlePhysicalShortcut(event("ы", code: 1, flags: [.control])), "Split does not consume modified S combinations")
        try check(handlePhysicalShortcut(event("ф", code: 0, flags: [.command])) && editor.selection == Set(editor.project.tracks.flatMap(\.clips).map(\.id)), "Command-A works on the Russian physical ф key")
        let splitItem = NSApp.mainMenu!.items.flatMap { $0.submenu?.items ?? [] }.first { $0.action == #selector(split) }!
        try check(splitItem.keyEquivalent == "s" && splitItem.keyEquivalentModifierMask.isEmpty, "The Fragments menu preserves the unmodified S shortcut for Split")
        timeline.renameTrack(original.tracks[0].id)
        guard let input = timeline.nameField.currentEditor() as? NSTextView else { throw SounderError.message("No inline field editor") }
        let before = editor.project.tracks[0].clips.count
        try check(!handlePhysicalShortcut(event("ы", code: 1)), "Physical letter shortcuts are inactive while editing a name")
        input.insertText("ы", replacementRange: input.selectedRange())
        try check(input.string.contains("ы") && editor.project.tracks[0].clips.count == before, "Russian ы remains ordinary text while editing")
        timeline.nameField.finish(commit: false); window.makeFirstResponder(timeline)
        editor.project = original; editor.selection = []; editor.selectedTrack = original.tracks[0].id; editor.dirty = false; refresh()
    }
}

extension AppDelegate {
    func verifyNormalizationUI() throws {
        let original = editor.project
        let clip = original.tracks[0].clips[0]
        editor.selection = [clip.id]; window.makeFirstResponder(timeline)
        var failure: String?
        func field(_ view: NSView) -> NSTextField? {
            if let input = view as? NSTextField, input.isEditable { return input }
            return view.subviews.lazy.compactMap { field($0) }.first
        }
        let timer = Timer(timeInterval: 0.1, repeats: false) { _ in
            guard let root = NSApp.modalWindow?.contentView, let input = field(root) else { failure = "No Normalize level field"; NSApp.stopModal(withCode: .alertSecondButtonReturn); return }
            if input.stringValue != "-1" { failure = "Normalize must initially default to -1 dBFS" }
            input.stringValue = "-3"; NSApp.stopModal(withCode: .alertFirstButtonReturn)
        }
        RunLoop.main.add(timer, forMode: .common)
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: "т", charactersIgnoringModifiers: "т", isARepeat: false, keyCode: 45)!
        guard handlePhysicalShortcut(event) else { throw SounderError.message("Physical N/т shortcut did not open Normalize") }
        if let failure { throw SounderError.message(failure) }
        let limit = Date().addingTimeInterval(10)
        while editor.isNormalizing && Date() < limit { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        guard !editor.isNormalizing, editor.project.normalizationLevel == -3, editor.project.tracks[0].clips[0].gain != 1 else { throw SounderError.message("Process failed to normalize the selected fragment") }
        let dialog = NormalizeDialog(level: editor.project.normalizationLevel)
        guard dialog.field.stringValue == "-3", dialog.alert.buttons[0].title == "Process" else { throw SounderError.message("Normalize did not remember the last processed level") }
        let cancel = Timer(timeInterval: 0.1, repeats: false) { _ in dialog.field.stringValue = "-6"; dialog.alert.buttons[1].performClick(nil) }
        RunLoop.main.add(cancel, forMode: .common)
        guard dialog.runModal() == nil, editor.project.normalizationLevel == -3 else { throw SounderError.message("Normalize Cancel changed the last chosen level") }
        editor.project = original; editor.selection = []; editor.selectedTrack = original.tracks[0].id; editor.dirty = false; refresh()
        print("PASS: physical N/т opens Normalize, Process changes gain, the next dialog recalls the target, and Cancel preserves it")
    }
}

extension AppDelegate {
    func verifyFragmentMuteUI() throws {
        let original = editor.project
        let a = original.tracks[0].clips[0], b = original.tracks[1].clips[0]
        editor.selection = [a.id, b.id]; refresh()
        func menu() throws -> NSMenu {
            let point = NSPoint(x: timeline.header + (a.start + 1) * editor.zoom, y: timeline.ruler + 30)
            let event = NSEvent.mouseEvent(with: .rightMouseDown, location: timeline.convert(point, to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            guard let menu = timeline.menu(for: event) else { throw SounderError.message("No fragment context menu") }; return menu
        }
        let history = editor.undoStack.count, messages = editor.notifications.messages.count
        let first = try menu()
        guard let mute = first.items.first(where: { $0.title == "Mute" }), editor.selection == [a.id, b.id] else { throw SounderError.message("Mute context action missing or reset the group") }
        _ = NSApp.sendAction(mute.action!, to: mute.target, from: mute)
        guard editor.fragmentsAreMuted([a.id, b.id]), editor.undoStack.count == history + 1, editor.notifications.messages.count == messages else { throw SounderError.message("Group mute did not apply silently as one edit") }
        let next = try menu()
        guard next.items.contains(where: { $0.title == "Unmute" }), fragmentMuteButton.toolTip == "Unmute selected fragments" else { throw SounderError.message("Mute action did not change to Unmute") }
        fragmentMuteButton.performClick(nil)
        guard !editor.fragmentsAreMuted([a.id, b.id]), editor.project.tracks.flatMap(\.clips).allSatisfy({ !$0.muted }) else { throw SounderError.message("Toolbar Unmute did not restore the selected fragments") }
        editor.undo()
        guard editor.fragmentsAreMuted([a.id, b.id]) else { throw SounderError.message("Undo did not restore mute") }
        editor.redo()
        editor.project = original; editor.selection = []; editor.selectedTrack = original.tracks[0].id; editor.dirty = false; refresh()
        print("PASS: context Mute applies to the group, becomes Unmute, toolbar toggles it, no toasts appear, and Undo/Redo works")
    }
}

extension AppDelegate {
    func verifyFragmentSettingsUI() throws {
        let original = editor.project, clip = editor.project.tracks[0].clips[0]
        window.makeFirstResponder(timeline)
        var opened = 0, failure: String?
        fragmentDialogAutomation = { dialog in
            opened += 1
            if dialog.volumeSlider.minValue != -48 || dialog.volumeSlider.maxValue > 24 || dialog.panSlider.minValue != -90 || dialog.panSlider.maxValue != 90 { failure = "Fragment settings slider limits are incorrect" }
            dialog.volume.stringValue = "24"; dialog.pan.stringValue = "-30"
            dialog.fadeIn.stringValue = "40"; dialog.fadeOut.stringValue = "60"
            dialog.inCurve.selectItem(at: FadeCurve.allCases.firstIndex(of: .exponential)!)
            dialog.outCurve.selectItem(at: FadeCurve.allCases.firstIndex(of: .logarithmic)!)
            dialog.alert.buttons[0].performClick(nil)
        }
        let point = NSPoint(x: timeline.header + (clip.start + 1) * editor.zoom, y: timeline.ruler + 30)
        func event(_ type: NSEvent.EventType, clicks: Int) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: timeline.convert(point, to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
        }
        timeline.mouseDown(with: event(.leftMouseDown, clicks: 1)); timeline.mouseUp(with: event(.leftMouseUp, clicks: 1))
        guard opened == 0 else { throw SounderError.message("A single click unexpectedly opened fragment settings") }
        let history = editor.undoStack.count
        timeline.mouseDown(with: event(.leftMouseDown, clicks: 2)); timeline.mouseUp(with: event(.leftMouseUp, clicks: 2))
        if let failure { throw SounderError.message(failure) }
        let edited = editor.project.tracks[0].clips[0]
        let raw = try editor.audio.load(edited.source), peak = FragmentNormalization.peak(for: edited, data: raw, sampleRate: editor.audio.sampleRate)
        guard opened == 1, edited.volumeDB <= (try FragmentSettings.maximumVolume(clip: clip, peak: peak)), edited.pan == -30, edited.fadeInMS == 40, edited.fadeOutMS == 60, edited.fadeInCurve == .exponential, edited.fadeOutCurve == .logarithmic, editor.undoStack.count == history + 1 else { throw SounderError.message("Double-click settings did not save bounded volume, pan and fades") }
        fragmentDialogAutomation = { dialog in
            opened += 1
            if dialog.pan.stringValue != "-30" || dialog.fadeIn.stringValue != "40" { failure = "Edit did not restore saved fragment settings" }
            dialog.pan.stringValue = "90"; dialog.alert.buttons[1].performClick(nil)
        }
        let menu = timeline.menu(for: event(.rightMouseDown, clicks: 1))!
        guard let edit = menu.items.first(where: { $0.title == "Edit…" }) else { throw SounderError.message("No Edit in fragment context menu") }
        _ = NSApp.sendAction(edit.action!, to: edit.target, from: edit)
        if let failure { throw SounderError.message(failure) }
        guard opened == 2, FragmentSettings(editor.project.tracks[0].clips[0]) == FragmentSettings(edited), editor.undoStack.count == history + 1 else { throw SounderError.message("Context Edit cancellation changed settings or history") }
        fragmentDialogAutomation = nil; editor.undo()
        guard editor.project.tracks[0].clips[0].volumeDB == clip.volumeDB else { throw SounderError.message("Fragment settings Undo failed") }
        editor.project = original; editor.selection = []; editor.selectedTrack = original.tracks[0].id; editor.dirty = false; refresh()
        print("PASS: single click selects, double click and context Edit open settings, volume is peak-limited, Save persists all fields and Cancel/Undo work")
    }
}

extension AppDelegate {
    func verifyTempoSnappingUI() throws {
        func check(_ value: Bool, _ message: String) throws {
            guard value else { throw SounderError.message(message) }; print("PASS: \(message)")
        }
        let original = editor.project
        var a = original.tracks[0].clips[0]; a.start = 0.5; a.offset = 0.5; a.duration = 4
        var b = a; b.id = UUID(); b.start = 3; b.offset = 0; b.duration = 0.5
        editor.project = Project(tracks: [Track(name: "Bars", clips: [a]), Track(name: "Group", clips: [b])], tempo: 120, tempoMode: true)
        editor.selection = [a.id, b.id]; editor.zoom = 70; refresh()
        let scroll = timeline.enclosingScrollView!
        scroll.contentView.scroll(to: .zero); scroll.reflectScrolledClipView(scroll.contentView)
        func send(_ type: NSEvent.EventType, _ time: Double, shift: Bool = false, command: Bool = false) {
            let point = NSPoint(x: timeline.header + time * editor.zoom, y: timeline.ruler + 30)
            var flags: NSEvent.ModifierFlags = []; if shift { flags.insert(.shift) }; if command { flags.insert(.command) }
            if type == .flagsChanged {
                let event = NSEvent.keyEvent(with: type, location: timeline.convert(point, to: nil), modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 56)!
                timeline.flagsChanged(with: event); return
            }
            let event = NSEvent.mouseEvent(with: type, location: timeline.convert(point, to: nil), modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            if type == .leftMouseDown { timeline.mouseDown(with: event) }
            else if type == .leftMouseDragged { timeline.mouseDragged(with: event) }
            else { timeline.mouseUp(with: event) }
        }
        func clip(_ id: UUID) -> Clip { editor.project.tracks.flatMap(\.clips).first { $0.id == id }! }
        send(.leftMouseDown, 1.5); send(.leftMouseDragged, 2.7)
        try check(clip(a.id).start == 1.5 && clip(b.id).start == 4 && timeline.fragmentSnapTime == 1.5, "Tempo group movement changes all start positions by one-beat steps from the original offset")
        send(.flagsChanged, 2.7, shift: true)
        try check(abs(clip(a.id).start - 1.7) < 1e-9 && abs(clip(b.id).start - 4.2) < 1e-9, "Pressing Shift mid-drag immediately restores free group movement")
        send(.flagsChanged, 2.7)
        try check(clip(a.id).start == 1.5, "Releasing Shift immediately restores beat steps")
        send(.leftMouseUp, 2.7); editor.undo()
        send(.leftMouseDown, 1.5, shift: true); send(.leftMouseDragged, 2.2, shift: true); send(.leftMouseUp, 2.2, shift: true)
        try check(abs(clip(a.id).start - 1.2) < 1e-9 && editor.selection == [a.id, b.id], "Holding Shift before the drag bypasses beats without deselecting the group")
        editor.undo()
        send(.leftMouseDown, 1.5); send(.leftMouseDragged, 0.2); send(.leftMouseUp, 0.2)
        try check(clip(a.id).start == 0 && clip(b.id).start == 2.5, "Whole-beat movement clamps the group without fractional shifts before timeline zero")
        editor.undo(); editor.selection = [a.id]
        let history = editor.undoStack.count
        send(.leftMouseDown, 0.5 + 1 / editor.zoom); send(.leftMouseUp, 0.5 + 1 / editor.zoom)
        try check(clip(a.id).start == 0.5 && editor.undoStack.count == history, "Clicking an off-grid edge does not resize or snap it")
        send(.leftMouseDown, 0.5 + 1 / editor.zoom); send(.leftMouseDragged, 1.2 + 1 / editor.zoom)
        try check(timeline.resizedFragment?.start == 1 && timeline.resizedFragment?.end == 4.5 && timeline.resizedFragment?.offset == 1, "Left resize aligns to an absolute beat boundary while retaining the right edge and source alignment")
        send(.flagsChanged, 1.2, shift: true)
        try check(abs((timeline.resizedFragment?.start ?? 0) - 1.2) < 1e-9, "Shift switches an active edge resize to free timing")
        send(.flagsChanged, 1.2)
        try check(timeline.resizedFragment?.start == 1, "Releasing Shift snaps the edge back to a beat")
        send(.leftMouseUp, 1.2 + 1 / editor.zoom); editor.undo()
        send(.leftMouseDown, 4.5 - 1 / editor.zoom); send(.leftMouseDragged, 5.2 - 1 / editor.zoom); send(.leftMouseUp, 5.2 - 1 / editor.zoom)
        try check(clip(a.id).end == 5 && clip(a.id).start == 0.5, "Right resize aligns to a beat without moving the left edge")
        editor.undo()
        send(.leftMouseDown, 4.5 - 1 / editor.zoom, shift: true); send(.leftMouseDragged, 5.2 - 1 / editor.zoom, shift: true); send(.leftMouseUp, 5.2 - 1 / editor.zoom, shift: true)
        try check(abs(clip(a.id).end - 5.2) < 1e-9, "Shift-held right resize remains free from the start of the gesture")
        editor.undo()
        send(.leftMouseDown, 4.5 - 1 / editor.zoom); send(.leftMouseDragged, 12); send(.leftMouseUp, 12)
        try check(clip(a.id).end == 8 && clip(a.id).offset + clip(a.id).duration == 8, "Beat resizing cannot extend beyond the original recording")
        editor.undo(); scroll.contentView.scroll(to: .zero); scroll.reflectScrolledClipView(scroll.contentView)
        send(.leftMouseDown, 1.5, command: true); send(.leftMouseDragged, 2.7, command: true); send(.leftMouseUp, 2.7, command: true)
        let copies = editor.project.tracks.flatMap(\.clips).filter { editor.selection.contains($0.id) }
        try check(copies.count == 1 && copies[0].start == 1.5 && clip(a.id).start == 0.5, "Command-drag copies follow the same Tempo beat steps")
        editor.undo(); editor.project.tempoMode = false; editor.selection = [a.id]
        send(.leftMouseDown, 1.5); send(.leftMouseDragged, 2.2); send(.leftMouseUp, 2.2)
        try check(abs(clip(a.id).start - 1.2) < 1e-9, "Time mode keeps the ordinary free movement behavior")
        editor.undo(); editor.project = original; editor.selection = []; editor.selectedTrack = original.tracks[0].id; editor.dirty = false; refresh()
    }
}

extension AppDelegate {
    func verifyTrackSoloUI() throws {
        let original = editor.project
        defer { editor.stop(); editor.project = original; editor.dirty = false; refresh() }
        let root = Track(name: "Solo root", clips: Array(original.tracks[0].clips.prefix(1)))
        let child = Track(name: "Solo child", parent: root.id)
        let grandchild = Track(name: "Solo grandchild", parent: child.id)
        editor.project = Project(tracks: [root, child, grandchild]); refresh()
        for row in 0..<3 {
            let solo = timeline.trackSoloRect(row: row, depth: row)
            guard solo.minX > timeline.trackMuteRect(row: row, depth: row).maxX,
                  solo.maxX < timeline.trackFXRect(row: row, depth: row).minX,
                  timeline.trackFXRect(row: row, depth: row).maxX < timeline.fragmentLeft else { throw SounderError.message("Solo/Mute/FX overlap in nested headers") }
            let point = timeline.convert(NSPoint(x: solo.midX, y: solo.midY), to: nil)
            let event = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            timeline.mouseDown(with: event)
            guard editor.project.tracks[row].solo else { throw SounderError.message("Solo button did not activate") }
        }
        guard editor.project.tracks.allSatisfy(\.solo) else { throw SounderError.message("Solo cleared another track") }
        editor.seek(to: 2); editor.playPause()
        guard let playback = editor.player else { throw SounderError.message("Solo UI playback did not start") }
        let messages = editor.notifications.messages.count
        for row in 0..<3 {
            let rect = timeline.trackSoloRect(row: row, depth: row)
            let event = NSEvent.mouseEvent(with: .leftMouseDown, location: timeline.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            timeline.mouseDown(with: event)
            guard !editor.project.tracks[row].solo, editor.isPlaying, editor.player === playback else { throw SounderError.message("Solo must toggle during playback without replacing the stream") }
        }
        guard editor.notifications.messages.count == messages else { throw SounderError.message("Solo toggles must remain silent") }
        print("PASS: Live Solo buttons toggle without replacing playback or emitting notifications")
        print("PASS: Solo buttons sit between MUTE and FX at every nesting depth and independently activate multiple tracks")
    }
}

extension AppDelegate {
    func verifyFragmentFadesUI() throws {
        func check(_ value: Bool, _ message: String) throws {
            guard value else { throw SounderError.message(message) }; print("PASS: \(message)")
        }
        let original = editor.project
        defer { _ = timeline.cancelFragmentResize(); editor.project = original; editor.selection = []; editor.dirty = false; refresh() }
        var a = original.tracks[0].clips[0]; a.start = 1; a.offset = 0.5; a.duration = 4
        a.fadeInMS = 500; a.fadeOutMS = 750; a.fadeInCurve = .exponential; a.fadeOutCurve = .smooth
        var b = a; b.id = UUID(); b.start = 6
        editor.project = Project(tracks: [Track(name: "Fade controls", clips: [a, b])])
        editor.selection = [a.id, b.id]; editor.cursor = 2.25; editor.zoom = 90; refresh()
        let scroll = timeline.enclosingScrollView!
        scroll.contentView.scroll(to: .zero); scroll.reflectScrolledClipView(scroll.contentView)
        func clip() -> Clip { editor.project.tracks[0].clips.first { $0.id == a.id }! }
        func send(_ type: NSEvent.EventType, _ point: NSPoint) {
            let event = NSEvent.mouseEvent(with: type, location: timeline.convert(point, to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            if type == .leftMouseDown { timeline.mouseDown(with: event) }
            else if type == .leftMouseDragged { timeline.mouseDragged(with: event) }
            else { timeline.mouseUp(with: event) }
        }
        func handle(_ left: Bool) -> NSPoint {
            let rect = timeline.fragmentFadeHandleRects(clip(), in: timeline.clipRect(clip(), row: 0, layer: 0))[left ? 0 : 1]
            return NSPoint(x: rect.midX, y: rect.midY)
        }
        let originalRect = timeline.clipRect(a, row: 0, layer: 0)
        var shortFade = a; shortFade.fadeInMS = 10; shortFade.fadeOutMS = 10
        let shortAreas = timeline.fragmentFadeRects(shortFade, in: originalRect)
        try check(abs(shortAreas[0].width - 0.9) < 1e-9 && abs(shortAreas[1].width - 0.9) < 1e-9, "10 ms fade curves occupy their true subpixel timeline duration without a visual minimum")
        shortFade.fadeInMS = 0
        try check(timeline.fragmentFadeRects(shortFade, in: originalRect)[0].width == 0, "A disabled fade has no visible curve width while its corner remains editable")
        let areas = timeline.fragmentFadeRects(a, in: originalRect), handles = timeline.fragmentFadeHandleRects(a, in: originalRect)
        try check(abs(handles[0].midX - areas[0].maxX) < 1e-9 && abs(handles[1].midX - areas[1].minX) < 1e-9, "Fade drag targets follow the current upper curve endpoints instead of the fragment corners")
        var meeting = a; meeting.fadeInMS = 2000; meeting.fadeOutMS = 2000
        let meetingHandles = timeline.fragmentFadeHandleRects(meeting, in: originalRect)
        try check(meetingHandles[0].maxX <= meetingHandles[1].minX && meetingHandles.allSatisfy { $0.width > 0 }, "Both fades remain separately draggable when their upper endpoints meet")
        for isLeft in [true, false] {
            let target = handle(isLeft), outside = NSPoint(x: target.x, y: originalRect.minY - 3)
            let end = NSPoint(x: outside.x + (isLeft ? 1 : -1) * editor.zoom * 0.25, y: outside.y)
            try check(!originalRect.contains(outside) && timeline.fragmentFadeHandleRects(clip(), in: originalRect)[isLeft ? 0 : 1].contains(outside), "Fade target extends above the fragment without changing its visual curve")
            send(.leftMouseDown, outside); send(.leftMouseDragged, end)
            try check(timeline.fadedFragment != nil, "Dragging can start outside the fragment's upper border for either fade")
            send(.leftMouseUp, end)
            try check(isLeft ? clip().fadeInMS == 750 : clip().fadeOutMS == 1000, "An exterior fade drag commits the correct duration")
            editor.undo()
        }
        let history = editor.undoStack.count, cursor = editor.cursor
        let left = handle(true), leftEnd = NSPoint(x: left.x + editor.zoom, y: left.y)
        send(.leftMouseDown, left); send(.leftMouseUp, left)
        try check(editor.undoStack.count == history && clip().fadeInMS == 500, "Fade handle click does not change selection, duration or Undo history")
        send(.leftMouseDown, left); send(.leftMouseDragged, leftEnd)
        try check(timeline.fadedFragment?.fadeInMS == 1500 && clip().fadeInMS == 500 && editor.cursor == cursor, "Fade-in upper endpoint previews duration live without seeking or altering source bounds")
        send(.leftMouseUp, leftEnd)
        try check(clip().fadeInMS == 1500 && clip().fadeOutMS == 750 && clip().start == a.start && clip().offset == a.offset && clip().duration == a.duration && editor.selection == [a.id, b.id] && editor.undoStack.count == history + 1, "Fade drag changes only its edge and commits once while preserving the group")
        editor.undo(); try check(clip().fadeInMS == 500, "One Undo restores the original fade")
        editor.redo(); try check(clip().fadeInMS == 1500, "Redo restores the edited fade")
        editor.undo()
        let right = handle(false), rightEnd = NSPoint(x: right.x - editor.zoom * 0.5, y: right.y)
        send(.leftMouseDown, right); send(.leftMouseDragged, rightEnd); send(.leftMouseUp, rightEnd)
        try check(clip().fadeOutMS == 1250 && clip().fadeInMS == 500, "Fade-out upper endpoint changes duration in the mirrored horizontal direction")
        editor.undo()
        send(.leftMouseDown, left); send(.leftMouseDragged, NSPoint(x: left.x - editor.zoom, y: left.y)); send(.leftMouseUp, NSPoint(x: left.x - editor.zoom, y: left.y))
        try check(clip().fadeInMS == 0, "Dragging beyond the corner clamps fade duration at zero")
        editor.undo()
        send(.leftMouseDown, right); send(.leftMouseDragged, NSPoint(x: right.x - editor.zoom * 8, y: right.y))
        try check(timeline.fadedFragment?.fadeOutMS == 4000, "Fade duration cannot exceed the fragment length")
        let beforeCancel = editor.undoStack.count
        try check(timeline.cancelFragmentResize() && clip().fadeOutMS == 750 && editor.undoStack.count == beforeCancel, "Escape/Stop cancels the fade preview without changing project data")
        let rect = timeline.clipRect(clip(), row: 0, layer: 0)
        let area = timeline.fragmentFadeRects(clip(), in: rect)[0]
        let point = NSPoint(x: area.midX, y: area.midY)
        let event = NSEvent.mouseEvent(with: .rightMouseDown, location: timeline.convert(point, to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        guard let menu = timeline.menu(for: event) else { throw SounderError.message("Fade curve menu did not open") }
        try check(menu.items.count == 4 && menu.items.allSatisfy { $0.image != nil && $0.title.isEmpty && $0.state == .off }, "Right-click fade area shows only graphical icons without titles or selection checkmarks")
        menu.performActionForItem(at: 3)
        try check(clip().fadeInCurve == .logarithmic && clip().fadeOutCurve == .smooth && editor.selection == [a.id, b.id], "Curve menu changes only the clicked fragment edge and preserves selection")
        editor.undo(); try check(clip().fadeInCurve == .exponential, "Curve type selection supports Undo")
        if let index = CommandLine.arguments.firstIndex(of: "--snapshot"), index + 1 < CommandLine.arguments.count {
            refresh(); window.contentView!.layoutSubtreeIfNeeded()
            let content = window.contentView!
            if let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                content.cacheDisplay(in: content.bounds, to: bitmap)
                let path = URL(fileURLWithPath: CommandLine.arguments[index + 1]).deletingPathExtension().appendingPathExtension("fades.png")
                try bitmap.representation(using: .png, properties: [:])?.write(to: path)
            }
        }
    }
}

extension AppDelegate {
    func verifyFragmentsSystemMenuUI() throws {
        func check(_ value: Bool, _ message: String) throws {
            guard value else { throw SounderError.message(message) }; print("PASS: \(message)")
        }
        let selection = editor.selection
        defer { editor.selection = selection; editor.requestingMic = false; refresh() }
        window.makeKeyAndOrderFront(nil); window.makeFirstResponder(timeline)
        let roots = NSApp.mainMenu!.items
        guard let index = roots.firstIndex(where: { $0.title == "Edit" }), index + 1 < roots.count,
              roots[index + 1].title == "Fragments", let fragments = roots[index + 1].submenu else { throw SounderError.message("Fragments menu must immediately follow Edit") }
        let actions = [#selector(split), #selector(trim), #selector(join), #selector(normalize), #selector(muteFragments), #selector(deleteClips)]
        try check(fragments.items.compactMap(\.action) == actions && roots[index].submenu!.items.allSatisfy { !actions.contains($0.action!) }, "Fragment actions live exclusively in the system Fragments menu immediately after Edit")
        editor.selection = []; fragments.update()
        try check(fragments.items.allSatisfy { !$0.isEnabled }, "All system fragment actions disable when no fragment is selected")
        editor.selection = [UUID()]; fragments.update()
        try check(fragments.items.allSatisfy { !$0.isEnabled }, "Stale selection IDs cannot enable fragment actions")
        editor.selection = [editor.project.tracks[0].clips[0].id]; fragments.update()
        try check(fragments.items.allSatisfy(\.isEnabled), "Selecting a real fragment enables the Fragments menu actions")
        editor.requestingMic = true; fragments.update()
        try check(fragments.items.allSatisfy { !$0.isEnabled }, "Busy transport keeps every fragment action disabled")
        editor.requestingMic = false
        timeline.renameTrack(editor.project.tracks[0].id); fragments.update()
        try check(fragments.items.allSatisfy { !$0.isEnabled }, "Editing a name disables fragment actions and preserves text shortcuts")
        timeline.nameField.finish(commit: false); window.makeFirstResponder(timeline)
        let split = fragments.items.first { $0.action == #selector(split) }!, normalize = fragments.items.first { $0.action == #selector(normalize) }!
        try check(split.keyEquivalent == "s" && split.keyEquivalentModifierMask.isEmpty && normalize.keyEquivalent == "n" && normalize.keyEquivalentModifierMask.isEmpty, "Split and Normalize retain their physical unmodified shortcuts in Fragments")
    }
}

extension AppDelegate {
    func verifyButtonHoverUI() throws {
        func check(_ value: Bool, _ message: String) throws {
            guard value else { throw SounderError.message(message) }; print("PASS: \(message)")
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil); window.makeFirstResponder(timeline); refresh()
        let deadline = Date().addingTimeInterval(2)
        while !window.isKeyWindow && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        try check(window.isKeyWindow, "Main window is active before testing hover feedback")
        guard let icon = window.toolbar?.items.first(where: { $0.itemIdentifier.rawValue == "open" })?.view as? PointerButton else { throw SounderError.message("Open button missing") }
        func event(_ type: NSEvent.EventType, point: NSPoint, view: NSView) -> NSEvent {
            let location = view.convert(point, to: nil)
            if type == .mouseEntered || type == .mouseExited {
                return NSEvent.enterExitEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!
            }
            return NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!
        }
        func pixels(_ view: NSView) -> Data {
            let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
            view.cacheDisplay(in: view.bounds, to: bitmap)
            return bitmap.representation(using: .png, properties: [:])!
        }
        let center = NSPoint(x: icon.bounds.midX, y: icon.bounds.midY)
        let entered = event(.mouseEntered, point: center, view: icon), exited = event(.mouseExited, point: center, view: icon)
        icon.mouseExited(with: exited); let normal = pixels(icon)
        icon.mouseEntered(with: entered); let hover = pixels(icon)
        try check(icon.interactionCursor == .arrow && icon.isHovering && hover != normal, "Icon buttons use an arrow and gain a visible lighter hover background (arrow: \(icon.interactionCursor == .arrow), hover: \(icon.isHovering), key: \(window.isKeyWindow), changed: \(hover != normal))")
        icon.mouseExited(with: exited)
        try check(!icon.isHovering && pixels(icon) == normal, "Moving off an icon removes its hover background")
        icon.isEnabled = false; icon.mouseEntered(with: entered)
        try check(!icon.isHovering, "Disabled buttons never highlight on hover")
        icon.isEnabled = true
        if let export = exportButton as? PointerButton {
            let old = export.isEnabled; export.isEnabled = true
            let point = NSPoint(x: export.bounds.midX, y: export.bounds.midY)
            let exit = event(.mouseExited, point: point, view: export), enter = event(.mouseEntered, point: point, view: export)
            export.mouseExited(with: exit); let before = pixels(export)
            export.mouseEntered(with: enter)
            try check(export.interactionCursor == .arrow && pixels(export) != before, "Text buttons retain an arrow and gain rounded hover feedback")
            export.mouseExited(with: exit); export.isEnabled = old
        }
        let buttonRect = timeline.trackMuteRect(row: 0, depth: timeline.rows[0].1)
        let point = NSPoint(x: buttonRect.midX, y: buttonRect.midY)
        timeline.mouseExited(with: event(.mouseExited, point: point, view: timeline)); let baseline = pixels(timeline)
        timeline.mouseMoved(with: event(.mouseMoved, point: point, view: timeline))
        try check(pixels(timeline) != baseline, "Drawn track MUTE/SOLO/FX controls also provide hover feedback")
        timeline.mouseExited(with: event(.mouseExited, point: point, view: timeline))
        try check((bpmButton as? PointerButton)?.interactionCursor == .iBeam, "Editable BPM retains its text cursor")
        refresh()
    }
}

extension AppDelegate {
    func verifyNumericInputUI() throws {
        let clip = editor.project.tracks[0].clips[0]
        let fragment = FragmentSettingsDialog(clip: clip, store: editor.audio, peak: 0.5)
        let normalize = NormalizeDialog(level: -1), tempo = TempoDialog(bpm: 120)
        let export = ExportOptionsController(settings: editor.project.defaultExportSettings)
        let fields: [(NSTextField, String)] = [
            (fragment.volume, "-6.25"), (fragment.pan, "+30,5"),
            (fragment.fadeIn, "12.5"), (fragment.fadeOut, "0,75"),
            (normalize.field, "-1,5"), (tempo.field, "125.5"),
            (export.metadataFields[6], "2026"), (export.metadataFields[7], "3/12"), (export.metadataFields[8], "1/2")
        ]
        let alert = CompactSettingsAlert(); alert.messageText = "Numeric input"
        let form = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: fields.count * 32))
        for (index, pair) in fields.enumerated() {
            pair.0.removeFromSuperview(); pair.0.frame = NSRect(x: 0, y: index * 32, width: 280, height: 24); form.addSubview(pair.0)
        }
        alert.accessoryView = form; alert.addButton(withTitle: "Close")
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        var failure: String?
        let timer = Timer(timeInterval: 0.1, repeats: false) { _ in
            do {
                func check(_ condition: Bool, _ message: String) throws {
                    guard condition else { throw SounderError.message(message) }
                }
                for (field, valid) in fields {
                    alert.window.makeFirstResponder(field)
                    guard let input = field.currentEditor() as? NSTextView else { throw SounderError.message("Numeric field did not start editing") }
                    input.selectAll(nil); input.insertText(valid, replacementRange: input.selectedRange())
                    try check(input.string == valid, "A numeric field rejected a valid decimal, sign or track number: \(valid)")
                    input.setSelectedRange(NSRange(location: 1, length: 0))
                    input.insertText("я", replacementRange: input.selectedRange())
                    try check(input.string == valid, "A numeric field accepted a letter inserted in the middle")
                    pasteboard.clearContents(); pasteboard.setString("12abc🎵", forType: .string)
                    input.selectAll(nil); _ = input.readSelection(from: pasteboard, type: .string)
                    try check(input.string == valid, "Pasting invalid text changed the numeric value")
                    pasteboard.clearContents(); pasteboard.setString(valid, forType: .string)
                    input.selectAll(nil); _ = input.readSelection(from: pasteboard, type: .string)
                    try check(input.string == valid, "Pasting a valid number failed")
                    input.selectAll(nil); input.deleteBackward(nil)
                    try check(input.string.isEmpty, "Numeric fields must allow clearing and replacing the value")
                    input.insertText(valid, replacementRange: input.selectedRange())
                }
                alert.window.makeFirstResponder(fragment.fadeIn)
                let input = fragment.fadeIn.currentEditor() as! NSTextView
                for invalid in ["-10", "+10", "1.2.3", "1,2.3", "NaN", "1e3", "1 000", "١٢"] {
                    input.selectAll(nil); input.insertText(invalid, replacementRange: input.selectedRange())
                    try check(input.string == "12.5", "Fade accepted an invalid unsigned decimal: \(invalid)")
                }
                alert.window.makeFirstResponder(fragment.volume)
                let signed = fragment.volume.currentEditor() as! NSTextView
                signed.selectAll(nil); signed.insertText("-", replacementRange: signed.selectedRange())
                try check(signed.string == "-", "Typing a leading minus was blocked")
                signed.insertText("3,5", replacementRange: signed.selectedRange())
                try check(signed.string == "-3,5", "Typing a negative decimal step by step failed")
                alert.window.makeFirstResponder(fragment.fadeOut)
                fragment.fadeOut.stringValue = String(format: "%g", 0.0000001)
                try check(!fragment.fadeOut.stringValue.contains("e"), "Small fade duration was displayed using blocked exponent syntax")
            } catch { failure = error.localizedDescription }
            NSApp.stopModal(withCode: .alertFirstButtonReturn)
        }
        RunLoop.main.add(timer, forMode: .modalPanel)
        _ = alert.runModal()
        if let failure { throw SounderError.message(failure) }
        print("PASS: Actual numeric fields reject letters, malformed numbers and invalid pasted text; decimals, signs, editing, clearing and valid pastes work")
    }
}

extension AppDelegate {
    func verifyTrackMixUI() throws {
        let original = editor.project, zoom = editor.zoom
        defer {
            editor.stop(); editor.project = original; editor.zoom = zoom; editor.dirty = false
            editor.undoStack = []; editor.redoStack = []; editor.reconcile(); refresh()
        }
        for index in 1...8 { editor.project.tracks.append(Track(name: "Mixer \(index)")) }
        refresh()
        let first = timeline.rows[0].0.id
        guard let controls = timeline.mixerControls[first] else { throw SounderError.message("Track sliders were not installed") }
        for (row, item) in timeline.rows.enumerated() {
            guard let view = timeline.mixerControls[item.0.id], !view.isHidden else { continue }
            let volume = view.volume.convert(view.volume.bounds, to: timeline), pan = view.pan.convert(view.pan.bounds, to: timeline)
            guard volume.minY >= timeline.trackFXRect(row: row, depth: item.1).maxY,
                  volume.maxX < pan.minX, pan.maxX < timeline.fragmentLeft,
                  abs(pan.height - (timeline.rowHeight - 8)) < 0.01, view.pan.isVertical,
                  timeline.trackNameRect(row: row, depth: item.1).maxX < pan.minX else { throw SounderError.message("Track sliders overlap buttons, leave the sidebar or have the wrong orientation") }
        }
        // Measure the rendered native thumb: modern AppKit's legacy cell tick
        // rectangles do not necessarily describe its vertical layer geometry.
        func thumbY() throws -> Double {
            let view = controls.pan
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw SounderError.message("Cannot capture Pan thumb") }
            view.effectiveAppearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: bitmap) }
            var sum = 0.0, count = 0.0
            for y in 0..<bitmap.pixelsHigh { for x in 0..<bitmap.pixelsWide {
                if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.alphaComponent > 0.8,
                   color.redComponent > 0.65, color.greenComponent > 0.65, color.blueComponent > 0.65 {
                    sum += Double(y); count += 1
                }
            } }
            guard count > 0 else { throw SounderError.message("Pan thumb did not render") }
            return sum / count
        }
        var thumbPositions: [Double] = []
        for (value, expected) in [(90.0, -90.0), (-90.0, 90.0)] {
            controls.pan.doubleValue = value
            _ = controls.pan.sendAction(controls.pan.action, to: controls.pan.target)
            thumbPositions.append(try thumbY())
            let track = editor.project.tracks[0]
            guard track.pan == expected,
                  track.outputGain(channel: expected < 0 ? 0 : 1, channels: 2) > 0.99,
                  track.outputGain(channel: expected < 0 ? 1 : 0, channels: 2) < 1e-12 else { throw SounderError.message("Pan top must route left and bottom must route right") }
        }
        guard thumbPositions[0] < thumbPositions[1] else { throw SounderError.message("Pan left thumb must appear above right thumb: \(thumbPositions)") }
        editor.zoom = 160; refresh()
        let clipView = timeline.enclosingScrollView!.contentView
        clipView.scroll(to: NSPoint(x: 300, y: 0)); timeline.enclosingScrollView!.reflectScrolledClipView(clipView)
        refresh()
        let pinned = controls.pan.convert(controls.pan.bounds, to: window.contentView)
        guard pinned.minX >= 0, pinned.maxX <= timeline.header else { throw SounderError.message("Mixer controls scroll horizontally with fragments") }
        let history = editor.undoStack.count
        controls.volume.doubleValue = -6
        _ = controls.volume.sendAction(controls.volume.action, to: controls.volume.target)
        controls.pan.doubleValue = -45
        _ = controls.pan.sendAction(controls.pan.action, to: controls.pan.target)
        guard editor.project.tracks[0].volumeDB == -6, editor.project.tracks[0].pan == 45, editor.undoStack.count == history + 2 else { throw SounderError.message("Native slider actions did not update track values with Undo") }
        editor.cursor = 0; editor.playPause()
        guard let live = editor.player else { throw SounderError.message("Mixer playback did not start") }
        let engine = live.engine, node = live.node, graph = live.snapshotGraph
        controls.pan.doubleValue = 30
        _ = controls.pan.sendAction(controls.pan.action, to: controls.pan.target)
        guard editor.isPlaying, editor.player === live, live.engine === engine, live.node === node, live.snapshotGraph === graph,
              editor.project.tracks[0].pan == -30, controls.volume.isEnabled else { throw SounderError.message("Live track fader changed or stopped the playback engine") }
        editor.stop()
        clipView.scroll(to: .zero); refresh()
        // Several continuous slider actions within the same tracking gesture
        // must create one history entry, independently of device event timing.
        let slider = controls.volume, beforeDrag = editor.undoStack.count
        slider.withTrackingGesture {
            for value in [-12.0, -18, -24] {
                slider.doubleValue = value
                _ = slider.sendAction(slider.action, to: slider.target)
            }
        }
        guard editor.undoStack.count == beforeDrag + 1, editor.project.tracks[0].volumeDB == -24 else { throw SounderError.message("One slider drag must create exactly one Undo entry") }
        for control in [controls.pan, controls.volume] {
            let before = editor.undoStack.count
            let event = NSEvent.mouseEvent(with: .leftMouseDown, location: control.convert(NSPoint(x: control.bounds.midX, y: control.bounds.midY), to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 2, pressure: 1)!
            control.mouseDown(with: event)
            let value = control === controls.pan ? editor.project.tracks[0].pan : editor.project.tracks[0].volumeDB
            guard value == 0, control.doubleValue == 0, editor.undoStack.count == before + 1 else { throw SounderError.message("Double-click did not reset a track slider with one Undo entry") }
            control.mouseDown(with: event)
            guard editor.undoStack.count == before + 1 else { throw SounderError.message("Resetting a default slider added an empty Undo action") }
        }
        print("PASS: Full-height Pan routes left at the top and right at the bottom; double-click resets both track sliders without empty Undo actions")
        let contentY = timeline.ruler + timeline.rowHeight * 4 + 40
        clipView.scroll(to: NSPoint(x: 0, y: contentY)); timeline.enclosingScrollView!.reflectScrolledClipView(clipView)
        refresh()
        for view in timeline.mixerControls.values where !view.isHidden {
            guard view.frame.minY >= timeline.pinnedRulerRect.maxY else { throw SounderError.message("A track slider covers the pinned ruler") }
        }
        clipView.scroll(to: .zero); refresh()
        print("PASS: Native track sliders fit under MUTE/SOLO/FX, Pan is vertical, controls remain pinned and clipped, live changes retain transport, and dragging is one Undo")
    }
}
