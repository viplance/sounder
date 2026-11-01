import AppKit

let background = NSColor(calibratedRed: 0.055, green: 0.065, blue: 0.085, alpha: 1)
let panelColor = NSColor(calibratedRed: 0.085, green: 0.10, blue: 0.13, alpha: 1)
let accent = NSColor(calibratedRed: 0.40, green: 0.88, blue: 0.75, alpha: 1)
let trackColors: [NSColor] = [accent, .init(calibratedRed: 0.57, green: 0.62, blue: 0.98, alpha: 1), .init(calibratedRed: 0.94, green: 0.67, blue: 0.41, alpha: 1), .init(calibratedRed: 0.82, green: 0.53, blue: 0.81, alpha: 1)]
func label(_ text: String, _ rect: NSRect, size: CGFloat = 12, color: NSColor = .labelColor, weight: NSFont.Weight = .regular, alignment: NSTextAlignment = .left) {
    let style = NSMutableParagraphStyle(); style.lineBreakMode = .byTruncatingTail; style.alignment = alignment
    (text as NSString).draw(in: rect, withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: style])
}
func fill(_ rect: NSRect, _ color: NSColor, radius: CGFloat = 0) { color.setFill(); NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill() }
func line(_ from: NSPoint, _ to: NSPoint, _ color: NSColor, width: CGFloat = 1) { color.setStroke(); let p = NSBezierPath(); p.lineWidth = width; p.move(to: from); p.line(to: to); p.stroke() }

// Shared inline editor: only committed, nonempty names reach the model.
final class InlineNameField: NSTextField, NSTextFieldDelegate {
    private var commitName: ((String) -> Void)?
    private var ended: (() -> Void)?
    private(set) var isRenaming = false
    var textChanged: (() -> Void)?
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        delegate = self; isHidden = true; isBezeled = false; drawsBackground = false
        backgroundColor = panelColor; textColor = .labelColor; focusRingType = .none
        usesSingleLineMode = true; lineBreakMode = .byClipping
        (cell as? NSTextFieldCell)?.isScrollable = true
    }
    required init?(coder: NSCoder) { fatalError() }
    func begin(_ name: String, commit: @escaping (String) -> Void, end: @escaping () -> Void) {
        guard !isRenaming else { return }
        stringValue = String(name.prefix(NameRules.maximumLength)); commitName = commit; ended = end; isRenaming = true; isHidden = false
        textChanged?()
        window?.makeFirstResponder(self)
        if let input = currentEditor() as? NSTextView {
            input.drawsBackground = false
            input.setSelectedRange(NSRange(location: (input.string as NSString).length, length: 0))
        }
        revealCaret()
    }
    @discardableResult func finish(commit: Bool, requireValid: Bool = false) -> Bool {
        guard isRenaming else { return true }
        let name = NameRules.normalized(stringValue)
        if commit && requireValid && name.isEmpty { NSSound.beep(); return false }
        let save = commitName, end = ended
        isRenaming = false; commitName = nil; ended = nil
        // Clear the field editor before hiding the field; end-editing may reenter.
        window?.endEditing(for: self)
        isHidden = true; end?()
        if commit && !name.isEmpty { save?(name) }
        return true
    }
    func controlTextDidChange(_ notification: Notification) {
        if let input = currentEditor() as? NSTextView, !input.hasMarkedText(), input.string.count > NameRules.maximumLength {
            let selection = input.selectedRange()
            let limited = String(input.string.prefix(NameRules.maximumLength))
            input.string = limited
            let length = (limited as NSString).length
            input.setSelectedRange(NSRange(location: min(selection.location, length), length: min(selection.length, max(0, length - min(selection.location, length)))))
            stringValue = limited
        }
        textChanged?()
        revealCaret()
    }
    func revealCaret() {
        guard isRenaming else { return }
        // The toolbar and the track editor may resize after a keystroke. Scroll after
        // that layout, so AppKit keeps the insertion point inside the final field width.
        window?.contentView?.superview?.layoutSubtreeIfNeeded()
        if let input = currentEditor() as? NSTextView { input.scrollRangeToVisible(input.selectedRange()) }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isRenaming, let input = self.currentEditor() as? NSTextView else { return }
            input.scrollRangeToVisible(input.selectedRange())
        }
    }
    func controlTextDidEndEditing(_ notification: Notification) { finish(commit: true) }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            let parent = superview
            if finish(commit: true, requireValid: true) { window?.makeFirstResponder(parent) }
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            let parent = superview; finish(commit: false); window?.makeFirstResponder(parent); return true
        }
        return false
    }
}

final class Timeline: NSView {
    private var fragmentWaveforms: [UUID: (FragmentWaveformKey, [[Float]])] = [:]
    private var waveformJobs: [UUID: (FragmentWaveformKey, Progress)] = [:]
    private let waveformQueue = DispatchQueue(label: "Sounder.fragment-waveforms", qos: .userInitiated)
    private func processedWaveform(_ clip: Clip, audio: AudioData) -> [[Float]]? {
        let rate = editor.audio.sampleRate, channels = editor.project.audioFormat.channels
        let key = FragmentWaveformKey(clip, rate: rate, channels: channels)
        if let cached = fragmentWaveforms[clip.id], cached.0 == key { return cached.1 }
        if waveformJobs[clip.id]?.0 != key {
            waveformJobs[clip.id]?.1.cancel()
            let cancellation = Progress(totalUnitCount: 1)
            waveformJobs[clip.id] = (key, cancellation)
            waveformQueue.async { [weak self] in
                guard let peaks = FragmentWaveform.peaks(audio, clip: clip, rate: rate, channels: channels, cancelled: { cancellation.isCancelled }) else { return }
                DispatchQueue.main.async { [weak self] in
                    guard let self, !cancellation.isCancelled, self.waveformJobs[clip.id]?.0 == key else { return }
                    self.fragmentWaveforms[clip.id] = (key, peaks)
                    self.waveformJobs.removeValue(forKey: clip.id)
                    self.needsDisplay = true
                }
            }
        }
        return nil
    }
    let editor: Editor
    let header: CGFloat = 220
    let rowHeight: CGFloat = 116 / 1.5
    let ruler: CGFloat = 42
    var rows: [(Track, Int)] = []
    var dragClip: UUID?
    private var pendingFragmentClick: UUID?
    private var pendingShiftFragmentClick: UUID?
    private var lastFragmentDragPoint: NSPoint?
    private var didResizeFragment = false
    var dragStart = NSPoint.zero
    var originalStart = 0.0
    var dragTrack: UUID?
    var dragDestination: UUID?
    private var movingFragments: [(track: UUID, row: Int, clip: Clip)] = []
    private var fragmentDestinations: [UUID: UUID] = [:]
    private var copyingFragments = false
    private var fragmentCopyPreviews: [UUID: Clip] = [:]
    private(set) var fragmentSnapTime: Double?
    var didCheckpoint = false
    private var fadeDrag: (original: Clip, left: Bool)?
    private(set) var fadedFragment: Clip?
    private var didDragFade = false
    private var fragmentResize: (original: Clip, leftEdge: Bool, sourceDuration: Double)?
    private(set) var resizedFragment: Clip?
    var selectingRange = false
    var rangeAnchor: Double?
    var didDragRange = false
    private(set) var marqueeAnchor: NSPoint?
    private(set) var marqueeRect: NSRect?
    private var marqueeInitialSelection = Set<UUID>()
    private var marqueeInitialRange: ClosedRange<Double>?
    private var marqueeAdditive = false
    var trackDrag: UUID?
    private var trackDragRows: [(Track, Int)]?
    private(set) var trackPreview: [Track]?
    var pendingTrackRename: UUID?
    let nameField = InlineNameField(frame: .zero)
    private(set) var renamingTrack: UUID?
    private(set) var headerControls: NSView?
    private var scrollObserver: NSObjectProtocol?
    private var controlsTracking: NSTrackingArea?
    private var followedPlayback = false
    private var hoveredTrackControl: (id: UUID, kind: Int)?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    init(_ editor: Editor) { self.editor = editor; super.init(frame: .zero); addSubview(nameField); nameField.font = .systemFont(ofSize: 13, weight: .semibold); nameField.setAccessibilityLabel("Track name"); nameField.textChanged = { [weak self] in self?.layoutNameField() } }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
        scrollObserver = nil
        guard let clip = enclosingScrollView?.contentView else { return }
        clip.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.positionHeaderControls()
            if let window = self.window { self.updateTrackControlHover(at: self.convert(window.mouseLocationOutsideOfEventStream, from: nil)) }
            self.layoutNameField()
            self.setNeedsDisplay(self.visibleRect)
            self.window?.invalidateCursorRects(for: self)
        }
    }
    override func updateTrackingAreas() {
        if let controlsTracking { removeTrackingArea(controlsTracking) }
        super.updateTrackingAreas()
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area); controlsTracking = area
        window?.acceptsMouseMovedEvents = true
    }
    private func updateTrackControlHover(at point: NSPoint?) {
        var next: (id: UUID, kind: Int)?
        if let point, visibleTrackRect.contains(point), point.x < fragmentLeft,
           !editor.isRecording, !editor.isShuttling, !editor.requestingMic, !editor.isImporting {
            let row = Int((point.y - ruler) / rowHeight)
            if rows.indices.contains(row) {
                let (track, depth) = rows[row]
                let rects = [trackMuteRect(row: row, depth: depth), trackSoloRect(row: row, depth: depth), trackFXRect(row: row, depth: depth)]
                if let index = rects.firstIndex(where: { $0.contains(point) }) { next = (track.id, index) }
            }
        }
        if next?.id != hoveredTrackControl?.id || next?.kind != hoveredTrackControl?.kind { hoveredTrackControl = next; needsDisplay = true }
    }
    override func mouseMoved(with event: NSEvent) { updateTrackControlHover(at: convert(event.locationInWindow, from: nil)) }
    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseExited(with event: NSEvent) { updateTrackControlHover(at: nil) }
    private func drawTrackControlHover(_ id: UUID, kind: Int, rect: NSRect) {
        guard window?.isKeyWindow == true, hoveredTrackControl?.id == id, hoveredTrackControl?.kind == kind,
              !editor.isRecording, !editor.isShuttling, !editor.requestingMic, !editor.isImporting else { return }
        fill(rect, NSColor.white.withAlphaComponent(0.10), radius: 5)
        NSColor.white.withAlphaComponent(0.16).setStroke()
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.4, dy: 0.4), xRadius: 5, yRadius: 5); path.lineWidth = 0.7; path.stroke()
    }
    func installHeaderControls(_ view: NSView) {
        headerControls?.removeFromSuperview(); headerControls = view
        view.translatesAutoresizingMaskIntoConstraints = true
        addSubview(view)
        positionHeaderControls()
    }
    private func positionHeaderControls() {
        headerControls?.frame = NSRect(x: pinnedHeaderX, y: pinnedRulerRect.minY, width: header, height: ruler)
    }
    deinit { if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) } }
    var pinnedRulerRect: NSRect { NSRect(x: 0, y: max(0, visibleRect.minY), width: bounds.width, height: ruler) }
    var pinnedHeaderX: CGFloat { max(0, visibleRect.minX) }
    var fragmentLeft: CGFloat { pinnedHeaderX + header }
    var visibleFragmentRect: NSRect {
        let visible = visibleRect
        return NSRect(x: fragmentLeft, y: visible.minY, width: max(0, visible.width - header), height: visible.height)
    }
    var visibleTrackRect: NSRect {
        let visible = visibleRect, top = pinnedRulerRect.maxY
        return NSRect(x: visible.minX, y: top, width: visible.width, height: max(0, visible.maxY - top))
    }
    func isTrackPoint(_ point: NSPoint) -> Bool { point.y >= ruler && !pinnedRulerRect.contains(point) }
    var timelineDuration: Double { max(30, max(editor.duration, resizedFragment?.end ?? 0, fragmentCopyPreviews.values.map(\.end).max() ?? 0) + 8, editor.cursor + 5) }
    var viewportSize: NSSize { enclosingScrollView?.contentSize ?? NSSize(width: 1000, height: 600) }
    var minimumZoom: Double { max(1, viewportSize.width - header) / timelineDuration }
    var rulerStep: Double {
        let required = 80 / editor.zoom
        let magnitude = pow(10, floor(log10(max(1, required))))
        return [1.0, 2, 5, 10].map { $0 * magnitude }.first { $0 >= required } ?? magnitude * 10
    }
    private func orderedRows(_ tracks: [Track]) -> [(Track, Int)] { TrackHierarchy.orderedRows(tracks) }
    private func previewTrackMove(at point: NSPoint) {
        guard let source = trackDrag, let baseline = trackDragRows else { return }
        trackPreview = nil
        guard isTrackPoint(point), visibleRect.contains(point) else { refresh(); return }
        let tracks = baseline.map { $0.0 }
        var movingIDs: Set<UUID> = [source]
        var count = 0
        while movingIDs.count != count {
            count = movingIDs.count
            for track in tracks where track.parent.map({ movingIDs.contains($0) }) == true { movingIDs.insert(track.id) }
        }
        var remaining = tracks.filter { !movingIDs.contains($0.id) }
        let moving = tracks.filter { movingIDs.contains($0.id) }
        let position = max(0, (point.y - ruler) / rowHeight)
        let row = Int(position)
        var parent: UUID?
        var insertion: Int
        if row >= baseline.count {
            parent = nil; insertion = remaining.count
        } else {
            let target = baseline[row].0
            guard !movingIDs.contains(target.id), let targetIndex = remaining.firstIndex(where: { $0.id == target.id }) else { refresh(); return }
            let fraction = position - floor(position)
            if fraction < 0.25 {
                parent = target.parent; insertion = targetIndex
            } else {
                parent = fraction > 0.75 ? target.parent : target.id
                // Append after the target's complete subtree, preserving its existing children.
                var subtree: Set<UUID> = [target.id]
                insertion = targetIndex + 1
                while insertion < remaining.count, remaining[insertion].parent.map({ subtree.contains($0) }) == true {
                    subtree.insert(remaining[insertion].id); insertion += 1
                }
            }
        }
        var block = moving
        if let index = block.firstIndex(where: { $0.id == source }) { block[index].parent = parent }
        remaining.insert(contentsOf: block, at: insertion)
        guard (try? TrackHierarchy.validate(remaining)) != nil else { refresh(); return }
        trackPreview = remaining
        refresh()
    }
    func cancelTrackDrag() {
        trackPreview = nil; trackDragRows = nil; trackDrag = nil; pendingTrackRename = nil
        refresh()
    }
    func refresh() {
        rows = orderedRows(trackPreview ?? editor.project.tracks)
        let retained = Set(editor.project.tracks.flatMap(\.clips).map(\.id)).union(fragmentCopyPreviews.values.map(\.id))
        fragmentWaveforms = fragmentWaveforms.filter { retained.contains($0.key) }
        for id in Array(waveformJobs.keys) where !retained.contains(id) { waveformJobs.removeValue(forKey: id)?.1.cancel() }
        window?.invalidateCursorRects(for: self)
        let visible = viewportSize
        editor.zoom = max(minimumZoom, editor.zoom)
        let width = editor.zoom <= minimumZoom ? visible.width : max(visible.width, header + timelineDuration * editor.zoom)
        frame.size = NSSize(width: width, height: max(visible.height, ruler + CGFloat(rows.count) * rowHeight + 110))
        positionHeaderControls()
        layoutNameField()
        if let window, window.isKeyWindow { updateTrackControlHover(at: convert(window.mouseLocationOutsideOfEventStream, from: nil)) }
        else { updateTrackControlHover(at: nil) }
        needsDisplay = true
        let followsPlayback = editor.isPlaying || editor.isShuttling
        if followsPlayback || followedPlayback { centerOnPlayhead() }
        followedPlayback = followsPlayback
        if editor.isRecording, let scroll = enclosingScrollView {
            let visible = scroll.documentVisibleRect, x = header + editor.cursor * editor.zoom
            if x > visible.maxX - 40 {
                scroll.contentView.scroll(to: NSPoint(x: max(0, x - visible.width + 80), y: visible.minY))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        }
    }
    func clipRect(_ clip: Clip, row: Int, layer: Int) -> NSRect {
        NSRect(x: header + clip.start * editor.zoom, y: ruler + CGFloat(row) * rowHeight + 8 + CGFloat(min(layer, 4)) * 2, width: max(2, clip.duration * editor.zoom), height: rowHeight - 16 - CGFloat(min(layer, 4)) * 2)
    }
    func dropTrack(at point: NSPoint) -> UUID? {
        guard isTrackPoint(point), !rows.isEmpty else { return nil }
        let row = min(rows.count - 1, Int((point.y - ruler) / rowHeight))
        return rows[row].0.id
    }
    var fragmentSnapTolerance: Double { max(0, visibleFragmentRect.width) / editor.zoom * 0.01 }
    func snappedFragmentPosition(_ proposed: Double, clip: Clip, destination: UUID?) -> (start: Double, guide: Double?) {
        let minimum = originalStart - (movingFragments.map { $0.clip.start }.min() ?? originalStart)
        let start = max(minimum, proposed)
        guard let destination, destination != dragTrack else { return (start, nil) }
        // The original position is stable even as the live drag changes the model.
        var matches = [(start: originalStart, guide: originalStart)]
        for target in editor.project.tracks.flatMap(\.clips) where target.id != clip.id && !movingFragments.contains(where: { $0.clip.id == target.id }) {
            for edge in [target.start, target.end] {
                matches.append((edge, edge))
                matches.append((edge - clip.duration, edge))
            }
        }
        var best: (start: Double, guide: Double)?
        var distance = fragmentSnapTolerance
        for match in matches where match.start >= minimum {
            let difference = abs(match.start - start)
            if difference < distance { best = match; distance = difference }
        }
        return best.map { ($0.start, Optional($0.guide)) } ?? (start, nil)
    }
    private func updateFragmentMove(at point: NSPoint, flags: NSEvent.ModifierFlags) {
        guard let id = dragClip, let anchor = movingFragments.first(where: { $0.clip.id == id }),
              let requested = dropTrack(at: point), let targetRow = rows.firstIndex(where: { $0.0.id == requested }),
              let firstRow = movingFragments.map({ $0.row }).min(), let lastRow = movingFragments.map({ $0.row }).max() else { return }
        let rowDelta = max(-firstRow, min(targetRow - anchor.row, rows.count - 1 - lastRow))
        fragmentDestinations = Dictionary(uniqueKeysWithValues: movingFragments.map { ($0.clip.id, rows[$0.row + rowDelta].0.id) })
        dragDestination = fragmentDestinations[id]
        lastFragmentDragPoint = point
        let proposedDelta = (point.x - dragStart.x) / editor.zoom
        let delta: Double
        if editor.project.tempoMode && !flags.contains(.shift) {
            delta = TempoGrid.snappedMove(delta: proposedDelta, earliestStart: movingFragments.map { $0.clip.start }.min() ?? originalStart, bpm: editor.project.tempo)
            fragmentSnapTime = originalStart + delta
        } else {
            let position = snappedFragmentPosition(originalStart + proposedDelta, clip: anchor.clip, destination: dragDestination)
            delta = position.start - originalStart; fragmentSnapTime = position.guide
        }
        for original in movingFragments {
            if let i = editor.project.tracks.firstIndex(where: { $0.id == original.track }),
               let j = editor.project.tracks[i].clips.firstIndex(where: { $0.id == original.clip.id }) {
                if copyingFragments {
                    var copy = fragmentCopyPreviews[original.clip.id] ?? original.clip
                    if fragmentCopyPreviews[original.clip.id] == nil { copy.id = UUID() }
                    copy.start = original.clip.start + delta; fragmentCopyPreviews[original.clip.id] = copy
                } else { editor.project.tracks[i].clips[j].start = original.clip.start + delta }
            }
        }
        editor.update()
    }
    func displayedClips(for track: Track) -> [Clip] {
        var clips = track.clips
        if let fadedFragment, let index = clips.firstIndex(where: { $0.id == fadedFragment.id }) { clips[index] = fadedFragment }
        if let resizedFragment, let index = clips.firstIndex(where: { $0.id == resizedFragment.id }) { clips[index] = resizedFragment }
        if copyingFragments {
            for original in movingFragments where fragmentDestinations[original.clip.id] == track.id {
                if let copy = fragmentCopyPreviews[original.clip.id] { clips.append(copy) }
            }
        } else if !fragmentDestinations.isEmpty {
            clips.removeAll { fragmentDestinations[$0.id].map { $0 != track.id } == true }
            for source in editor.project.tracks where source.id != track.id {
                clips.append(contentsOf: source.clips.filter { fragmentDestinations[$0.id] == track.id })
            }
        }
        clips.sort { $0.order < $1.order }
        // Draw the whole moving selection above the destination's older fragments.
        if dragDestination != nil {
            let active = copyingFragments ? Set(fragmentCopyPreviews.values.map(\.id)) : Set(fragmentDestinations.keys)
            clips = clips.filter { !active.contains($0.id) } + clips.filter { active.contains($0.id) }
        }
        return clips
    }
    func fragmentFadeHandleRects(_ clip: Clip, in rect: NSRect) -> [NSRect] {
        let areas = fragmentFadeRects(clip, in: rect)
        let points = [areas[0].maxX, areas[1].minX]
        let width: CGFloat = 14
        var handles = points.map { x in
            NSRect(x: x - width / 2, y: rect.minY - 5, width: width, height: 18)
        }
        // When the curves meet, each side of the shared point edits its own fade.
        if handles[0].maxX > handles[1].minX {
            let middle = (points[0] + points[1]) / 2, right = handles[1].maxX
            handles[0].size.width = max(0, middle - handles[0].minX)
            handles[1].origin.x = middle; handles[1].size.width = max(0, right - middle)
        }
        return handles
    }
    func fragmentFadeRects(_ clip: Clip, in rect: NSRect) -> [NSRect] {
        let rate = editor.audio.sampleRate
        let lengths = clip.fadeLengths(frames: max(0, Int(clip.end * rate) - Int(clip.start * rate)), sampleRate: rate)
        return [lengths.0, lengths.1].enumerated().map { edge, frames in
            let width = min(rect.width, frames / rate * editor.zoom)
            return NSRect(x: edge == 0 ? rect.minX : rect.maxX - width, y: rect.minY, width: width, height: rect.height)
        }
    }
    private func updateFragmentFade(at point: NSPoint) {
        guard let fadeDrag else { return }
        let delta = (point.x - dragStart.x) / editor.zoom * 1000 * (fadeDrag.left ? 1 : -1)
        let originalDuration = fadeDrag.left ? fadeDrag.original.fadeInMS : fadeDrag.original.fadeOutMS
        fadedFragment = fadeDrag.original.changingFade(left: fadeDrag.left, durationMS: originalDuration + delta)
        refresh()
    }
    private func drawFragmentFades(_ clip: Clip, in rect: NSRect) {
        for (edge, area) in fragmentFadeRects(clip, in: rect).enumerated() where area.width > 0 {
            let curve = edge == 0 ? clip.fadeInCurve : clip.fadeOutCurve
            let path = NSBezierPath()
            for step in 0...48 {
                let t = Double(step) / 48
                let duration = edge == 0 ? clip.fadeInMS : clip.fadeOutMS
                let gain = duration == 0 ? 1 : curve.value(edge == 0 ? t : 1 - t)
                let point = NSPoint(x: area.minX + t * area.width, y: area.maxY - 2 - gain * max(0, area.height - 4))
                if step == 0 { path.move(to: point) } else { path.line(to: point) }
            }
            let shade = path.copy() as! NSBezierPath
            shade.line(to: NSPoint(x: area.maxX, y: area.minY)); shade.line(to: area.origin); shade.close()
            NSColor.black.withAlphaComponent(0.22).setFill(); shade.fill()
            NSColor.white.withAlphaComponent(0.85).setStroke(); path.lineWidth = 1.25; path.stroke()
        }
    }
    private static let fadeInCursor = fadeCursor(left: true)
    private static let fadeOutCursor = fadeCursor(left: false)
    private static func fadeCursor(left: Bool) -> NSCursor {
        let image = NSImage(size: NSSize(width: 20, height: 20), flipped: true) { _ in
            func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: (left ? x : 32 - x) * 0.625, y: y * 0.625) }
            let path = NSBezierPath(); path.lineJoinStyle = .round; path.lineCapStyle = .round
            path.move(to: point(3, 13)); path.line(to: point(3, 3)); path.line(to: point(13, 3))
            path.move(to: point(6, 26)); path.curve(to: point(26, 6), controlPoint1: point(18, 26), controlPoint2: point(18, 6))
            NSColor.black.withAlphaComponent(0.9).setStroke(); path.lineWidth = 2.5; path.stroke()
            NSColor.white.setStroke(); path.lineWidth = 1.1; path.stroke()
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: left ? 1.875 : 18.125, y: 1.875))
    }
    private struct FadeChoice { let id: UUID; let left: Bool; let curve: FadeCurve }
    private func fadeCurveMenu(_ clip: Clip, left: Bool) -> NSMenu {
        let menu = NSMenu(); menu.autoenablesItems = false; menu.minimumWidth = 84
        for curve in FadeCurve.allCases {
            let item = NSMenuItem(title: "", action: #selector(chooseFadeCurve(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = FadeChoice(id: clip.id, left: left, curve: curve)
            item.setAccessibilityLabel(curve.title)
            item.image = NSImage(size: NSSize(width: 56, height: 28), flipped: true) { rect in
                let path = NSBezierPath(); path.lineWidth = 2
                for step in 0...40 {
                    let t = Double(step) / 40
                    let point = NSPoint(x: 3 + t * (rect.width - 6), y: rect.maxY - 3 - curve.value(left ? t : 1 - t) * (rect.height - 6))
                    if step == 0 { path.move(to: point) } else { path.line(to: point) }
                }
                NSColor.labelColor.setStroke(); path.stroke(); return true
            }
            item.image?.isTemplate = true; menu.addItem(item)
        }
        return menu
    }
    @objc private func chooseFadeCurve(_ item: NSMenuItem) {
        guard let choice = item.representedObject as? FadeChoice else { return }
        editor.setFragmentFade(choice.id, left: choice.left, curve: choice.curve)
    }
    func fragmentEdgeRects(_ rect: NSRect) -> [NSRect] {
        let width = min(6, rect.width / 3)
        return [NSRect(x: rect.minX, y: rect.minY, width: width, height: rect.height),
                NSRect(x: rect.maxX - width, y: rect.minY, width: width, height: rect.height)]
    }
    @discardableResult func cancelFragmentResize() -> Bool {
        if fadeDrag != nil { fadeDrag = nil; fadedFragment = nil; didDragFade = false; refresh(); return true }
        guard fragmentResize != nil else { return false }
        fragmentResize = nil; resizedFragment = nil; pendingFragmentClick = nil; didResizeFragment = false; lastFragmentDragPoint = nil; refresh(); return true
    }
    private func updateFragmentResize(at point: NSPoint, flags: NSEvent.ModifierFlags) {
        guard let resize = fragmentResize else { return }
        lastFragmentDragPoint = point
        var delta = (point.x - dragStart.x) / editor.zoom
        if editor.project.tempoMode && !flags.contains(.shift) {
            let clip = resize.original, minimum = min(Clip.minimumDuration, clip.duration, resize.sourceDuration)
            let edge = resize.leftEdge ? clip.start : clip.end
            let lower = resize.leftEdge ? max(0, clip.start - clip.offset) : clip.start + minimum
            let upper = resize.leftEdge ? clip.end - minimum : clip.start + resize.sourceDuration - clip.offset
            guard lower <= upper, let snapped = TempoGrid.snappedEdge(time: edge + delta, bounds: lower...upper, bpm: editor.project.tempo) else { resizedFragment = clip; refresh(); return }
            delta = snapped - edge
        }
        resizedFragment = resize.original.resized(leftEdge: resize.leftEdge, by: delta, sourceDuration: resize.sourceDuration)
        refresh()
    }
    override func flagsChanged(with event: NSEvent) {
        if let point = lastFragmentDragPoint, !editor.busy {
            if fragmentResize != nil && didResizeFragment { updateFragmentResize(at: point, flags: event.modifierFlags) }
            else if dragClip != nil && didCheckpoint { updateFragmentMove(at: point, flags: event.modifierFlags) }
        }
        super.flagsChanged(with: event)
    }
    func trackNameRect(row: Int, depth: Int) -> NSRect {
        let x = pinnedHeaderX + CGFloat(min(depth, 6)) * 15 + 18
        let meterWidth: CGFloat = rows.indices.contains(row) && editor.showsTrackMeter(rows[row].0.id) ? 66 : 0
        return NSRect(x: x, y: ruler + CGFloat(row) * rowHeight + 10, width: fragmentLeft - x - 12 - meterWidth, height: 22)
    }
    func trackNameHitRect(row: Int, depth: Int) -> NSRect {
        guard rows.indices.contains(row) else { return .zero }
        var rect = trackNameRect(row: row, depth: depth)
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .semibold)]
        let prefix = depth > 0 ? ("↳  " as NSString).size(withAttributes: attributes).width : 0
        rect.origin.x += prefix
        rect.size.width = max(0, min(rect.width - prefix, ceil((rows[row].0.name as NSString).size(withAttributes: attributes).width)))
        return rect
    }
    func trackMuteRect(row: Int, depth: Int) -> NSRect {
        NSRect(x: pinnedHeaderX + CGFloat(min(depth, 6)) * 15 + 18, y: ruler + CGFloat(row) * rowHeight + 42, width: 46, height: 23)
    }
    func trackSoloRect(row: Int, depth: Int) -> NSRect {
        trackMuteRect(row: row, depth: depth).offsetBy(dx: 54, dy: 0)
    }
    func trackFXRect(row: Int, depth: Int) -> NSRect {
        let x = pinnedHeaderX + CGFloat(min(depth, 6)) * 15 + 18
        return NSRect(x: min(fragmentLeft - 54, x + 108), y: ruler + CGFloat(row) * rowHeight + 42, width: 46, height: 23)
    }
    func rangeHandleRects() -> [NSRect] {
        guard let range = editor.range else { return [] }
        return [range.lowerBound, range.upperBound].map {
            NSRect(x: header + $0 * editor.zoom - 5, y: pinnedRulerRect.minY, width: 10, height: ruler)
                .intersection(NSRect(x: fragmentLeft, y: pinnedRulerRect.minY, width: max(0, visibleRect.width - header), height: ruler))
        }
    }
    var canSelectRange: Bool { !editor.isRecording && !editor.requestingMic && !editor.isImporting }
    override func resetCursorRects() {
        super.resetCursorRects()
        if canSelectRange {
            for rect in rangeHandleRects() {
                let visible = rect.intersection(visibleRect)
                if !visible.isEmpty { addCursorRect(visible, cursor: .resizeLeftRight) }
            }
        }
        for (row, item) in rows.enumerated() {
            if !editor.busy {
                let clips = displayedClips(for: item.0)
                let rects = clips.enumerated().map { layer, clip in
                    clipRect(clip, row: row, layer: clips.prefix(layer).filter { $0.start < clip.end && $0.end > clip.start }.count)
                }
                for index in rects.indices {
                    let handles = editor.selection.contains(clips[index].id) ? fragmentFadeHandleRects(clips[index], in: rects[index]) : []
                    let newer = Array(rects.dropFirst(index + 1))
                    let edges = fragmentEdgeRects(rects[index]).map { ($0, NSCursor.resizeLeftRight, newer + handles) }
                    let corners = handles.enumerated().map { ($0.element, $0.offset == 0 ? Self.fadeInCursor : Self.fadeOutCursor, newer) }
                    for (edge, cursor, covers) in edges + corners {
                        var exposed = [edge.intersection(visibleTrackRect).intersection(visibleFragmentRect)]
                        // Keep corner and edge cursors disjoint; hidden regions receive neither.
                        for cover in covers {
                            exposed = exposed.flatMap { rect -> [NSRect] in
                                let overlap = rect.intersection(cover)
                                guard !overlap.isEmpty else { return [rect] }
                                return [NSRect(x: rect.minX, y: rect.minY, width: overlap.minX - rect.minX, height: rect.height),
                                        NSRect(x: overlap.maxX, y: rect.minY, width: rect.maxX - overlap.maxX, height: rect.height),
                                        NSRect(x: overlap.minX, y: rect.minY, width: overlap.width, height: overlap.minY - rect.minY),
                                        NSRect(x: overlap.minX, y: overlap.maxY, width: overlap.width, height: rect.maxY - overlap.maxY)]
                                    .filter { !$0.isEmpty }
                            }
                        }
                        for rect in exposed where !rect.isEmpty { addCursorRect(rect, cursor: cursor) }
                    }
                }
            }
            let depth = item.1
            for (rect, cursor) in [(trackNameHitRect(row: row, depth: depth), NSCursor.iBeam),
                                   (trackMuteRect(row: row, depth: depth), NSCursor.arrow),
                                   (trackSoloRect(row: row, depth: depth), NSCursor.arrow),
                                   (trackFXRect(row: row, depth: depth), NSCursor.arrow)] {
                let visible = rect.intersection(visibleTrackRect)
                if !visible.isEmpty && (!editor.busy || ((rect == trackFXRect(row: row, depth: depth) || rect == trackMuteRect(row: row, depth: depth) || rect == trackSoloRect(row: row, depth: depth)) && !editor.isRecording && !editor.isShuttling && !editor.requestingMic && !editor.isImporting)) { addCursorRect(visible, cursor: cursor) }
            }
        }
    }
    func renameTrack(_ id: UUID) {
        guard !editor.busy, let index = editor.project.tracks.firstIndex(where: { $0.id == id }) else { return }
        nameField.finish(commit: true)
        renamingTrack = id
        layoutNameField()
        guard renamingTrack != nil else { return }
        nameField.begin(editor.project.tracks[index].name, commit: { [weak self] name in
            guard let self, let index = self.editor.project.tracks.firstIndex(where: { $0.id == id }), self.editor.project.tracks[index].name != name else { return }
            self.editor.checkpoint(); self.editor.project.tracks[index].name = name; self.editor.update("Track renamed")
        }, end: { [weak self] in self?.renamingTrack = nil; self?.needsDisplay = true })
    }
    private func layoutNameField() {
        guard let id = renamingTrack else { return }
        guard let row = rows.firstIndex(where: { $0.0.id == id }) else {
            nameField.finish(commit: false); renamingTrack = nil; return
        }
        let rect = trackNameHitRect(row: row, depth: rows[row].1)
        let name = nameField.isRenaming ? nameField.stringValue : rows[row].0.name
        let width = ceil((name as NSString).size(withAttributes: [.font: nameField.font!]).width) + 4
        let frame = NSRect(x: rect.minX - 2, y: rect.minY, width: min(max(4, width), trackNameRect(row: row, depth: rows[row].1).maxX - rect.minX), height: 22)
        guard visibleTrackRect.contains(frame) else {
            nameField.finish(commit: true); renamingTrack = nil; return
        }
        nameField.frame = frame
    }
    func drawWaveform(_ peaks: [Float], partialPeak: Float? = nil, sampleRate: Double, offset: Double, gain: Double = 1, fragment: Clip? = nil, in rect: NSRect, dirtyRect: NSRect, color: NSColor) {
        let top = rect.minY + 1, bottom = rect.maxY - 1
        let mid = (top + bottom) / 2, amplitude = max(1, (bottom - top) / 2)
        let lowX = max(rect.minX, dirtyRect.minX), highX = min(rect.maxX, dirtyRect.maxX)
        let count = peaks.count + (partialPeak == nil ? 0 : 1)
        let path = NSBezierPath(); path.lineWidth = 1
        for x in stride(from: lowX, to: highX, by: 2) {
            let seconds = offset + (x - rect.minX) / editor.zoom
            let first = max(0, Int(seconds * sampleRate) / 128)
            let last = min(count, max(first + 1, Int((seconds + 2 / editor.zoom) * sampleRate) / 128))
            var peak: Float = 0
            if first < last { for index in first..<last { peak = max(peak, index < peaks.count ? peaks[index] : (partialPeak ?? 0)) } }
            var envelope = 1.0
            if let fragment {
                let frames = Int(fragment.duration * sampleRate), relative = (x - rect.minX) / editor.zoom * sampleRate
                let (first, last) = fragment.fadeLengths(frames: frames, sampleRate: sampleRate)
                let incoming = fragment.fadeInBaked || first == 0 ? 1 : fragment.fadeInCurve.value(relative / first)
                let outgoing = fragment.fadeOutBaked || last == 0 ? 1 : fragment.fadeOutCurve.value((Double(frames - 1) - relative) / last)
                envelope = min(incoming, outgoing)
            }
            let h = CGFloat(min(1, Double(peak) * gain * envelope)) * amplitude
            path.move(to: NSPoint(x: x, y: mid - h)); path.line(to: NSPoint(x: x, y: mid + max(0.4, h)))
        }
        color.setStroke(); path.stroke()
    }
    func drawChannelWaveforms(_ peaks: [[Float]], partialPeaks: [Float?] = [], sampleRate: Double, offset: Double, gain: Double = 1, fragment: Clip? = nil, in rect: NSRect, dirtyRect: NSRect, color: NSColor) {
        let count = min(2, peaks.count)
        guard count > 0 else { return }
        let top = rect.minY + 2, bottom = rect.maxY - 2
        let gap: CGFloat = count == 2 ? 2 : 0
        let height = max(0, (bottom - top - gap) / CGFloat(count))
        for channel in 0..<count {
            let lane = NSRect(x: rect.minX, y: top + CGFloat(channel) * (height + gap), width: rect.width, height: height)
            drawWaveform(peaks[channel], partialPeak: partialPeaks.indices.contains(channel) ? partialPeaks[channel] : nil, sampleRate: sampleRate, offset: offset, gain: gain * (count > 1 ? (fragment?.panGain(channel: channel, channels: editor.project.audioFormat.channels) ?? 1) : 1), fragment: fragment, in: lane, dirtyRect: dirtyRect, color: color)
        }
        if count == 2 {
            let y = top + height + gap / 2
            line(NSPoint(x: rect.minX + 1, y: y), NSPoint(x: rect.maxX - 1, y: y), color.withAlphaComponent(0.15))
        }
    }
    func drawFragmentTitle(_ text: String, in rect: NSRect, color: NSColor, weight: NSFont.Weight = .medium) {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow(); shadow.shadowColor = NSColor.black; shadow.shadowOffset = .zero
        let titleRect = NSRect(x: rect.minX + 9, y: rect.minY + 6, width: max(0, rect.width - 18), height: 16)
        for radius: CGFloat in [10, 8, 6, 4, 2] {
            shadow.shadowBlurRadius = radius; shadow.set()
            label(text, titleRect, size: 10, color: color, weight: weight)
        }
        NSGraphicsContext.restoreGraphicsState()
    }
    private func dimmedTrackIDs() -> Set<UUID> {
        let tracks = trackPreview ?? editor.project.tracks
        var dimmed = Set(tracks.filter(\.muted).map(\.id))
        var previous: Set<UUID> = []
        while previous != dimmed {
            previous = dimmed
            for track in tracks where track.parent.map({ dimmed.contains($0) }) == true { dimmed.insert(track.id) }
        }
        return dimmed.union(Set(tracks.map(\.id)).subtracting(TrackSoloRouting(tracks: tracks).dry))
    }
    override func draw(_ dirtyRect: NSRect) {
        fill(bounds, background)
        let dimmed = dimmedTrackIDs()
        for tick in rulerTicks(in: dirtyRect) {
            let x = header + tick.time * editor.zoom
            let alpha = editor.project.tempoMode ? (tick.isBar ? 0.10 : 0.035) : 0.045
            line(NSPoint(x: x, y: ruler), NSPoint(x: x, y: bounds.height), NSColor.white.withAlphaComponent(alpha))
        }
        for (index, item) in rows.enumerated() {
            let track = item.0; let y = ruler + CGFloat(index) * rowHeight
            let trackDimmed = dimmed.contains(track.id)
            if !NSRect(x: 0, y: y, width: bounds.width, height: rowHeight).intersects(dirtyRect) { continue }
            let color = trackColors[index % trackColors.count]
            line(NSPoint(x: 0, y: y + rowHeight), NSPoint(x: bounds.width, y: y + rowHeight), .white.withAlphaComponent(0.065))
            let clips = displayedClips(for: track)
            for (layer, clip) in clips.enumerated() {
                let overlaps = clips.prefix(layer).filter { $0.start < clip.end && $0.end > clip.start }.count
                let rect = clipRect(clip, row: index, layer: overlaps)
                guard rect.intersects(dirtyRect) else { continue }
                fill(rect.offsetBy(dx: 0, dy: 3), .black.withAlphaComponent(0.4), radius: 6)
                fill(rect, color.blended(withFraction: trackDimmed || clip.muted ? 0.92 : 0.78, of: background)!, radius: 6)
                let outline = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6); outline.lineWidth = editor.selection.contains(clip.id) ? 2 : 1
                (editor.selection.contains(clip.id) ? color : color.withAlphaComponent(0.45)).setStroke(); outline.stroke()
                NSGraphicsContext.saveGraphicsState(); NSBezierPath(rect: rect.insetBy(dx: 1, dy: 1)).addClip()
                if let data = try? editor.audio.load(clip.source) {
                    if let peaks = processedWaveform(clip, audio: data) {
                        drawChannelWaveforms(peaks, sampleRate: editor.audio.sampleRate, offset: 0, in: rect, dirtyRect: dirtyRect, color: color.withAlphaComponent(trackDimmed || clip.muted ? 0.25 : 0.9))
                    } else {
                        drawChannelWaveforms(data.channelPeaks, sampleRate: editor.audio.sampleRate, offset: clip.offset, gain: clip.volumeGain, fragment: clip, in: rect, dirtyRect: dirtyRect, color: color.withAlphaComponent(trackDimmed || clip.muted ? 0.25 : 0.9))
                    }
                }
                if editor.selection.contains(clip.id) { drawFragmentFades(clip, in: rect) }
                drawFragmentTitle(clip.name, in: rect, color: trackDimmed || clip.muted ? .secondaryLabelColor : color)
                NSGraphicsContext.restoreGraphicsState()
            }
            if editor.isRecording && editor.recordingTrack == track.id {
                let rect = NSRect(x: header + editor.recordingStart * editor.zoom, y: y + 8, width: max(10, (editor.cursor - editor.recordingStart) * editor.zoom), height: rowHeight - 16)
                fill(rect, NSColor.systemRed.blended(withFraction: 0.85, of: background)!, radius: 6)
                NSColor.systemRed.setStroke(); NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).stroke()
                NSGraphicsContext.saveGraphicsState(); NSBezierPath(rect: rect.insetBy(dx: 1, dy: 1)).addClip()
                drawChannelWaveforms(editor.recordingChannelPeaks, partialPeaks: editor.recordingPartialChannelPeaks, sampleRate: editor.recorder?.format.sampleRate ?? editor.audio.sampleRate, offset: 0, in: rect, dirtyRect: dirtyRect, color: .systemRed)
                NSGraphicsContext.restoreGraphicsState()
            }
        }
        if let range = editor.range {
            fill(NSRect(x: header + range.lowerBound * editor.zoom, y: ruler, width: (range.upperBound - range.lowerBound) * editor.zoom, height: bounds.height - ruler), accent.withAlphaComponent(0.09))
        }
        let playX = header + editor.cursor * editor.zoom
        line(NSPoint(x: playX, y: ruler), NSPoint(x: playX, y: bounds.height), editor.isRecording ? .systemRed : accent, width: 1.5)
        if let fragmentSnapTime {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: visibleFragmentRect.intersection(visibleTrackRect)).addClip()
            let x = header + fragmentSnapTime * editor.zoom
            let guide = NSBezierPath(); guide.move(to: NSPoint(x: x, y: pinnedRulerRect.maxY))
            guide.line(to: NSPoint(x: x, y: visibleRect.maxY))
            guide.lineWidth = 1.5; guide.setLineDash([4, 4], count: 2, phase: 0)
            NSColor.white.withAlphaComponent(0.9).setStroke(); guide.stroke()
            NSGraphicsContext.restoreGraphicsState()
        }
        if let rect = marqueeRect {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: visibleFragmentRect.intersection(visibleTrackRect)).addClip()
            fill(rect, accent.withAlphaComponent(0.12))
            accent.withAlphaComponent(0.9).setStroke()
            let outline = NSBezierPath(rect: rect); outline.lineWidth = 1; outline.stroke()
            NSGraphicsContext.restoreGraphicsState()
        }
        drawTrackHeaders(in: dirtyRect)
        drawRuler(in: dirtyRect)
    }
    private func meterColor(_ amplitude: Double) -> NSColor {
        let db = TrackLevelMeter.decibels(amplitude)
        return db >= -1 ? .systemRed : db >= -6 ? .systemYellow : accent
    }
    private func drawTrackHeaders(in dirtyRect: NSRect) {
        let dimmed = dimmedTrackIDs()
        let column = NSRect(x: pinnedHeaderX, y: ruler, width: header, height: max(0, bounds.height - ruler))
        fill(column, panelColor)
        NSGraphicsContext.saveGraphicsState(); NSBezierPath(rect: column).addClip()
        for (index, item) in rows.enumerated() {
            let (track, depth) = item; let y = ruler + CGFloat(index) * rowHeight
            guard NSRect(x: pinnedHeaderX, y: y, width: header, height: rowHeight).intersects(dirtyRect) else { continue }
            let selected = editor.selectedTrack == track.id
            let trackDimmed = dimmed.contains(track.id)
            fill(NSRect(x: pinnedHeaderX, y: y, width: header, height: rowHeight), selected ? NSColor(calibratedRed: 0.12, green: 0.16, blue: 0.19, alpha: 1) : panelColor)
            let meter = editor.trackMeters[track.id] ?? TrackLevelMeter()
            let recording = editor.isRecording && editor.recordingTrack == track.id
            let headerRect = NSRect(x: pinnedHeaderX, y: y, width: header, height: rowHeight)
            if (recording || editor.isPlaying) && meter.fraction > 0 {
                fill(NSRect(x: headerRect.minX, y: y, width: header * meter.fraction, height: rowHeight), accent.withAlphaComponent(0.25))
            }
            if editor.showsTrackMeter(track.id) {
                label(meter.peakText, NSRect(x: fragmentLeft - 74, y: y + 12, width: 62, height: 16), size: 9, color: recording ? .systemRed : meterColor(meter.peak), weight: .medium, alignment: .right)
            }
            let color = trackColors[index % trackColors.count]
            fill(NSRect(x: pinnedHeaderX, y: y + 1, width: 3, height: rowHeight - 2), selected ? color.withAlphaComponent(trackDimmed ? 0.3 : 1) : .clear)
            let editing = renamingTrack == track.id && nameField.isRenaming
            let title = editing ? (depth > 0 ? "↳  " : "") : (depth > 0 ? "↳  \(track.name)" : track.name)
            label(title, trackNameRect(row: index, depth: depth), size: 13, color: trackDimmed ? .secondaryLabelColor : .labelColor, weight: .semibold)
            let muteRect = trackMuteRect(row: index, depth: depth)
            fill(muteRect, track.muted ? NSColor.systemOrange.withAlphaComponent(0.25) : NSColor.white.withAlphaComponent(0.06), radius: 5)
            drawTrackControlHover(track.id, kind: 0, rect: muteRect)
            label(track.muted ? "MUTED" : "MUTE", NSRect(x: muteRect.minX, y: muteRect.minY + 5, width: muteRect.width, height: 15), size: 9, color: track.muted ? .systemOrange : .secondaryLabelColor, weight: .semibold, alignment: .center)
            let soloRect = trackSoloRect(row: index, depth: depth)
            fill(soloRect, track.solo ? NSColor.systemBlue.withAlphaComponent(0.25) : NSColor.white.withAlphaComponent(0.06), radius: 5)
            drawTrackControlHover(track.id, kind: 1, rect: soloRect)
            label("SOLO", NSRect(x: soloRect.minX, y: soloRect.minY + 5, width: soloRect.width, height: 15), size: 9, color: track.solo ? .systemBlue : .secondaryLabelColor, weight: .semibold, alignment: .center)
            let fxRect = trackFXRect(row: index, depth: depth)
            fill(fxRect, track.effects.isEmpty ? NSColor.white.withAlphaComponent(0.06) : color.withAlphaComponent(0.18), radius: 5)
            drawTrackControlHover(track.id, kind: 2, rect: fxRect)
            label("FX", NSRect(x: fxRect.minX, y: fxRect.minY + 5, width: fxRect.width, height: 15), size: 10, color: track.effects.isEmpty ? .secondaryLabelColor : color, weight: .semibold, alignment: .center)
            line(NSPoint(x: pinnedHeaderX, y: y + rowHeight), NSPoint(x: fragmentLeft, y: y + rowHeight), .white.withAlphaComponent(0.065))
        }
        NSGraphicsContext.restoreGraphicsState()
        line(NSPoint(x: fragmentLeft, y: ruler), NSPoint(x: fragmentLeft, y: bounds.height), .white.withAlphaComponent(0.10))
    }
    func rulerTicks(in rect: NSRect) -> [TempoTick] {
        let start = max(0, (rect.minX - header) / editor.zoom)
        let end = max(start, (rect.maxX - header) / editor.zoom)
        if editor.project.tempoMode { return TempoGrid.ticks(from: start, to: end, zoom: editor.zoom, bpm: editor.project.tempo) }
        let step = rulerStep, first = floor(start / step) * step
        return stride(from: first, through: end, by: step).map {
            TempoTick(time: $0, label: String(format: "%02d:%02d", Int($0) / 60, Int($0) % 60), isBar: true)
        }
    }
    private func drawRuler(in dirtyRect: NSRect) {
        let rect = pinnedRulerRect, top = rect.minY
        fill(rect, panelColor)
        NSGraphicsContext.saveGraphicsState(); NSBezierPath(rect: visibleFragmentRect).addClip()
        if let range = editor.range {
            fill(NSRect(x: header + range.lowerBound * editor.zoom, y: top, width: (range.upperBound - range.lowerBound) * editor.zoom, height: ruler), accent.withAlphaComponent(0.09))
        }
        for tick in rulerTicks(in: dirtyRect) {
            let x = header + tick.time * editor.zoom
            if editor.project.tempoMode {
                line(NSPoint(x: x, y: rect.maxY - (tick.isBar ? 10 : 5)), NSPoint(x: x, y: rect.maxY), NSColor.white.withAlphaComponent(tick.isBar ? 0.10 : 0.035))
            }
            if !tick.label.isEmpty {
                let textHeight = ceil((tick.label as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 10)]).height)
                label(tick.label, NSRect(x: x + 7, y: rect.midY - textHeight / 2, width: editor.project.tempoMode ? 70 : 60, height: textHeight), size: 10, color: editor.project.tempoMode && tick.isBar ? .labelColor : .secondaryLabelColor)
            }
        }
        if let range = editor.range {
            for time in [range.lowerBound, range.upperBound] {
                let x = header + time * editor.zoom
                line(NSPoint(x: x, y: top), NSPoint(x: x, y: rect.maxY), accent.withAlphaComponent(0.8), width: 2)
                fill(NSRect(x: x - 3, y: top + ruler / 2 - 6, width: 6, height: 12), accent, radius: 2)
            }
        }
        let playX = header + editor.cursor * editor.zoom
        line(NSPoint(x: playX, y: top), NSPoint(x: playX, y: rect.maxY), editor.isRecording ? .systemRed : accent, width: 1.5)
        fill(NSRect(x: playX - 4, y: top, width: 8, height: 8), editor.isRecording ? .systemRed : accent, radius: 2)
        if let start = editor.lastPlaybackStart {
            let x = header + start * editor.zoom
            line(NSPoint(x: x, y: rect.maxY - 15), NSPoint(x: x, y: rect.maxY), .systemOrange, width: 2)
        }
        NSGraphicsContext.restoreGraphicsState()
        fill(NSRect(x: pinnedHeaderX, y: top, width: header, height: ruler), panelColor)
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        pendingFragmentClick = nil; pendingShiftFragmentClick = nil; lastFragmentDragPoint = nil; didResizeFragment = false
        let point = convert(event.locationInWindow, from: nil)
        // A ruler press is only a seek once released without dragging.
        // Range selection and handle resizing never touch the transport.
        if pinnedRulerRect.contains(point) {
            guard canSelectRange, point.x >= fragmentLeft else { return }
            dragStart = point; selectingRange = true; didDragRange = false; rangeAnchor = nil
            if let range = editor.range, event.clickCount < 2 {
                let handles = rangeHandleRects()
                let hits = handles.indices.filter { handles[$0].contains(point) }
                if let edge = hits.min(by: { abs(handles[$0].midX - point.x) < abs(handles[$1].midX - point.x) }) {
                    rangeAnchor = edge == 0 ? range.upperBound : range.lowerBound
                }
            }
            return
        }
        if !editor.isRecording && !editor.isShuttling && !editor.requestingMic && !editor.isImporting && isTrackPoint(point) && point.x < fragmentLeft {
            let row = Int((point.y - ruler) / rowHeight)
            if rows.indices.contains(row), trackMuteRect(row: row, depth: rows[row].1).contains(point) {
                editor.selectedTrack = rows[row].0.id
                editor.toggleMute(rows[row].0.id); return
            }
            if rows.indices.contains(row), trackSoloRect(row: row, depth: rows[row].1).contains(point) {
                editor.selectedTrack = rows[row].0.id
                editor.toggleSolo(rows[row].0.id); return
            }
            if rows.indices.contains(row), trackFXRect(row: row, depth: rows[row].1).contains(point) {
                editor.selectedTrack = rows[row].0.id; editor.update()
                EffectsWindow(editor: editor, trackID: rows[row].0.id).run(); return
            }
        }
        guard !editor.busy || (editor.isPlaying && point.x >= fragmentLeft) else { return }
        let p = point; dragStart = p; didCheckpoint = false; pendingTrackRename = nil
        let row = Int((p.y - ruler) / rowHeight)
        guard isTrackPoint(p), row >= 0 else { return }
        guard row < rows.count else {
            if p.x >= fragmentLeft { beginMarquee(at: p, additive: event.modifierFlags.contains(.shift)) }
            return
        }
        let (track, depth) = rows[row]; editor.selectedTrack = track.id
        if p.x < fragmentLeft {
            if trackFXRect(row: row, depth: depth).contains(p) {
                EffectsWindow(editor: editor, trackID: track.id).run(); return
            }
            if trackMuteRect(row: row, depth: depth).contains(p) {
                editor.toggleMute(track.id)
            } else if trackSoloRect(row: row, depth: depth).contains(p) {
                editor.toggleSolo(track.id)
            } else {
                trackDrag = track.id
                if trackNameHitRect(row: row, depth: depth).contains(p) { pendingTrackRename = track.id }
            }
            editor.update(); return
        }
        let clips = track.clips.sorted { $0.order < $1.order }
        for (layer, clip) in clips.enumerated().reversed() {
            let overlaps = clips.prefix(layer).filter { $0.start < clip.end && $0.end > clip.start }.count
            let rect = clipRect(clip, row: row, layer: overlaps)
            let fadeHit = editor.selection.contains(clip.id) ? fragmentFadeHandleRects(clip, in: rect).firstIndex(where: { $0.contains(p) }) : nil
            if rect.contains(p) || (!editor.busy && fadeHit != nil) {
                if event.clickCount == 2, !editor.busy {
                    editor.range = nil; editor.selection = [clip.id]; pendingFragmentClick = nil; editor.update()
                    (NSApp.delegate as? AppDelegate)?.editFragment(clip.id); return
                }
                if !editor.busy, let edge = fadeHit {
                    fadeDrag = (clip, edge == 0); fadedFragment = clip; didDragFade = false
                    editor.update(); return
                }
                if !editor.busy, let edge = fragmentEdgeRects(clipRect(clip, row: row, layer: overlaps)).firstIndex(where: { $0.contains(p) }) {
                    do {
                        let duration = try editor.audio.sourceDuration(clip.source)
                        fragmentResize = (clip, edge == 0, duration); resizedFragment = clip
                        if !event.modifierFlags.contains(.shift) { pendingFragmentClick = clip.id }
                        if !editor.selection.contains(clip.id) { editor.selection = [clip.id] }
                        editor.hint(.selectFragments, "Shift click to multi select"); editor.update()
                    } catch { editor.error(error) }
                    return
                }
                if !event.modifierFlags.contains(.shift) { pendingFragmentClick = clip.id }
                if event.clickCount == 2 { editor.range = nil }
                editor.seek(to: (p.x - header) / editor.zoom)
                if event.modifierFlags.contains(.shift) { if editor.selection.contains(clip.id) { pendingShiftFragmentClick = clip.id } else { editor.selection.insert(clip.id) } }
                else if !editor.selection.contains(clip.id) { editor.selection = [clip.id] }
                if editor.selection.contains(clip.id) { editor.hint(.selectFragments, "Shift click to multi select") }
                if !editor.busy && editor.selection.contains(clip.id) {
                    dragClip = clip.id; originalStart = clip.start; dragTrack = track.id; dragDestination = nil; fragmentSnapTime = nil
                    fragmentDestinations = [:]; fragmentCopyPreviews = [:]; copyingFragments = false
                    movingFragments = rows.enumerated().flatMap { index, row in
                        row.0.clips.filter { editor.selection.contains($0.id) }.map { (row.0.id, index, $0) }
                    }
                }
                editor.update(); return
            }
        }
        beginMarquee(at: p, additive: event.modifierFlags.contains(.shift))
    }
    private func beginMarquee(at point: NSPoint, additive: Bool) {
        marqueeAnchor = point; marqueeRect = nil
        marqueeInitialSelection = editor.selection; marqueeInitialRange = editor.range
        marqueeAdditive = additive
    }
    private func updateMarquee(to point: NSPoint) {
        guard let anchor = marqueeAnchor else { return }
        guard marqueeRect != nil || hypot(point.x - anchor.x, point.y - anchor.y) > 3 else { return }
        let end = NSPoint(x: min(bounds.maxX, max(fragmentLeft, point.x)), y: min(bounds.maxY, max(pinnedRulerRect.maxY, point.y)))
        let rect = NSRect(x: min(anchor.x, end.x), y: min(anchor.y, end.y), width: max(1, abs(end.x - anchor.x)), height: max(1, abs(end.y - anchor.y)))
        marqueeRect = rect
        var hits = Set<UUID>()
        for (row, item) in rows.enumerated() {
            let clips = item.0.clips.sorted { $0.order < $1.order }
            for (layer, clip) in clips.enumerated() {
                let overlaps = clips.prefix(layer).filter { $0.start < clip.end && $0.end > clip.start }.count
                if clipRect(clip, row: row, layer: overlaps).intersects(rect) { hits.insert(clip.id) }
            }
        }
        editor.selection = marqueeAdditive ? marqueeInitialSelection.union(hits) : hits
        editor.range = nil
        if !hits.isEmpty { editor.hint(.selectFragments, "Shift click to multi select") }
        editor.update()
    }
    private func clearMarquee() {
        marqueeAnchor = nil; marqueeRect = nil; marqueeInitialSelection = []; marqueeInitialRange = nil
        needsDisplay = true
    }
    @discardableResult func cancelMarqueeSelection() -> Bool {
        guard marqueeAnchor != nil else { return false }
        editor.selection = marqueeInitialSelection; editor.range = marqueeInitialRange
        clearMarquee(); editor.update(); return true
    }
    private func autoscrollRange(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let horizontalPoint = NSPoint(x: point.x, y: visibleRect.midY)
        if let horizontalEvent = NSEvent.mouseEvent(with: .leftMouseDragged, location: convert(horizontalPoint, to: nil), modifierFlags: event.modifierFlags, timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil, eventNumber: event.eventNumber, clickCount: event.clickCount, pressure: event.pressure) {
            autoscroll(with: horizontalEvent)
        }
    }
    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if fadeDrag != nil {
            guard !editor.busy else { cancelFragmentResize(); return }
            guard didDragFade || abs(p.x - dragStart.x) > 2 else { return }
            didDragFade = true; autoscrollRange(with: event)
            updateFragmentFade(at: convert(event.locationInWindow, from: nil)); return
        }
        if fragmentResize != nil {
            guard !editor.busy else { cancelFragmentResize(); return }
            guard didResizeFragment || abs(p.x - dragStart.x) > 2 else { return }
            didResizeFragment = true; autoscrollRange(with: event)
            updateFragmentResize(at: convert(event.locationInWindow, from: nil), flags: event.modifierFlags); return
        }
        if marqueeAnchor != nil {
            guard canSelectRange else { cancelMarqueeSelection(); return }
            autoscroll(with: event)
            updateMarquee(to: convert(event.locationInWindow, from: nil))
            return
        }
        if selectingRange {
            guard canSelectRange else { return }
            guard didDragRange || abs(p.x - dragStart.x) > 3 else { return }
            didDragRange = true
            let a = rangeAnchor ?? max(0, (dragStart.x - header) / editor.zoom)
            let b = max(0, (p.x - header) / editor.zoom)
            editor.range = min(a, b)...max(a, b)
            editor.update(); autoscrollRange(with: event); return
        }
        guard !editor.busy else { return }
        if trackDrag != nil, trackDragRows != nil || hypot(p.x - dragStart.x, p.y - dragStart.y) > 4 {
            pendingTrackRename = nil
            if trackDragRows == nil { trackDragRows = orderedRows(editor.project.tracks) }
            editor.hint(.nestTracks, "Drag tracks to nest")
            previewTrackMove(at: p)
        }
        if dragClip != nil, hypot(p.x - dragStart.x, p.y - dragStart.y) > 2 || didCheckpoint {
            if !didCheckpoint {
                copyingFragments = event.modifierFlags.contains(.command)
                editor.checkpoint(); didCheckpoint = true
            }
            if copyingFragments { NSCursor.dragCopy.set() }
            updateFragmentMove(at: p, flags: event.modifierFlags)
        }
        if trackDrag != nil {
            let point = NSPoint(x: visibleRect.midX, y: p.y)
            if let verticalEvent = NSEvent.mouseEvent(with: .leftMouseDragged, location: convert(point, to: nil), modifierFlags: event.modifierFlags, timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil, eventNumber: event.eventNumber, clickCount: event.clickCount, pressure: event.pressure) { autoscroll(with: verticalEvent) }
        } else { autoscroll(with: event) }
    }
    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil); let row = Int((p.y - ruler) / rowHeight)
        if let drag = fadeDrag {
            if !editor.busy, didDragFade {
                updateFragmentFade(at: p)
                if let clip = fadedFragment { editor.setFragmentFade(clip.id, left: drag.left, durationMS: drag.left ? clip.fadeInMS : clip.fadeOutMS) }
            }
            fadeDrag = nil; fadedFragment = nil; didDragFade = false; refresh(); return
        }
        if let resize = fragmentResize {
            if !editor.busy {
                if didResizeFragment { updateFragmentResize(at: p, flags: event.modifierFlags) }
                if let clip = resizedFragment,
                   clip.start != resize.original.start || clip.duration != resize.original.duration,
                   let i = editor.project.tracks.firstIndex(where: { $0.clips.contains(where: { $0.id == clip.id }) }),
                   let j = editor.project.tracks[i].clips.firstIndex(where: { $0.id == clip.id }) {
                    editor.checkpoint(); editor.project.tracks[i].clips[j] = clip
                }
            }
            if let clip = resizedFragment, clip.start == resize.original.start, clip.duration == resize.original.duration,
               let id = pendingFragmentClick { editor.selection = [id] }
            fragmentResize = nil; resizedFragment = nil; pendingFragmentClick = nil; didResizeFragment = false; lastFragmentDragPoint = nil; editor.update(); return
        }
        if marqueeAnchor != nil {
            guard canSelectRange else { cancelMarqueeSelection(); return }
            if marqueeRect == nil {
                editor.selection = marqueeAdditive ? marqueeInitialSelection : []
                if event.clickCount == 2 { editor.range = nil }
                clearMarquee()
                editor.seek(to: max(0, (p.x - header) / editor.zoom))
            } else {
                updateMarquee(to: p); clearMarquee()
            }
            return
        }
        if selectingRange {
            if canSelectRange && !didDragRange && rangeAnchor == nil {
                if event.clickCount == 2 { editor.range = nil }
                editor.seek(to: max(0, (p.x - header) / editor.zoom))
            }
            selectingRange = false; rangeAnchor = nil; didDragRange = false
            return
        }
        var renameID: UUID?
        if let id = pendingTrackRename, hypot(p.x - dragStart.x, p.y - dragStart.y) <= 4,
           isTrackPoint(p), row >= 0, row < rows.count, rows[row].0.id == id, trackNameHitRect(row: row, depth: rows[row].1).contains(p) {
            renameID = id
        }
        if trackDragRows != nil {
            // Resolve against the unchanged drag baseline, never the reordered preview.
            previewTrackMove(at: p)
            let preview = trackPreview
            trackPreview = nil; trackDragRows = nil
            if let preview, !editor.busy, (try? TrackHierarchy.validate(preview)) != nil,
               preview.map({ $0.id }) != editor.project.tracks.map({ $0.id }) || preview.map({ $0.parent }) != editor.project.tracks.map({ $0.parent }) {
                editor.checkpoint(); editor.project.tracks = preview; editor.update("Track hierarchy updated")
            }
            refresh()
        }
        if dragClip != nil, didCheckpoint, !editor.busy { updateFragmentMove(at: p, flags: event.modifierFlags) }
        if dragClip != nil, didCheckpoint, !editor.busy, copyingFragments {
            var copies = Set<UUID>()
            for original in movingFragments.sorted(by: { $0.clip.order < $1.clip.order }) {
                if var copy = fragmentCopyPreviews[original.clip.id], let destination = fragmentDestinations[original.clip.id],
                   let index = editor.project.tracks.firstIndex(where: { $0.id == destination }) {
                    copy.order = editor.project.nextOrder; editor.project.nextOrder += 1
                    editor.project.tracks[index].clips.append(copy); copies.insert(copy.id)
                }
            }
            editor.selection = copies; editor.selectedTrack = dragDestination ?? dragTrack; editor.update()
        } else if dragClip != nil, didCheckpoint, !editor.busy {
            var transfers: [(UUID, Clip)] = []
            for i in editor.project.tracks.indices {
                let source = editor.project.tracks[i].id
                for clip in editor.project.tracks[i].clips {
                    if let destination = fragmentDestinations[clip.id], destination != source { transfers.append((destination, clip)) }
                }
                editor.project.tracks[i].clips.removeAll { fragmentDestinations[$0.id].map { $0 != source } == true }
            }
            for (destination, clip) in transfers {
                if let i = editor.project.tracks.firstIndex(where: { $0.id == destination }) { editor.project.tracks[i].clips.append(clip) }
            }
            editor.selectedTrack = dragDestination ?? dragTrack; editor.update()
        }
        // Wait for mouse-up to distinguish a plain click from a group drag.
        if !didCheckpoint, let id = pendingShiftFragmentClick { editor.selection.remove(id); editor.update() }
        else if !didCheckpoint, let id = pendingFragmentClick { editor.selection = [id]; editor.update() }
        pendingFragmentClick = nil; pendingShiftFragmentClick = nil; lastFragmentDragPoint = nil
        if copyingFragments { NSCursor.arrow.set() }
        copyingFragments = false; fragmentCopyPreviews = [:]
        dragClip = nil; dragTrack = nil; dragDestination = nil; fragmentSnapTime = nil; movingFragments = []; fragmentDestinations = [:]
        trackDrag = nil; pendingTrackRename = nil; selectingRange = false
        needsDisplay = true
        if let renameID { renameTrack(renameID) }
    }
    func centerOnPlayhead() {
        guard let scroll = enclosingScrollView else { return }
        let width = scroll.contentSize.width
        let x = header + editor.cursor * editor.zoom
        var origin = x - header - (width - header) / 2
        origin = min(max(0, frame.width - width), max(0, origin))
        scroll.contentView.scroll(to: NSPoint(x: origin, y: scroll.contentView.bounds.minY))
        scroll.reflectScrolledClipView(scroll.contentView)
    }
    func movePlayhead(direction: Double) {
        guard canSelectRange else { return }
        let visible = visibleRect
        let fragmentWidth = max(0, visible.width - header)
        guard fragmentWidth > 0 else { return }
        let step = Double(fragmentWidth) / editor.zoom * 0.01
        let position = editor.player?.currentTime ?? editor.cursor
        editor.seek(to: position + direction * step)
        centerOnPlayhead()
    }
    func beginShuttle(direction: Double) {
        guard canSelectRange else { return }
        editor.beginShuttle(direction: direction)
        centerOnPlayhead()
    }
    func seekBoundary(end: Bool) {
        guard canSelectRange else { return }
        editor.seek(to: end ? editor.duration : 0)
        centerOnPlayhead()
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 1 && event.modifierFlags.intersection([.command, .shift, .control, .option]).isEmpty { editor.split() }
        else if event.keyCode == 45 && event.modifierFlags.intersection([.command, .shift, .control, .option]).isEmpty { NSApp.sendAction(#selector(AppDelegate.normalize), to: NSApp.delegate, from: self) }
        else if event.keyCode == 123 { if event.modifierFlags.contains(.command) { seekBoundary(end: false) } else { beginShuttle(direction: -1) } }
        else if event.keyCode == 124 { if event.modifierFlags.contains(.command) { seekBoundary(end: true) } else { beginShuttle(direction: 1) } }
        else if event.keyCode == 126 { NSApp.sendAction(#selector(AppDelegate.zoomIn), to: NSApp.delegate, from: self) }
        else if event.keyCode == 125 { NSApp.sendAction(#selector(AppDelegate.zoomOut), to: NSApp.delegate, from: self) }
        else if event.keyCode == 36 || event.keyCode == 76 { editor.restartFromLastStart() }
        else if event.keyCode == 49 { editor.playPause() }
        else if event.keyCode == 51 || event.keyCode == 117 { editor.deleteClips() }
        else { super.keyDown(with: event) }
    }
    override func keyUp(with event: NSEvent) {
        if event.keyCode == 123 || event.keyCode == 124 { editor.releaseShuttle(); centerOnPlayhead() }
        else { super.keyUp(with: event) }
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        guard !editor.busy else { return nil }
        let p = convert(event.locationInWindow, from: nil); let row = Int((p.y - ruler) / rowHeight)
        guard isTrackPoint(p), row >= 0 else { return nil }
        if row >= rows.count {
            guard p.x >= 0, p.x < fragmentLeft else { return nil }
            let menu = NSMenu()
            let item = NSMenuItem(title: "Add track", action: #selector(addTrack), keyEquivalent: "")
            item.target = self; menu.addItem(item)
            return menu
        }
        if p.x >= fragmentLeft {
            let clips = rows[row].0.clips.sorted { $0.order < $1.order }
            for (layer, clip) in clips.enumerated().reversed() {
                let overlaps = clips.prefix(layer).filter { $0.start < clip.end && $0.end > clip.start }.count
                let rect = clipRect(clip, row: row, layer: overlaps)
                let fadeHit = editor.selection.contains(clip.id) && fragmentFadeHandleRects(clip, in: rect).contains(where: { $0.contains(p) })
                guard rect.contains(p) || fadeHit else { continue }
                if editor.selection.contains(clip.id) {
                    let areas = fragmentFadeRects(clip, in: rect), corners = fragmentFadeHandleRects(clip, in: rect)
                    let hits = areas.indices.filter { areas[$0].contains(p) || corners[$0].contains(p) }
                    if let edge = hits.min(by: { abs(p.x - ($0 == 0 ? rect.minX : rect.maxX)) < abs(p.x - ($1 == 0 ? rect.minX : rect.maxX)) }) {
                        return fadeCurveMenu(clip, left: edge == 0)
                    }
                }
                editor.selectedTrack = rows[row].0.id
                if !editor.selection.contains(clip.id) { editor.selection = [clip.id] }
                editor.update()
                let menu = NSMenu(); menu.autoenablesItems = false
                for (title, action, enabled) in [
                    ("Edit…", #selector(editFragment(_:)), true),
                    ("Move up", #selector(moveFragmentUp(_:)), editor.canMoveFragmentLayers(editor.selection, up: true)),
                    ("Move down", #selector(moveFragmentDown(_:)), editor.canMoveFragmentLayers(editor.selection, up: false)),
                    ("Normalize…", #selector(normalizeFragments(_:)), true),
                    (editor.fragmentsAreMuted(editor.selection) ? "Unmute" : "Mute", #selector(muteFragments(_:)), true),
                    ("Delete", #selector(deleteFragment(_:)), true)] {
                    let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
                    item.target = self
                    if action == #selector(editFragment(_:)) { item.representedObject = clip.id } else { item.representedObject = editor.selection }
                    item.isEnabled = enabled; menu.addItem(item)
                }
                return menu
            }
            return nil
        }
        editor.selectedTrack = rows[row].0.id; editor.update()
        let menu = NSMenu()
        for (title, action) in [("Track effects…", #selector(effects)), ("Add nested track", #selector(nest)), ("Move to root", #selector(unparent)), ("Delete track…", #selector(remove))] { let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; menu.addItem(item) }
        return menu
    }
    @objc func editFragment(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? UUID { (NSApp.delegate as? AppDelegate)?.editFragment(id) }
    }
    @objc func moveFragmentUp(_ sender: NSMenuItem) { if let ids = sender.representedObject as? Set<UUID> { editor.moveFragmentLayers(ids, up: true) } }
    @objc func moveFragmentDown(_ sender: NSMenuItem) { if let ids = sender.representedObject as? Set<UUID> { editor.moveFragmentLayers(ids, up: false) } }
    @objc func normalizeFragments(_ sender: NSMenuItem) {
        guard !editor.busy, let ids = sender.representedObject as? Set<UUID> else { return }
        editor.selection = ids; NSApp.sendAction(#selector(AppDelegate.normalize), to: NSApp.delegate, from: sender)
    }
    @objc func muteFragments(_ sender: NSMenuItem) {
        if let ids = sender.representedObject as? Set<UUID> { editor.toggleFragmentMute(ids) }
    }
    @objc func deleteFragment(_ sender: NSMenuItem) {
        guard !editor.busy, let ids = sender.representedObject as? Set<UUID> else { return }
        editor.selection = ids; editor.deleteClips()
    }
    @objc func effects() { if let id = editor.selectedTrack { EffectsWindow(editor: editor, trackID: id).run() } }
    @objc func addTrack() { editor.addTrack() }
    @objc func nest() { editor.addTrack(nested: true) }
    @objc func unparent() { if let id = editor.selectedTrack { editor.reparent(id, to: nil) } }
    @objc func remove() { editor.removeTrack() }
}
