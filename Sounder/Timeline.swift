import AppKit
import QuartzCore
import CoreText

final class MixerFXButton: PointerButton {
    static let controlWidth: CGFloat = 54
    static let trackControlWidth: CGFloat = 48
    let power = PointerButton(title: "", target: nil, action: nil)
    override init(frame: NSRect) {
        super.init(frame: frame)
        power.image = NSImage(systemSymbolName: "power", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 10, weight: .regular))
        power.imagePosition = .imageOnly; power.isBordered = false
        power.setButtonType(.pushOnPushOff); power.activeAppearanceColor = .systemGreen
        power.contentTintColor = .secondaryLabelColor
        power.target = self; power.action = #selector(toggleEffects)
        addSubview(power)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        positionPower()
    }
    override func layout() { super.layout(); positionPower() }
    private func positionPower() {
        power.frame = NSRect(x: bounds.maxX - 18, y: bounds.midY - 9, width: 18, height: 18)
    }
    private weak var editor: Editor?
    private var trackID: UUID?
    private var hasActiveEffects = false { didSet { if oldValue != hasActiveEffects { needsDisplay = true } } }
    private var hasEffects = false { didSet { if oldValue != hasEffects { needsDisplay = true } } }
    private var effectColor = accent { didSet { if oldValue != effectColor { needsDisplay = true } } }
    func configure(editor: Editor, track: Track, color: NSColor) {
        if self.editor !== editor || trackID != track.id {
            self.editor = editor; trackID = track.id
            title = "FX"; font = .systemFont(ofSize: 9, weight: .semibold); isBordered = false
            target = self; action = #selector(openEffects)
        }
        setAccessibilityLabel("\(track.name) effects")
        if isEnabled != editor.canEditEffects { isEnabled = editor.canEditEffects }
        hasEffects = !track.effects.isEmpty; effectColor = color
        let active = !track.effectsBypassed && track.effects.contains { !$0.bypassed }
        hasActiveEffects = active
        let caption = hasEffects ? "FX  •" : "FX"
        if title != caption { title = caption; needsDisplay = true }
        power.state = active ? .on : .off
        power.isEnabled = editor.canToggleEffects && hasEffects
        power.toolTip = active ? "Выключить все эффекты" : "Включить все эффекты"
        power.setAccessibilityLabel((power.toolTip ?? "") + " · " + track.name)
        positionPower()
    }
    @objc private func openEffects() {
        guard let editor, let trackID else { return }
        editor.showEffects(for: trackID)
    }
    @objc private func toggleEffects() {
        guard let editor, let trackID else { return }
        editor.toggleAllEffects(for: trackID)
    }
    override var intrinsicContentSize: NSSize { NSSize(width: Self.controlWidth, height: 20) }
    private static func drawFace(in rect: NSRect, title: String, active: Bool, color: NSColor, hovered: Bool, flipped: Bool) {
        fill(rect, active ? color.withAlphaComponent(0.18) : NSColor.white.withAlphaComponent(0.06), radius: 5)
        if hovered {
            fill(rect, NSColor.white.withAlphaComponent(0.10), radius: 5)
            NSColor.white.withAlphaComponent(0.16).setStroke()
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.4, dy: 0.4), xRadius: 5, yRadius: 5)
            path.lineWidth = 0.7; path.stroke()
        }
        centeredControlLabel(title, NSRect(x: rect.minX, y: rect.minY, width: max(0, rect.width - 18), height: rect.height), size: 9,
                             color: active ? color : .secondaryLabelColor, flipped: flipped)
    }
    override func draw(_ dirtyRect: NSRect) {
        Self.drawFace(in: bounds, title: title, active: hasActiveEffects, color: effectColor,
                      hovered: isEnabled && window?.isKeyWindow == true && isHovering, flipped: isFlipped)
    }
}

final class TrackVolumeMeterCell: NSSliderCell {
    var levels = [0.0, 0.0]
    var recording = false
    var usesLayerMeter = false
    private(set) var knobDrawCount = 0
    private var animationFrom: Double?
    private var animationStart = 0.0
    private var animationTimer: Timer?
    var displayedValue: Double {
        guard let from = animationFrom else { return doubleValue }
        let t = min(1, max(0, (ProcessInfo.processInfo.systemUptime - animationStart) / 0.18))
        let eased = t * t * (3 - 2 * t)
        return from + (doubleValue - from) * eased
    }
    func animateRailClick() {
        let from = displayedValue
        cancelKnobAnimation()
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        animationFrom = from; animationStart = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            if ProcessInfo.processInfo.systemUptime - self.animationStart >= 0.18 { self.cancelKnobAnimation() }
            self.controlView?.needsDisplay = true
            (self.controlView as? TrackMixerSlider)?.refreshValuePresentation()
        }
        animationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .eventTracking)
    }
    func cancelKnobAnimation() {
        animationTimer?.invalidate(); animationTimer = nil; animationFrom = nil
        controlView?.needsDisplay = true
    }
    override func continueTracking(last lastPoint: NSPoint, current currentPoint: NSPoint, in controlView: NSView) -> Bool {
        if hypot(currentPoint.x - lastPoint.x, currentPoint.y - lastPoint.y) > 1 { cancelKnobAnimation() }
        return super.continueTracking(last: lastPoint, current: currentPoint, in: controlView)
    }
    func displayedKnobRect(flipped: Bool) -> NSRect {
        let rail = barRect(flipped: flipped)
        let fraction = max(0, min(1, (displayedValue - minValue) / (maxValue - minValue)))
        let x = rail.minX + 4 + max(0, rail.width - 8) * fraction
        return NSRect(x: x - 4, y: knobRect(flipped: flipped).midY - 7, width: 8, height: 14)
    }
    override func drawKnob(_ knobRect: NSRect) {
        knobDrawCount += 1
        // Preserve native tracking and its generous hit target, but let the
        // narrow visible thumb reach both rail edges instead of retaining the
        // inset reserved for the much wider system thumb.
        super.drawKnob(displayedKnobRect(flipped: controlView?.isFlipped ?? false))
    }
    deinit { animationTimer?.invalidate() }
    func fraction(_ amplitude: Double) -> Double {
        max(0, min(1, (TrackLevelMeter.decibels(amplitude) - minValue) / (maxValue - minValue)))
    }
    func meterEndX(_ amplitude: Double, inside rect: NSRect, flipped: Bool) -> CGFloat {
        let amount = fraction(amplitude)
        guard amount > 0 else { return rect.minX }
        let inset: CGFloat = 4
        return rect.minX + inset + max(0, rect.width - 2 * inset) * amount
    }
    override func drawBar(inside rect: NSRect, flipped: Bool) {
        guard !usesLayerMeter else { return }
        let rail = NSRect(x: rect.minX, y: rect.midY - 3, width: rect.width, height: 6)
        fill(rail, NSColor.white.withAlphaComponent(0.16), radius: 3)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: rail, xRadius: 3, yRadius: 3).addClip()
        let color = recording ? NSColor.systemRed : accent
        for channel in 0..<2 {
            let top = flipped ? channel : 1 - channel
            fill(NSRect(x: rail.minX, y: rail.minY + CGFloat(top) * 3.5, width: meterEndX(levels[channel], inside: rail, flipped: flipped) - rail.minX, height: 2.5), color)
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// Signal changes resize only these cheap layers, never redraw the native thumb.
/// Kept behind the transparent slider so tracking, focus and accessibility stay native.
final class MixerMeterRail: NSView {
    private let rail = CALayer()
    private let fills = [CALayer(), CALayer()]
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(rail)
        rail.cornerRadius = 3; rail.masksToBounds = true; rail.isGeometryFlipped = true
        rail.backgroundColor = NSColor.white.withAlphaComponent(0.16).cgColor
        fills.forEach { rail.addSublayer($0) }
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    func update(cell: TrackVolumeMeterCell, flipped: Bool) {
        let bar = cell.barRect(flipped: flipped)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        rail.frame = NSRect(x: bar.minX, y: bar.midY - 3, width: bar.width, height: 6)
        let color = (cell.recording ? NSColor.systemRed : accent).cgColor
        for channel in 0..<2 {
            fills[channel].backgroundColor = color
            // The layer's coordinates are explicitly top-down: L above R.
            fills[channel].frame = NSRect(x: 0, y: CGFloat(channel) * 3.5,
                width: max(0, cell.meterEndX(cell.levels[channel], inside: bar, flipped: flipped) - bar.minX), height: 2.5)
        }
        CATransaction.commit()
    }
}

/// The pan thumb mirrors the volume thumb's 8×14 pt proportions, rotated.
/// Native geometry still supplies tracking, animation and accessibility.
final class TrackPanSliderCell: NSSliderCell {
    private static let thumbSize = NSSize(width: 14, height: 8)
    override func drawBar(inside rect: NSRect, flipped: Bool) {
        // Native travel reserves space for a taller thumb. Trim only the
        // painted rail to the visible thumb's endpoints, preserving tracking.
        let inset = max(0, (knobRect(flipped: flipped).height - Self.thumbSize.height) / 2)
        super.drawBar(inside: rect.insetBy(dx: 0, dy: inset), flipped: flipped)
    }
    override func drawKnob(_ knobRect: NSRect) {
        super.drawKnob(NSRect(x: knobRect.midX - Self.thumbSize.width / 2, y: knobRect.midY - Self.thumbSize.height / 2,
                             width: Self.thumbSize.width, height: Self.thumbSize.height))
    }
}

final class TrackMixerSlider: NSSlider {
    private(set) var trackingGesture = false
    var checkpointed = false
    var valueText: ((Double) -> String)?
    private var valuePanel: NSPanel?
    private let valueLabel = NSTextField(labelWithString: "")
    private var valueTrackingArea: NSTrackingArea?
    private var resignKeyObserver: NSObjectProtocol?
    var visibleValueText: String? { valuePanel?.isVisible == true ? valueLabel.stringValue : nil }
    var visibleValueFrame: NSRect? { valuePanel?.isVisible == true ? valuePanel?.frame : nil }
    private func showValue() {
        guard let window, let valueText else { return }
        if valuePanel == nil {
            let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false; panel.isOpaque = false; panel.backgroundColor = .clear
            panel.hasShadow = true; panel.ignoresMouseEvents = true; panel.hidesOnDeactivate = true
            panel.level = .popUpMenu; panel.collectionBehavior = [.transient, .ignoresCycle]
            let content = NSView(); content.wantsLayer = true
            content.layer?.backgroundColor = panelColor.cgColor; content.layer?.cornerRadius = 7
            content.layer?.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor; content.layer?.borderWidth = 1
            valueLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            valueLabel.textColor = .labelColor; valueLabel.alignment = .center
            content.addSubview(valueLabel); panel.contentView = content; valuePanel = panel
        }
        guard let panel = valuePanel else { return }
        valueLabel.stringValue = valueText(doubleValue); valueLabel.sizeToFit()
        let size = NSSize(width: max(50, valueLabel.frame.width + 18), height: 27)
        let rect = window.convertToScreen(convert(bounds, to: nil))
        let displayedValue = (cell as? TrackVolumeMeterCell)?.displayedValue ?? doubleValue
        let fraction = max(0, min(1, (displayedValue - minValue) / (maxValue - minValue)))
        var origin: NSPoint
        if isVertical {
            // The rectangle is already in screen coordinates, where Y grows
            // upward regardless of the slider view's flipped coordinate system.
            let y = rect.minY + 7 + (rect.height - 14) * fraction
            origin = NSPoint(x: rect.minX - size.width - 6, y: y - size.height / 2)
        } else {
            let x: CGFloat
            if let cell = cell as? TrackVolumeMeterCell {
                let thumb = window.convertToScreen(convert(cell.displayedKnobRect(flipped: isFlipped), to: nil))
                x = thumb.midX
            } else { x = rect.minX + 7 + (rect.width - 14) * fraction }
            origin = NSPoint(x: x - size.width / 2, y: rect.maxY + 5)
        }
        if let screen = window.screen?.visibleFrame {
            origin.x = max(screen.minX + 5, min(screen.maxX - size.width - 5, origin.x))
            origin.y = max(screen.minY + 5, min(screen.maxY - size.height - 5, origin.y))
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: false)
        valueLabel.frame = NSRect(x: 9, y: (size.height - valueLabel.frame.height) / 2, width: size.width - 18, height: valueLabel.frame.height)
        if panel.parent !== window { panel.parent?.removeChildWindow(panel); window.addChildWindow(panel, ordered: .above) }
        panel.orderFront(nil); panel.displayIfNeeded()
    }
    private func hideValue() {
        valuePanel?.orderOut(nil)
        if let panel = valuePanel { panel.parent?.removeChildWindow(panel) }
    }
    func refreshValuePresentation() {
        // Layout/tracking-area updates can deliver stale enter events without
        // a matching exit. Always check this slider's actual current hit area.
        if isEnabled, !isHiddenOrHasHiddenAncestor, window?.isKeyWindow == true, pointerIsInside || trackingGesture { showValue() }
        else { hideValue() }
    }
    private var pointerIsInside: Bool {
        guard let window, window.isKeyWindow, !isHiddenOrHasHiddenAncestor else { return false }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        return bounds.contains(point) && visibleRect.contains(point)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let valueTrackingArea { removeTrackingArea(valueTrackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect, .enabledDuringMouseDrag], owner: self)
        addTrackingArea(area); valueTrackingArea = area
        refreshValuePresentation()
    }
    override func mouseEntered(with event: NSEvent) {
        refreshValuePresentation()
    }
    override func mouseExited(with event: NSEvent) {
        refreshValuePresentation()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let resignKeyObserver { NotificationCenter.default.removeObserver(resignKeyObserver) }
        resignKeyObserver = window.map { window in
            NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                self?.hideValue()
            }
        }
    }
    deinit { if let resignKeyObserver { NotificationCenter.default.removeObserver(resignKeyObserver) } }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { hideValue(); (cell as? TrackVolumeMeterCell)?.cancelKnobAnimation() }
        super.viewWillMove(toWindow: newWindow)
    }
    override func sendAction(_ action: Selector?, to target: Any?) -> Bool {
        let sent = super.sendAction(action, to: target)
        refreshValuePresentation()
        return sent
    }
    func withTrackingGesture(_ action: () -> Void) {
        trackingGesture = true; checkpointed = false
        showValue()
        defer { trackingGesture = false; checkpointed = false; refreshValuePresentation() }
        action()
    }
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        if let cell = cell as? TrackVolumeMeterCell {
            let point = convert(event.locationInWindow, from: nil)
            if event.clickCount == 1 && !cell.knobRect(flipped: isFlipped).contains(point) { cell.animateRailClick() }
            else { cell.cancelKnobAnimation() }
        }
        withTrackingGesture {
            if event.clickCount == 2 {
                doubleValue = 0
                _ = sendAction(action, to: target)
            } else { super.mouseDown(with: event) }
        }
    }
}

/// Shared post-fader stereo meter, native volume control and peak readouts.
final class MixerVolumeControl: NSView {
    static let peakReadoutWidth: CGFloat = 46
    private static let railReadoutGap: CGFloat = 2
    let slider = TrackMixerSlider(value: 0, minValue: -60, maxValue: 12, target: nil, action: nil)
    let peakReadout = MixerPeakReadout(frame: .zero)
    private let meterRail = MixerMeterRail(frame: .zero)
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        let cell = TrackVolumeMeterCell(); cell.minValue = -60; cell.maxValue = 12; cell.doubleValue = 0
        cell.usesLayerMeter = true
        slider.cell = cell; slider.controlSize = .mini; slider.isContinuous = true
        slider.wantsLayer = true
        slider.valueText = { $0 <= -60 ? "−∞ dB" : String(format: "%+.1f dB", $0) }
        addSubview(meterRail); addSubview(slider); addSubview(peakReadout)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        slider.frame = NSRect(x: 0, y: bounds.midY - 9, width: max(24, bounds.width - Self.peakReadoutWidth - Self.railReadoutGap), height: 18)
        meterRail.frame = slider.frame
        if let cell = slider.cell as? TrackVolumeMeterCell { meterRail.update(cell: cell, flipped: slider.isFlipped) }
        peakReadout.frame = NSRect(x: bounds.maxX - Self.peakReadoutWidth, y: bounds.midY - 11, width: Self.peakReadoutWidth, height: 22)
    }
    func configure(track: Track, meter: StereoTrackLevelMeter, active: Bool, recording: Bool, enabled: Bool, showsPeaks: Bool) {
        if !slider.trackingGesture && slider.doubleValue != track.volumeDB { slider.doubleValue = track.volumeDB }
        if slider.isEnabled != enabled { slider.isEnabled = enabled }
        slider.setAccessibilityLabel("\(track.name) volume")
        slider.refreshValuePresentation()
        updateMeter(meter, active: active, recording: recording, showsPeaks: showsPeaks)
    }
    func updateMeter(_ meter: StereoTrackLevelMeter, active: Bool, recording: Bool, showsPeaks: Bool) {
        peakReadout.update(meter, visible: active && showsPeaks)
        if let cell = slider.cell as? TrackVolumeMeterCell {
            let levels = active ? [meter.left.level, meter.right.level] : [0, 0]
            if cell.recording != recording || cell.levels != levels {
                cell.recording = recording; cell.levels = levels
                meterRail.update(cell: cell, flipped: slider.isFlipped)
            }
        }
    }
}

/// Each channel retains its last text while fading, including when its track
/// ends before the rest of the project. Repeated silent polls do not restart it.
final class MixerPeakReadout: NSView {
    let channels = [MixerPeakChannelReadout(frame: .zero), MixerPeakChannelReadout(frame: .zero)]
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        channels.forEach { addSubview($0) }
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func layout() {
        super.layout()
        for (index, channel) in channels.enumerated() {
            channel.frame = NSRect(x: 0, y: CGFloat(index) * 11, width: bounds.width, height: 11)
        }
    }
    func update(_ meter: StereoTrackLevelMeter, visible: Bool) {
        for (index, value) in [meter.left, meter.right].enumerated() {
            channels[index].update(value, suffix: index == 0 ? " L" : " R", visible: visible && value.peak > 0)
        }
    }
}

final class MixerPeakChannelReadout: NSView {
    private var text = ""
    private var color = accent
    private var visible = false
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true; layer?.opacity = 0
    }
    required init?(coder: NSCoder) { fatalError() }
    func update(_ value: TrackLevelMeter, suffix: String, visible: Bool) {
        if visible {
            let db = TrackLevelMeter.decibels(value.peak)
            let nextColor: NSColor = db >= -1 ? .systemRed : db >= -6 ? .systemYellow : accent
            let nextText = value.peakText + suffix
            if text != nextText || color != nextColor { text = nextText; color = nextColor; needsDisplay = true }
        }
        guard self.visible != visible else { return }
        self.visible = visible
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer?.removeAnimation(forKey: "stopFade")
        layer?.opacity = visible ? 1 : 0
        if !visible {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1; fade.toValue = 0; fade.duration = 1
            layer?.add(fade, forKey: "stopFade")
        }
        CATransaction.commit()
    }
    override func draw(_ dirtyRect: NSRect) {
        label(text, bounds, size: 8, color: color, weight: .medium, alignment: .right)
    }
}

/// Native sliders keep keyboard and accessibility support. The clipped holder
/// follows the pinned sidebar while the document scrolls underneath it.
final class TrackRecordButton: PointerButton {
    override func draw(_ dirtyRect: NSRect) {
        let active = state == .on
        fill(bounds, active ? NSColor.systemRed.withAlphaComponent(0.3) : NSColor.white.withAlphaComponent(0.06), radius: 5)
        if isEnabled && isHovering && window?.isKeyWindow == true {
            fill(bounds, NSColor.white.withAlphaComponent(0.10), radius: 5)
        }
        centeredControlLabel("REC", bounds, size: 9, color: active ? .systemRed : .secondaryLabelColor, flipped: isFlipped)
    }
}

final class TrackMixerControls: NSView {
    let volumeControl = MixerVolumeControl(frame: .zero)
    var volume: TrackMixerSlider { volumeControl.slider }
    let pan = TrackMixerSlider(value: 0, minValue: -90, maxValue: 90, target: nil, action: nil)
    let fx = MixerFXButton(title: "FX", target: nil, action: nil)
    let rec = TrackRecordButton(title: "REC", target: nil, action: nil)
    let trackID: UUID
    private weak var editor: Editor?
    override var isFlipped: Bool { true }
    init(track: Track, editor: Editor) {
        trackID = track.id; self.editor = editor
        super.init(frame: .zero)
        wantsLayer = true; layer?.masksToBounds = true
        addSubview(volumeControl); addSubview(pan); addSubview(fx); addSubview(rec)
        rec.setButtonType(.pushOnPushOff); rec.isBordered = false
        rec.activeAppearanceColor = .systemRed; rec.target = self; rec.action = #selector(toggleRecord)
        let panCell = TrackPanSliderCell(); panCell.minValue = -90; panCell.maxValue = 90; panCell.doubleValue = 0
        pan.cell = panCell
        pan.controlSize = .mini; pan.isContinuous = true; pan.target = self; pan.trackFillColor = accent
        volume.target = self
        volume.action = #selector(changeVolume); pan.action = #selector(changePan)
        pan.valueText = { $0 == 0 ? "Center" : String(format: "%@ %.0f°", $0 > 0 ? "Left" : "Right", abs($0)) }
        pan.isVertical = true
        if #available(macOS 26.0, *) { pan.neutralValue = 0 }
        pan.numberOfTickMarks = 0; pan.allowsTickMarkValuesOnly = false
        configure(track)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let result = super.hitTest(point)
        return result === self ? nil : result
    }
    func configure(_ track: Track, color: NSColor = accent) {
        if !pan.trackingGesture && pan.doubleValue != -track.pan { pan.doubleValue = -track.pan }
        let enabled = editor?.canAdjustTrackMix == true
        if pan.isEnabled != enabled { pan.isEnabled = enabled }
        pan.setAccessibilityLabel("\(track.name) Pan")
        pan.refreshValuePresentation()
        if let editor {
            fx.configure(editor: editor, track: track, color: color)
            rec.state = track.recordArmed ? .on : .off; rec.isEnabled = editor.canArmTracks
            rec.toolTip = track.recordArmed ? "Disarm recording" : "Arm recording"
            rec.setAccessibilityLabel("\(track.name) REC")
            let meter = editor.displayedTrackMeter(track)
            let active = editor.isMeteringAudio
            volumeControl.configure(track: track, meter: meter, active: active, recording: editor.recording(for: track.id) != nil,
                                    enabled: editor.canAdjustTrackMix, showsPeaks: editor.showsTrackMeter(track.id))
        }
    }
    private func change(_ slider: TrackMixerSlider, isPan: Bool) {
        guard let editor else { return }
        let value = ((isPan ? -slider.doubleValue : slider.doubleValue) * 10).rounded() / 10
        if editor.setTrackMix(trackID, volumeDB: isPan ? nil : value, pan: isPan ? value : nil,
                              checkpoint: !slider.trackingGesture || !slider.checkpointed) {
            slider.checkpointed = true
        }
    }
    @objc private func toggleRecord() { editor?.toggleRecordArm(trackID) }
    @objc private func changeVolume(_ sender: TrackMixerSlider) { change(sender, isPan: false) }
    @objc private func changePan(_ sender: TrackMixerSlider) { change(sender, isPan: true) }
}

let background = NSColor(calibratedRed: 0.055, green: 0.065, blue: 0.085, alpha: 1)
let panelColor = NSColor(calibratedRed: 0.085, green: 0.10, blue: 0.13, alpha: 1)
let accent = NSColor(calibratedRed: 0.40, green: 0.88, blue: 0.75, alpha: 1)
let trackColors: [NSColor] = [accent, .init(calibratedRed: 0.57, green: 0.62, blue: 0.98, alpha: 1), .init(calibratedRed: 0.94, green: 0.67, blue: 0.41, alpha: 1), .init(calibratedRed: 0.82, green: 0.53, blue: 0.81, alpha: 1)]
func label(_ text: String, _ rect: NSRect, size: CGFloat = 12, color: NSColor = .labelColor, weight: NSFont.Weight = .regular, alignment: NSTextAlignment = .left) {
    let style = NSMutableParagraphStyle(); style.lineBreakMode = .byTruncatingTail; style.alignment = alignment
    (text as NSString).draw(in: rect, withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: style])
}
/// Center actual glyph ink instead of a text container with unused leading.
func centeredControlLabel(_ text: String, _ rect: NSRect, size: CGFloat, color: NSColor, flipped: Bool) {
    guard let context = NSGraphicsContext.current?.cgContext else { return }
    let text = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: size, weight: .semibold),
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): color.cgColor])
    let textLine = CTLineCreateWithAttributedString(text)
    let ink = CTLineGetImageBounds(textLine, nil)
    context.saveGState()
    context.translateBy(x: rect.midX, y: rect.midY)
    if flipped { context.scaleBy(x: 1, y: -1) }
    context.textMatrix = .identity
    context.textPosition = CGPoint(x: -ink.midX, y: -ink.midY)
    CTLineDraw(textLine, context)
    context.restoreGState()
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

/// Keep AppKit geometry stationary. Only child layers move at display cadence;
/// moving an NSView makes AppKit rebuild tracking regions and reset the cursor.
private final class TransportPlayheadView: NSView {
    private let viewportLayer = CALayer()
    private let stem = CALayer()
    private let cap = CALayer()
    private(set) var markerFrame = NSRect.zero
    var markerIsHidden: Bool { viewportLayer.isHidden }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {} // Layer-only surface: never allocate a document-sized bitmap.
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.isGeometryFlipped = true
        layer?.addSublayer(viewportLayer)
        viewportLayer.masksToBounds = true
        viewportLayer.addSublayer(stem); viewportLayer.addSublayer(cap)
        cap.cornerRadius = 2
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    func present(x: CGFloat, viewport: NSRect, color: NSColor, visible: Bool) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if let document = superview, frame != document.bounds { frame = document.bounds }
        viewportLayer.isHidden = !visible
        viewportLayer.frame = viewport
        markerFrame = NSRect(x: x - 5, y: viewport.minY, width: 10, height: viewport.height)
        stem.frame = NSRect(x: x - viewport.minX - 0.75, y: 0, width: 1.5, height: viewport.height)
        cap.frame = NSRect(x: x - viewport.minX - 4, y: 0, width: 8, height: 8)
        stem.backgroundColor = color.cgColor; cap.backgroundColor = color.cgColor
        CATransaction.commit()
    }
}

/// Transparent to the timeline except where it contains a native control.
/// This is a sibling of the scroll view, so scrolling the document does not
/// invalidate the geometry and tracking areas of every mixer control.
private final class TimelineControlsOverlay: NSView {
    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {}
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true; layer?.masksToBounds = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

/// Paint in document coordinates without moving the AppKit surface.
private final class TimelinePinnedSurface: NSView {
    var paint: ((NSRect) -> Void)?
    var documentOrigin = NSPoint.zero
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        let dirty = dirtyRect.intersection(bounds)
        guard !dirty.isEmpty, !dirty.isNull else { return }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: bounds).addClip()
        NSGraphicsContext.current?.cgContext.translateBy(x: -documentOrigin.x, y: -documentOrigin.y)
        paint?(dirty.offsetBy(dx: documentOrigin.x, dy: documentOrigin.y))
        NSGraphicsContext.restoreGraphicsState()
    }
}

final class Timeline: NSView {
    private let controlsOverlay = TimelineControlsOverlay(frame: .zero)
    private let scrollSurface = TimelineScrollSurface(frame: .zero)
    private var presentationOrigin: NSPoint?
    private let playheadView = TransportPlayheadView(frame: .zero)
    private let sidebarSurface = TimelinePinnedSurface(frame: .zero)
    private let rulerSurface = TimelinePinnedSurface(frame: .zero)
    private var presentingTransport = false
    private var previousRecordingRect: NSRect?
    private(set) var structureRefreshCount = 0
    private(set) var rasterBuildCount = 0
    private(set) var rasterHitCount = 0
    var usesFragmentRasterCache = true
    var pendingGraphicsJobs: Int { sourceJobs.count + waveformJobs.count }
    var playheadFrame: NSRect { playheadView.markerFrame.offsetBy(dx: viewportRect.minX, dy: viewportRect.minY) }
    var playheadSurfaceFrame: NSRect { playheadView.frame }
    var playheadIsHidden: Bool { playheadView.markerIsHidden }
    private struct RasterStyle: Equatable {
        let waveform: FragmentWaveformKey
        let name: String
        let zoom: Double
        let height: CGFloat
        let scale: CGFloat
        let colorIndex: Int
        let selected: Bool
        let dimmed: Bool
        let muted: Bool
        let processed: Bool
        let hasAudio: Bool
    }
    private var rasterStyles: [UUID: (RasterStyle, UUID)] = [:]
    private let fragmentRasters: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.totalCostLimit = 64 * 1024 * 1024; cache.countLimit = 256
        return cache
    }()

    private struct SourceDecodeKey: Hashable { let path: String; let rate: Double }
    private var sourceJobs: [SourceDecodeKey: Progress] = [:]
    private var failedSources = Set<SourceDecodeKey>()
    private func preparedAudio(for clip: Clip) -> AudioData? {
        if let data = editor.audio.cache[clip.source] { return data }
        let key = SourceDecodeKey(path: clip.source, rate: editor.audio.sampleRate)
        guard sourceJobs[key] == nil, !failedSources.contains(key) else { return nil }
        let cancellation = Progress(totalUnitCount: 1)
        sourceJobs[key] = cancellation
        waveformQueue.async { [weak self] in
            let result = Result { try AudioStore.decode(URL(fileURLWithPath: key.path), sampleRate: key.rate, isCancelled: { cancellation.isCancelled }) }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.sourceJobs.removeValue(forKey: key) != nil, !cancellation.isCancelled,
                      self.editor.audio.sampleRate == key.rate else { return }
                switch result {
                case .success(let data):
                    self.editor.audio.cache[key.path] = data
                    self.invalidateScrollTiles()
                    self.setNeedsDisplay(self.viewportRect)
                case .failure(let error):
                    self.failedSources.insert(key); self.editor.error(error)
                }
            }
        }
        return nil
    }
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
                    self.invalidateScrollTiles()
                    for (row, item) in self.rows.enumerated() {
                        guard let current = self.displayedClips(for: item.0).first(where: { $0.id == clip.id }) else { continue }
                        let dirty = NSRect(x: self.header + current.start * self.editor.zoom - 4,
                                           y: self.ruler + CGFloat(row) * self.rowHeight,
                                           width: current.duration * self.editor.zoom + 8, height: self.rowHeight).intersection(self.viewportRect)
                        if !dirty.isNull, !dirty.isEmpty { self.setNeedsDisplay(dirty) }
                    }
                }
            }
        }
        return nil
    }
    let editor: Editor
    let header: CGFloat = 220
    let rowHeight: CGFloat = 116 / 1.5
    private var trackVolumeY: CGFloat { rowHeight / 2 - 11 }
    private let trackButtonsY: CGFloat = 51
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
    private var lastRangeDragPoint: NSPoint?
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
    private var nativeViewportSize = NSSize.zero
    private var controlsTracking: NSTrackingArea?
    private(set) var mixerControls: [UUID: TrackMixerControls] = [:]
    private var followedPlayback = false
    private var lastPlaybackScrollRequest: UInt64 = 0
    private struct PlaybackScroll {
        static let duration = 1.0
        let startedAt: Double
        let origin: CGFloat
        func position(target: CGFloat, at time: Double) -> CGFloat {
            let t = min(1, max(0, (time - startedAt) / Self.duration))
            let blend = t * t * (3 - 2 * t)
            return origin + (target - origin) * blend
        }
    }
    private var playbackScroll: PlaybackScroll?
    private var steppingPausedCursor = false
    private var pausedScrollCursor: Double?
    var scrollAnimationChanged: (() -> Void)?
    var isEasingPlaybackScroll: Bool { playbackScroll != nil }
    private var hoveredTrackControl: (id: UUID, kind: Int)?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    init(_ editor: Editor) {
        self.editor = editor; super.init(frame: .zero)
        editor.captureTimelineView = { [weak self] in
            guard let self, self.enclosingScrollView != nil else { return nil }
            // Layer scrolling may be ahead of AppKit's native clip bounds.
            return TimelineViewState(zoom: self.editor.zoom, x: max(0, self.viewportRect.minX), y: max(0, self.viewportRect.minY))
        }
        registerForDraggedTypes(AudioFileDrop.types)
        controlsOverlay.addSubview(scrollSurface)
        controlsOverlay.addSubview(sidebarSurface); controlsOverlay.addSubview(rulerSurface)
        controlsOverlay.addSubview(playheadView); controlsOverlay.addSubview(nameField)
        scrollSurface.paint = { [weak self] rect, ruler in
            if ruler { self?.drawRulerContent(in: rect) } else { self?.draw(rect) }
        }
        sidebarSurface.paint = { [weak self] in self?.drawTrackHeaders(in: $0) }
        rulerSurface.paint = { [weak self] in self?.drawRuler(in: $0) }
        nameField.font = .systemFont(ofSize: 13, weight: .semibold)
        nameField.setAccessibilityLabel("Track name")
        nameField.textChanged = { [weak self] in self?.layoutNameField() }
    }
    /// Uses displayed document coordinates so pinned headers/rulers never accept audio.
    func audioDropDestination(at point: NSPoint, flags: NSEvent.ModifierFlags = []) -> (track: UUID?, start: Double)? {
        guard !editor.busy, viewportRect.contains(point), bounds.contains(point),
              point.x >= fragmentLeft, isTrackPoint(point) else { return nil }
        let row = Int((point.y - ruler) / rowHeight)
        let track = rows.indices.contains(row) ? rows[row].0.id : nil
        return (track, timelineTime(at: point, flags: flags))
    }
    private func audioDropOperation(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingSourceOperationMask.contains(.copy),
              audioDropDestination(at: documentPoint(fromWindow: sender.draggingLocation)) != nil,
              !AudioFileDrop.urls(from: sender.draggingPasteboard).isEmpty else { return [] }
        return .copy
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { audioDropOperation(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { audioDropOperation(sender) }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { audioDropOperation(sender) == .copy }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard audioDropOperation(sender) == .copy else { return false }
        synchronizeScrollPresentation()
        return importDroppedAudio(from: sender.draggingPasteboard, at: documentPoint(fromWindow: sender.draggingLocation),
                                  flags: NSApp.currentEvent?.modifierFlags ?? [])
    }
    @discardableResult func importDroppedAudio(from pasteboard: NSPasteboard, at point: NSPoint,
                                               flags: NSEvent.ModifierFlags = []) -> Bool {
        guard let destination = audioDropDestination(at: point, flags: flags) else { return false }
        let urls = AudioFileDrop.urls(from: pasteboard)
        guard !urls.isEmpty else { return false }
        var placement = AudioImportPlacement.singleTrack
        if urls.count > 1 {
            guard let chosen = ImportPlacementDialog().runModal() else { return false }
            placement = chosen
        }
        editor.importAudio(urls: urls, placement: placement, destination: destination)
        return editor.isImporting
    }
    override var isOpaque: Bool { true }
    /// Displayed document coordinates; native visibleRect catches up on input.
    private var restoredViewID: UInt64 = 0
    var viewportRect: NSRect { NSRect(origin: presentationOrigin ?? super.visibleRect.origin, size: super.visibleRect.size) }
    var isPresentingScroll: Bool { presentationOrigin != nil }
    /// Convert a document point even while only the presentation layers scroll.
    func convertDocumentPoint(_ point: NSPoint, to view: NSView?) -> NSPoint {
        convert(NSPoint(x: point.x - viewportRect.minX + super.visibleRect.minX,
                        y: point.y - viewportRect.minY + super.visibleRect.minY), to: view)
    }
    /// Hit-test the displayed pixels without committing layer scrolling to AppKit.
    func documentPoint(fromWindow point: NSPoint) -> NSPoint {
        let native = convert(point, from: nil)
        return NSPoint(x: native.x + viewportRect.minX - super.visibleRect.minX,
                       y: native.y + viewportRect.minY - super.visibleRect.minY)
    }
    /// Commit at interaction boundaries, not at display cadence. Native controls
    /// and AppKit drag/autoscroll then use the same coordinates as the pixels.
    func synchronizeScrollPresentation() {
        guard let origin = presentationOrigin, let scroll = enclosingScrollView else { return }
        presentationOrigin = nil; scrollSurface.isHidden = true; rulerSurface.isHidden = false
        scroll.contentView.scroll(to: origin)
        scroll.reflectScrolledClipView(scroll.contentView)
        positionPinnedSurfaces(); positionHeaderControls(updateConfiguration: false)
        presentPlayhead()
        window?.invalidateCursorRects(for: self)
    }
    private func invalidateScrollTiles() { scrollSurface.invalidateTiles() }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
        scrollObserver = nil
        controlsOverlay.removeFromSuperview()
        guard let scroll = enclosingScrollView else { return }
        let clip = scroll.contentView
        nativeViewportSize = clip.bounds.size
        clip.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self, weak clip] _ in
            guard let self, let clip else { return }
            if self.nativeViewportSize != clip.bounds.size {
                self.nativeViewportSize = clip.bounds.size
                self.synchronizeScrollPresentation()
            }
            self.presentationOrigin = nil; self.scrollSurface.isHidden = true; self.rulerSurface.isHidden = false
            self.positionPinnedSurfaces()
            self.positionHeaderControls(updateConfiguration: false)
            self.presentPlayhead()
            if !self.presentingTransport {
                if let window = self.window { self.updateTrackControlHover(at: self.convert(window.mouseLocationOutsideOfEventStream, from: nil)) }
                self.layoutNameField()
                self.window?.invalidateCursorRects(for: self)
            }
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
           !editor.isRecording, !editor.isShuttling, !editor.requestingMic, !editor.isExporting, !editor.isImporting && !editor.isOpening {
            let row = Int((point.y - ruler) / rowHeight)
            if rows.indices.contains(row) {
                let (track, depth) = rows[row]
                let rects = [trackMuteRect(row: row, depth: depth), trackSoloRect(row: row, depth: depth)]
                if let index = rects.firstIndex(where: { $0.contains(point) }) { next = (track.id, index) }
            }
        }
        if next?.id != hoveredTrackControl?.id || next?.kind != hoveredTrackControl?.kind { hoveredTrackControl = next; sidebarSurface.needsDisplay = true }
    }
    override func mouseMoved(with event: NSEvent) {
        updateTrackControlHover(at: documentPoint(fromWindow: event.locationInWindow))
    }
    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseExited(with event: NSEvent) { updateTrackControlHover(at: nil) }
    private func drawTrackControlHover(_ id: UUID, kind: Int, rect: NSRect) {
        guard window?.isKeyWindow == true, hoveredTrackControl?.id == id, hoveredTrackControl?.kind == kind,
              !editor.isRecording, !editor.isShuttling, !editor.requestingMic, !editor.isExporting, !editor.isImporting && !editor.isOpening else { return }
        fill(rect, NSColor.white.withAlphaComponent(0.10), radius: 5)
        NSColor.white.withAlphaComponent(0.16).setStroke()
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.4, dy: 0.4), xRadius: 5, yRadius: 5); path.lineWidth = 0.7; path.stroke()
    }
    func installHeaderControls(_ view: NSView) {
        headerControls?.removeFromSuperview(); headerControls = view
        view.translatesAutoresizingMaskIntoConstraints = true
        controlsOverlay.addSubview(view)
        positionHeaderControls()
    }
    func installControlsOverlay(in container: NSView) {
        container.addSubview(controlsOverlay)
        positionPinnedSurfaces()
    }
    private func positionPinnedSurfaces() {
        guard let scroll = enclosingScrollView, let container = controlsOverlay.superview else { return }
        let visible = viewportRect
        let overlayFrame = container.convert(scroll.contentView.bounds, from: scroll.contentView)
        if controlsOverlay.frame != overlayFrame { controlsOverlay.frame = overlayFrame }
        if scrollSurface.frame != controlsOverlay.bounds { scrollSurface.frame = controlsOverlay.bounds }
        let sidebar = NSRect(x: 0, y: ruler, width: header, height: max(0, visible.height - ruler))
        let oldSidebar = sidebarSurface.frame
        if sidebar != oldSidebar { sidebarSurface.frame = sidebar }
        let sidebarOrigin = NSPoint(x: visible.minX, y: visible.minY + ruler)
        if sidebarSurface.documentOrigin.y != sidebarOrigin.y || sidebar.size != oldSidebar.size { sidebarSurface.needsDisplay = true }
        sidebarSurface.documentOrigin = sidebarOrigin
        let rulerFrame = NSRect(x: 0, y: 0, width: visible.width, height: ruler)
        if rulerSurface.frame != rulerFrame { rulerSurface.frame = rulerFrame; rulerSurface.needsDisplay = true }
        if rulerSurface.documentOrigin != visible.origin { rulerSurface.documentOrigin = visible.origin; rulerSurface.needsDisplay = true }
    }
    private func positionHeaderControls(updateConfiguration: Bool = true) {
        let rect = NSRect(x: 0, y: 0, width: header, height: ruler)
        if headerControls?.frame != rect { headerControls?.frame = rect }
        positionMixerControls(updateConfiguration: updateConfiguration)
    }
    private func positionMixerControls(updateConfiguration: Bool) {
        let ids = Set(rows.map { $0.0.id })
        for id in Array(mixerControls.keys) where !ids.contains(id) { mixerControls.removeValue(forKey: id)?.removeFromSuperview() }
        for (row, item) in rows.enumerated() {
            let (track, depth) = item
            let control = mixerControls[track.id] ?? TrackMixerControls(track: track, editor: editor)
            if control.superview == nil { controlsOverlay.addSubview(control); mixerControls[track.id] = control }
            let y = ruler + CGFloat(row) * rowHeight
            let rect = NSRect(x: pinnedHeaderX, y: y, width: header, height: rowHeight)
                .intersection(NSRect(x: pinnedHeaderX, y: pinnedRulerRect.maxY, width: header, height: max(0, viewportRect.maxY - pinnedRulerRect.maxY)))
            control.isHidden = rect.isEmpty || rect.isNull
            guard !control.isHidden else { continue }
            let localRect = rect.offsetBy(dx: -viewportRect.minX, dy: -viewportRect.minY)
            let needsLayout = updateConfiguration || control.frame.size != localRect.size || control.frame.minY != localRect.minY
            if control.frame != localRect { control.frame = localRect }
            if needsLayout {
                let offset = y - rect.minY
                let first = trackMuteRect(row: row, depth: depth)
                control.volumeControl.frame = NSRect(x: first.minX - pinnedHeaderX, y: offset + trackVolumeY, width: trackMeterReadoutRect(row: row, channel: 0).maxX - first.minX, height: 22)
                control.volumeControl.layoutSubtreeIfNeeded()
                control.pan.frame = NSRect(x: header - 24, y: offset + 4, width: 20, height: rowHeight - 8)
                let recRect = trackRecordRect(row: row, depth: depth)
                control.rec.frame = NSRect(x: recRect.minX - pinnedHeaderX, y: recRect.minY - rect.minY, width: recRect.width, height: recRect.height)
                let fxRect = trackFXRect(row: row, depth: depth)
                control.fx.frame = NSRect(x: fxRect.minX - pinnedHeaderX, y: fxRect.minY - rect.minY, width: fxRect.width, height: fxRect.height)
            }
            if updateConfiguration { control.configure(track, color: trackColors[row % trackColors.count]) }
        }
    }
    deinit {
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
        waveformJobs.values.forEach { $0.1.cancel() }; sourceJobs.values.forEach { $0.cancel() }
    }
    var pinnedRulerRect: NSRect { NSRect(x: 0, y: max(0, viewportRect.minY), width: bounds.width, height: ruler) }
    var pinnedHeaderX: CGFloat { max(0, viewportRect.minX) }
    var fragmentLeft: CGFloat { pinnedHeaderX + header }
    var visibleFragmentRect: NSRect {
        let visible = viewportRect
        return NSRect(x: fragmentLeft, y: visible.minY, width: max(0, visible.width - header), height: visible.height)
    }
    var visibleTrackRect: NSRect {
        let visible = viewportRect, top = pinnedRulerRect.maxY
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
        guard isTrackPoint(point), viewportRect.contains(point) else { refresh(); return }
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
        synchronizeScrollPresentation()
        invalidateScrollTiles()
        structureRefreshCount += 1
        rows = orderedRows(trackPreview ?? editor.project.tracks)
        let retained = Set(editor.project.tracks.flatMap(\.clips).map(\.id)).union(fragmentCopyPreviews.values.map(\.id))
        fragmentWaveforms = fragmentWaveforms.filter { retained.contains($0.key) }
        rasterStyles = rasterStyles.filter { retained.contains($0.key) }
        let sources = Set(editor.project.tracks.flatMap(\.clips).map(\.source))
        for key in Array(sourceJobs.keys) where key.rate != editor.audio.sampleRate || !sources.contains(key.path) {
            sourceJobs.removeValue(forKey: key)?.cancel()
        }
        failedSources = failedSources.filter { $0.rate == editor.audio.sampleRate && sources.contains($0.path) }
        for id in Array(waveformJobs.keys) where !retained.contains(id) { waveformJobs.removeValue(forKey: id)?.1.cancel() }
        window?.invalidateCursorRects(for: self)
        let visible = viewportSize
        editor.zoom = max(minimumZoom, editor.zoom)
        let width = editor.zoom <= minimumZoom ? visible.width : max(visible.width, header + timelineDuration * editor.zoom)
        frame.size = NSSize(width: width, height: max(visible.height, ruler + CGFloat(rows.count) * rowHeight + 110))
        if restoredViewID != editor.timelineViewRestoreID, let scroll = enclosingScrollView,
           scroll.contentSize.width > 0, scroll.contentSize.height > 0 {
            // Restore once, after the document's new size is known. A layout
            // or waveform refresh must not undo subsequent user scrolling.
            restoredViewID = editor.timelineViewRestoreID
            playbackScroll = nil; pausedScrollCursor = nil; followedPlayback = false
            let saved = editor.project.timelineView
            let origin = NSPoint(x: min(max(0, frame.width - scroll.contentSize.width), saved?.x ?? centeredPlayheadOrigin),
                                 y: min(max(0, frame.height - scroll.contentSize.height), saved?.y ?? 0))
            scroll.contentView.scroll(to: origin)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        positionPinnedSurfaces()
        positionHeaderControls()
        sidebarSurface.needsDisplay = true; rulerSurface.needsDisplay = true
        layoutNameField()
        if let window, window.isKeyWindow { updateTrackControlHover(at: convert(window.mouseLocationOutsideOfEventStream, from: nil)) }
        else { updateTrackControlHover(at: nil) }
        needsDisplay = true
        let followsPlayback = editor.isPlaying || editor.isShuttling
        let requested = lastPlaybackScrollRequest != editor.playbackScrollRequest
        lastPlaybackScrollRequest = editor.playbackScrollRequest
        if requested, editor.isPlaying, !editor.isShuttling, !editor.isRecording {
            playbackScroll = PlaybackScroll(startedAt: ProcessInfo.processInfo.systemUptime, origin: viewportRect.minX)
        }
        if editor.isShuttling || editor.isRecording { playbackScroll = nil }
        if followsPlayback { pausedScrollCursor = nil; followPlayhead() }
        else if !followedPlayback, playbackScroll != nil, steppingPausedCursor || pausedScrollCursor == editor.cursor { followPlayhead() }
        else {
            let wasEasing = playbackScroll != nil
            playbackScroll = nil; pausedScrollCursor = nil
            // A fading pause keeps its polling timer until the node pauses; freeze that viewport.
            // Stop/natural completion invalidates the timer and still reveals its final marker.
            if followedPlayback && (!wasEasing || editor.timer == nil) { centerOnPlayhead() }
        }
        followedPlayback = followsPlayback
        if editor.isRecording, let scroll = enclosingScrollView {
            let visible = scroll.documentVisibleRect, x = header + editor.cursor * editor.zoom
            if x > visible.maxX - 40 {
                scroll.contentView.scroll(to: NSPoint(x: max(0, x - visible.width + 80), y: visible.minY))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        }
        presentPlayhead()
    }
    func refreshTransportMeters() {
        for (track, _) in rows {
            guard let control = mixerControls[track.id], !control.isHidden else { continue }
            control.volumeControl.updateMeter(editor.displayedTrackMeter(track), active: editor.isMeteringAudio,
                                              recording: editor.recording(for: track.id) != nil,
                                              showsPeaks: editor.showsTrackMeter(track.id))
        }
    }
    func invalidateRecordingPreview() {
        var combined: NSRect?
        for take in editor.recordings {
            guard let row = rows.firstIndex(where: { $0.0.id == take.track }) else { continue }
            let rect = NSRect(x: header + take.start * editor.zoom - 2, y: ruler + CGFloat(row) * rowHeight,
                              width: max(14, (take.end - take.start) * editor.zoom + 4), height: rowHeight)
            combined = combined.map { $0.union(rect) } ?? rect
        }
        guard let rect = combined else { previousRecordingRect = nil; return }
        let dirty = (previousRecordingRect.map { $0.union(rect) } ?? rect).intersection(viewportRect)
        if !dirty.isNull, !dirty.isEmpty { setNeedsDisplay(dirty) }
        previousRecordingRect = rect
    }
    private func presentPlayhead() {
        let x = header + editor.cursor * editor.zoom
        let viewport = viewportRect
        playheadView.present(x: x - viewport.minX, viewport: visibleFragmentRect.offsetBy(dx: -viewport.minX, dy: -viewport.minY), color: editor.isRecording ? .systemRed : accent,
                             visible: x >= fragmentLeft && x <= viewportRect.maxX)
    }
    func presentTransportFrame() {
        presentingTransport = true
        defer { presentingTransport = false }
        if editor.isPlaying || editor.isShuttling || editor.isRecording {
            // Grow in coarse chunks only when recording/shuttle actually reaches the document end.
            if header + (editor.cursor + 2) * editor.zoom > frame.width {
                frame.size.width = max(frame.width, header + (editor.cursor + 15) * editor.zoom)
            }
            if editor.isRecording {
                if let scroll = enclosingScrollView {
                    let visible = scroll.documentVisibleRect, x = header + editor.cursor * editor.zoom
                    if x > visible.maxX - 40 {
                        scroll.contentView.scroll(to: NSPoint(x: max(0, x - visible.width + 80), y: visible.minY))
                        scroll.reflectScrolledClipView(scroll.contentView)
                    }
                }
            } else { followPlayhead() }
        } else if playbackScroll != nil { followPlayhead() }
        if isPresentingScroll {
            sidebarSurface.documentOrigin.x = viewportRect.minX
            scrollSurface.present(viewport: viewportRect, headerWidth: header, rulerHeight: ruler)
        }
        presentPlayhead()
        if let cursor = presentationCursor, NSCursor.current !== cursor { cursor.set() }
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
        if selectingRange, didDragRange, canSelectRange, let point = lastRangeDragPoint {
            updateTimeRange(to: point, flags: event.modifierFlags)
        }
        if let point = lastFragmentDragPoint, !editor.busy {
            if fragmentResize != nil && didResizeFragment { updateFragmentResize(at: point, flags: event.modifierFlags) }
            else if dragClip != nil && didCheckpoint { updateFragmentMove(at: point, flags: event.modifierFlags) }
        }
        super.flagsChanged(with: event)
    }
    func trackNameRect(row: Int, depth: Int) -> NSRect {
        let x = pinnedHeaderX + CGFloat(min(depth, 6)) * 15 + 18
        return NSRect(x: x, y: ruler + CGFloat(row) * rowHeight + 10, width: fragmentLeft - x - 34, height: 17)
    }
    func trackMeterReadoutRect(row: Int, channel: Int) -> NSRect {
        NSRect(x: fragmentLeft - 30 - MixerVolumeControl.peakReadoutWidth, y: ruler + CGFloat(row) * rowHeight + trackVolumeY + CGFloat(channel) * 11, width: MixerVolumeControl.peakReadoutWidth, height: 11)
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
        NSRect(x: pinnedHeaderX + CGFloat(min(depth, 2)) * 6 + 18, y: ruler + CGFloat(row) * rowHeight + trackButtonsY, width: 36, height: 20)
    }
    func trackSoloRect(row: Int, depth: Int) -> NSRect {
        let first = trackMuteRect(row: row, depth: depth)
        return NSRect(x: first.minX + 40, y: first.minY, width: 34, height: first.height)
    }
    func trackRecordRect(row: Int, depth: Int) -> NSRect {
        let first = trackMuteRect(row: row, depth: depth)
        return NSRect(x: first.minX + 78, y: first.minY, width: 32, height: first.height)
    }
    func trackFXRect(row: Int, depth: Int) -> NSRect {
        let x = pinnedHeaderX + CGFloat(min(depth, 2)) * 6 + 18
        return NSRect(x: x + 114, y: ruler + CGFloat(row) * rowHeight + trackButtonsY, width: MixerFXButton.trackControlWidth, height: 20)
    }
    func rangeHandleRects() -> [NSRect] {
        guard let range = editor.range else { return [] }
        return [range.lowerBound, range.upperBound].map {
            NSRect(x: header + $0 * editor.zoom - 5, y: pinnedRulerRect.minY, width: 10, height: ruler)
                .intersection(NSRect(x: fragmentLeft, y: pinnedRulerRect.minY, width: max(0, viewportRect.width - header), height: ruler))
        }
    }
    var canSelectRange: Bool { !editor.isRecording && !editor.requestingMic && !editor.isExporting && !editor.isImporting && !editor.isOpening }
    private func enumerateCursorRects(_ add: (NSRect, NSCursor) -> Void) {
        if canSelectRange {
            for rect in rangeHandleRects() {
                let visible = rect.intersection(viewportRect)
                if !visible.isEmpty { add(visible, .resizeLeftRight) }
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
                        for rect in exposed where !rect.isEmpty { add(rect, cursor) }
                    }
                }
            }
            let depth = item.1
            for (rect, cursor) in [(trackNameHitRect(row: row, depth: depth), NSCursor.iBeam),
                                   (trackMuteRect(row: row, depth: depth), NSCursor.arrow),
                                   (trackSoloRect(row: row, depth: depth), NSCursor.arrow)] {
                let visible = rect.intersection(visibleTrackRect)
                if !visible.isEmpty && (!editor.busy || ((rect == trackMuteRect(row: row, depth: depth) || rect == trackSoloRect(row: row, depth: depth)) && !editor.isRecording && !editor.isShuttling && !editor.requestingMic && !editor.isExporting && !editor.isImporting && !editor.isOpening)) { add(visible, cursor) }
            }
        }
    }
    override func resetCursorRects() {
        super.resetCursorRects()
        enumerateCursorRects { addCursorRect($0, cursor: $1) }
    }
    var presentationCursor: NSCursor? {
        guard isPresentingScroll, let window, window.isKeyWindow else { return nil }
        let point = documentPoint(fromWindow: window.mouseLocationOutsideOfEventStream)
        guard visibleFragmentRect.contains(point) else { return nil }
        if editor.busy {
            return canSelectRange && rangeHandleRects().contains(where: { $0.contains(point) }) ? .resizeLeftRight : .arrow
        }
        guard point.y < ruler + CGFloat(rows.count) * rowHeight || pinnedRulerRect.contains(point) else { return .arrow }
        var cursor = NSCursor.arrow
        enumerateCursorRects { rect, candidate in if rect.contains(point) { cursor = candidate } }
        return cursor
    }
    func renameTrack(_ id: UUID) {
        guard !editor.busy, let index = editor.project.tracks.firstIndex(where: { $0.id == id }) else { return }
        nameField.finish(commit: true)
        renamingTrack = id
        sidebarSurface.needsDisplay = true
        layoutNameField()
        guard renamingTrack != nil else { return }
        nameField.begin(editor.project.tracks[index].name, commit: { [weak self] name in
            guard let self, let index = self.editor.project.tracks.firstIndex(where: { $0.id == id }), self.editor.project.tracks[index].name != name else { return }
            self.editor.checkpoint(); self.editor.project.tracks[index].name = name; self.editor.update("Track renamed")
        }, end: { [weak self] in self?.renamingTrack = nil; self?.sidebarSurface.needsDisplay = true })
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
        nameField.frame = frame.offsetBy(dx: -viewportRect.minX, dy: -viewportRect.minY)
    }
    func drawWaveform(_ peaks: [Float], partialPeak: Float? = nil, sampleRate: Double, offset: Double, gain: Double = 1, fragment: Clip? = nil, in rect: NSRect, dirtyRect: NSRect, color: NSColor) {
        let top = rect.minY + 1, bottom = rect.maxY - 1
        let mid = (top + bottom) / 2, amplitude = max(1, (bottom - top) / 2)
        let lowX = max(rect.minX, dirtyRect.minX), highX = min(rect.maxX, dirtyRect.maxX)
        guard lowX < highX, !peaks.isEmpty || partialPeak != nil else { return }
        let count = peaks.count + (partialPeak == nil ? 0 : 1)
        // Anchor the contour to the fragment, with one extra point on either
        // side of the dirty region so adjacent cached tiles share their edges.
        let step: CGFloat = 2
        let firstX = rect.minX + (floor((lowX - rect.minX) / step) - 1) * step
        let lastX = rect.minX + (ceil((highX - rect.minX) / step) + 1) * step
        let path = NSBezierPath()
        var lower: [NSPoint] = []
        for x in stride(from: firstX, through: lastX, by: step) {
            let seconds = offset + (x - rect.minX) / editor.zoom
            let first = max(0, Int(seconds * sampleRate) / 128)
            let last = min(count, max(first + 1, Int((seconds + step / editor.zoom) * sampleRate) / 128))
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
            let h = max(0.4, CGFloat(min(1, Double(peak) * gain * envelope)) * amplitude)
            let upper = NSPoint(x: x, y: mid - h)
            if lower.isEmpty { path.move(to: upper) } else { path.line(to: upper) }
            lower.append(NSPoint(x: x, y: mid + h))
        }
        for point in lower.reversed() { path.line(to: point) }
        path.close()
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: rect.intersection(dirtyRect)).addClip()
        color.setFill(); path.fill()
        NSGraphicsContext.restoreGraphicsState()
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
        for (index, item) in rows.enumerated() {
            let track = item.0; let y = ruler + CGFloat(index) * rowHeight
            let trackDimmed = dimmed.contains(track.id)
            if !NSRect(x: 0, y: y, width: bounds.width, height: rowHeight).intersects(dirtyRect) { continue }
            line(NSPoint(x: 0, y: y + rowHeight), NSPoint(x: bounds.width, y: y + rowHeight), .white.withAlphaComponent(0.065))
            let clips = displayedClips(for: track)
            for (layer, clip) in clips.enumerated() {
                guard clipRect(clip, row: index, layer: 0).insetBy(dx: -4, dy: -4).intersects(dirtyRect) else { continue }
                // Only the visible fragments need overlap geometry; the display caps it at four levels.
                var overlaps = 0
                for prior in clips.prefix(layer) where prior.start < clip.end && prior.end > clip.start {
                    overlaps += 1; if overlaps == 4 { break }
                }
                let rect = clipRect(clip, row: index, layer: overlaps)
                guard rect.insetBy(dx: -4, dy: -4).intersects(dirtyRect) else { continue }
                drawFragmentRaster(clip, in: rect, dirtyRect: dirtyRect, colorIndex: index % trackColors.count, dimmed: trackDimmed)
            }
            if let take = editor.recording(for: track.id) {
                let rect = NSRect(x: header + take.start * editor.zoom, y: y + 8, width: max(10, (take.end - take.start) * editor.zoom), height: rowHeight - 16)
                fill(rect, NSColor.systemRed.blended(withFraction: 0.85, of: background)!, radius: 6)
                NSColor.systemRed.setStroke(); NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).stroke()
                NSGraphicsContext.saveGraphicsState(); NSBezierPath(rect: rect.insetBy(dx: 1, dy: 1)).addClip()
                drawChannelWaveforms(take.channelPeaks, partialPeaks: take.partialChannelPeaks, sampleRate: take.recorder.format.sampleRate, offset: 0, in: rect, dirtyRect: dirtyRect, color: .systemRed)
                NSGraphicsContext.restoreGraphicsState()
            }
        }
        if let range = editor.range {
            fill(NSRect(x: header + range.lowerBound * editor.zoom, y: ruler, width: (range.upperBound - range.lowerBound) * editor.zoom, height: bounds.height - ruler), accent.withAlphaComponent(0.09))
        }
        // Composite the grid over static fragment tiles and live capture alike.
        for tick in rulerTicks(in: dirtyRect) {
            let x = header + tick.time * editor.zoom
            let alpha = editor.project.tempoMode ? (tick.isBar ? 0.10 : 0.035) : 0.045
            line(NSPoint(x: x, y: ruler), NSPoint(x: x, y: bounds.height), NSColor.white.withAlphaComponent(alpha))
        }
        if let fragmentSnapTime {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: visibleFragmentRect.intersection(visibleTrackRect)).addClip()
            let x = header + fragmentSnapTime * editor.zoom
            let guide = NSBezierPath(); guide.move(to: NSPoint(x: x, y: pinnedRulerRect.maxY))
            guide.line(to: NSPoint(x: x, y: viewportRect.maxY))
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
    }
    private func paintFragment(_ clip: Clip, in rect: NSRect, dirtyRect: NSRect, color: NSColor, dimmed: Bool,
                       data: AudioData?, preparedPeaks: [[Float]]?) {
        fill(rect.offsetBy(dx: 0, dy: 3), .black.withAlphaComponent(0.4), radius: 6)
        fill(rect, color.blended(withFraction: dimmed || clip.muted ? 0.92 : 0.78, of: background)!, radius: 6)
        let outline = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6); outline.lineWidth = editor.selection.contains(clip.id) ? 2 : 1
        (editor.selection.contains(clip.id) ? color : color.withAlphaComponent(0.45)).setStroke(); outline.stroke()
        NSGraphicsContext.saveGraphicsState(); NSBezierPath(rect: rect.insetBy(dx: 1, dy: 1)).addClip()
        if let data {
            if let peaks = preparedPeaks {
                drawChannelWaveforms(peaks, sampleRate: editor.audio.sampleRate, offset: 0, in: rect, dirtyRect: dirtyRect, color: color.withAlphaComponent(dimmed || clip.muted ? 0.25 : 0.9))
            } else {
                drawChannelWaveforms(data.channelPeaks, sampleRate: editor.audio.sampleRate, offset: clip.offset, gain: clip.volumeGain, fragment: clip, in: rect, dirtyRect: dirtyRect, color: color.withAlphaComponent(dimmed || clip.muted ? 0.25 : 0.9))
            }
        }
        if editor.selection.contains(clip.id) { drawFragmentFades(clip, in: rect) }
        drawFragmentTitle(clip.name, in: rect, color: dimmed || clip.muted ? .secondaryLabelColor : color)
        NSGraphicsContext.restoreGraphicsState()
    }
    private func drawFragmentRaster(_ clip: Clip, in rect: NSRect, dirtyRect: NSRect, colorIndex: Int, dimmed: Bool) {
        let data = preparedAudio(for: clip)
        let peaks = data.flatMap { processedWaveform(clip, audio: $0) }
        let color = trackColors[colorIndex]
        guard usesFragmentRasterCache else {
            paintFragment(clip, in: rect, dirtyRect: dirtyRect, color: color, dimmed: dimmed, data: data, preparedPeaks: peaks)
            return
        }
        let scale = window?.backingScaleFactor ?? 2
        let style = RasterStyle(waveform: FragmentWaveformKey(clip, rate: editor.audio.sampleRate, channels: editor.project.audioFormat.channels),
                                name: clip.name, zoom: editor.zoom, height: rect.height, scale: scale, colorIndex: colorIndex,
                                selected: editor.selection.contains(clip.id), dimmed: dimmed, muted: clip.muted, processed: peaks != nil, hasAudio: data != nil)
        if rasterStyles[clip.id]?.0 != style { rasterStyles[clip.id] = (style, UUID()) }
        let generation = rasterStyles[clip.id]!.1
        // Tiles have stable fragment-local coordinates, so scrolling and moving reuse pixels.
        // Limit allocation to visible tiles, never the full width of a long recording.
        let extent = rect.insetBy(dx: -4, dy: -4)
        let visible = extent.intersection(dirtyRect)
        guard !visible.isEmpty else { return }
        let tileWidth: CGFloat = 512
        let first = max(0, Int(floor((visible.minX - extent.minX) / tileWidth)))
        let last = max(first, Int(floor((visible.maxX - extent.minX) / tileWidth)))
        for tile in first...last {
            let localX = CGFloat(tile) * tileWidth
            let width = min(tileWidth, extent.width - localX)
            guard width > 0 else { continue }
            let key = "\(generation):\(tile)" as NSString
            let image: NSImage
            if let cached = fragmentRasters.object(forKey: key) {
                image = cached; rasterHitCount += 1
            } else {
                let pixelsWide = max(1, Int(ceil(width * scale))), pixelsHigh = max(1, Int(ceil(extent.height * scale)))
                guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixelsWide, pixelsHigh: pixelsHigh,
                                                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                      let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else { continue }
                bitmap.size = NSSize(width: width, height: extent.height)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = graphics
                let context = graphics.cgContext
                context.translateBy(x: 0, y: CGFloat(pixelsHigh))
                context.scaleBy(x: scale, y: -scale)
                NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
                let tileRect = NSRect(x: 0, y: 0, width: width, height: extent.height)
                NSBezierPath(rect: tileRect).addClip()
                let localRect = NSRect(x: 4 - localX, y: 4, width: rect.width, height: rect.height)
                paintFragment(clip, in: localRect, dirtyRect: tileRect, color: color, dimmed: dimmed, data: data, preparedPeaks: peaks)
                NSGraphicsContext.restoreGraphicsState()
                image = NSImage(size: bitmap.size); image.addRepresentation(bitmap)
                fragmentRasters.setObject(image, forKey: key, cost: pixelsWide * pixelsHigh * 4)
                rasterBuildCount += 1
            }
            image.draw(in: NSRect(x: extent.minX + localX, y: extent.minY, width: width, height: extent.height),
                       from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.none])
        }
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
            let color = trackColors[index % trackColors.count]
            fill(NSRect(x: pinnedHeaderX, y: y + 1, width: 3, height: rowHeight - 2), selected ? color.withAlphaComponent(trackDimmed ? 0.3 : 1) : .clear)
            let editing = renamingTrack == track.id && nameField.isRenaming
            let title = editing ? (depth > 0 ? "↳  " : "") : (depth > 0 ? "↳  \(track.name)" : track.name)
            label(title, trackNameRect(row: index, depth: depth), size: 13, color: trackDimmed ? .secondaryLabelColor : .labelColor, weight: .semibold)
            let muteRect = trackMuteRect(row: index, depth: depth)
            fill(muteRect, track.muted ? NSColor.systemOrange.withAlphaComponent(0.25) : NSColor.white.withAlphaComponent(0.06), radius: 5)
            drawTrackControlHover(track.id, kind: 0, rect: muteRect)
            centeredControlLabel(track.muted ? "MUTED" : "MUTE", muteRect, size: 9, color: track.muted ? .systemOrange : .secondaryLabelColor, flipped: isFlipped)
            let soloRect = trackSoloRect(row: index, depth: depth)
            fill(soloRect, track.solo ? NSColor.systemBlue.withAlphaComponent(0.25) : NSColor.white.withAlphaComponent(0.06), radius: 5)
            drawTrackControlHover(track.id, kind: 1, rect: soloRect)
            centeredControlLabel("SOLO", soloRect, size: 9, color: track.solo ? .systemBlue : .secondaryLabelColor, flipped: isFlipped)
            line(NSPoint(x: pinnedHeaderX, y: y + rowHeight), NSPoint(x: fragmentLeft, y: y + rowHeight), .white.withAlphaComponent(0.065))
        }
        NSGraphicsContext.restoreGraphicsState()
        line(NSPoint(x: fragmentLeft, y: ruler), NSPoint(x: fragmentLeft, y: bounds.height), .white.withAlphaComponent(0.10))
    }
    func rulerTicks(in rect: NSRect) -> [TempoTick] {
        guard !rect.isEmpty, rect.minX.isFinite, rect.maxX.isFinite else { return [] }
        let start = max(0, (rect.minX - header) / editor.zoom)
        let end = max(start, (rect.maxX - header) / editor.zoom)
        if editor.project.tempoMode { return TempoGrid.ticks(from: start, to: end, zoom: editor.zoom, bpm: editor.project.tempo) }
        let step = rulerStep, first = floor(start / step) * step
        return stride(from: first, through: end, by: step).map {
            TempoTick(time: $0, label: String(format: "%02d:%02d", Int($0) / 60, Int($0) % 60), isBar: true)
        }
    }
    private func drawRuler(in dirtyRect: NSRect) {
        let rect = pinnedRulerRect
        fill(rect, panelColor)
        NSGraphicsContext.saveGraphicsState(); NSBezierPath(rect: visibleFragmentRect).addClip()
        drawRulerContent(in: dirtyRect)
        NSGraphicsContext.restoreGraphicsState()
        fill(NSRect(x: pinnedHeaderX, y: rect.minY, width: header, height: ruler), panelColor)
    }
    private func drawRulerContent(in dirtyRect: NSRect) {
        let rect = pinnedRulerRect, top = rect.minY
        fill(NSRect(x: dirtyRect.minX, y: top, width: dirtyRect.width, height: ruler), panelColor)
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
        if let start = editor.lastPlaybackStart {
            let x = header + start * editor.zoom
            line(NSPoint(x: x, y: rect.maxY - 15), NSPoint(x: x, y: rect.maxY), .systemOrange, width: 2)
        }
    }
    private func timelineTime(at point: NSPoint, flags: NSEvent.ModifierFlags) -> Double {
        let time = max(0, (point.x - header) / editor.zoom)
        guard editor.project.tempoMode, !flags.contains(.shift) else { return time }
        let beat = 60 / editor.project.tempo
        return (time / beat).rounded() * beat
    }
    private func updateTimeRange(to point: NSPoint, flags: NSEvent.ModifierFlags) {
        let a = rangeAnchor ?? timelineTime(at: dragStart, flags: flags)
        let b = timelineTime(at: point, flags: flags)
        editor.range = min(a, b)...max(a, b)
        editor.update()
    }
    override func mouseDown(with event: NSEvent) {
        synchronizeScrollPresentation()
        window?.makeFirstResponder(self)
        pendingFragmentClick = nil; pendingShiftFragmentClick = nil; lastFragmentDragPoint = nil; didResizeFragment = false
        let point = convert(event.locationInWindow, from: nil)
        // A ruler press is only a seek once released without dragging.
        // Range selection and handle resizing never touch the transport.
        if pinnedRulerRect.contains(point) {
            guard canSelectRange, point.x >= fragmentLeft else { return }
            dragStart = point; selectingRange = true; didDragRange = false; rangeAnchor = nil; lastRangeDragPoint = nil
            if let range = editor.range, event.clickCount < 2 {
                let handles = rangeHandleRects()
                let hits = handles.indices.filter { handles[$0].contains(point) }
                if let edge = hits.min(by: { abs(handles[$0].midX - point.x) < abs(handles[$1].midX - point.x) }) {
                    rangeAnchor = edge == 0 ? range.upperBound : range.lowerBound
                }
            }
            return
        }
        if !editor.isRecording && !editor.isShuttling && !editor.requestingMic && !editor.isExporting && !editor.isImporting && !editor.isOpening && isTrackPoint(point) && point.x < fragmentLeft {
            let row = Int((point.y - ruler) / rowHeight)
            if rows.indices.contains(row), trackMuteRect(row: row, depth: rows[row].1).contains(point) {
                editor.selectedTrack = rows[row].0.id
                editor.toggleMute(rows[row].0.id); return
            }
            if rows.indices.contains(row), trackSoloRect(row: row, depth: rows[row].1).contains(point) {
                editor.selectedTrack = rows[row].0.id
                editor.toggleSolo(rows[row].0.id); return
            }
            if rows.indices.contains(row), trackRecordRect(row: row, depth: rows[row].1).contains(point) {
                editor.toggleRecordArm(rows[row].0.id); return
            }
            if rows.indices.contains(row), trackFXRect(row: row, depth: rows[row].1).contains(point) {
                mixerControls[rows[row].0.id]?.fx.performClick(nil); return
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
            if trackMuteRect(row: row, depth: depth).contains(p) {
                editor.toggleMute(track.id)
            } else if trackSoloRect(row: row, depth: depth).contains(p) {
                editor.toggleSolo(track.id)
            } else if trackRecordRect(row: row, depth: depth).contains(p) {
                editor.toggleRecordArm(track.id)
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
                editor.seek(to: timelineTime(at: p, flags: event.modifierFlags))
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
        let horizontalPoint = NSPoint(x: point.x, y: viewportRect.midY)
        if let horizontalEvent = NSEvent.mouseEvent(with: .leftMouseDragged, location: convert(horizontalPoint, to: nil), modifierFlags: event.modifierFlags, timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil, eventNumber: event.eventNumber, clickCount: event.clickCount, pressure: event.pressure) {
            autoscroll(with: horizontalEvent)
        }
    }
    override func mouseDragged(with event: NSEvent) {
        synchronizeScrollPresentation()
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
            lastRangeDragPoint = p
            updateTimeRange(to: p, flags: event.modifierFlags)
            autoscrollRange(with: event); return
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
            let point = NSPoint(x: viewportRect.midX, y: p.y)
            if let verticalEvent = NSEvent.mouseEvent(with: .leftMouseDragged, location: convert(point, to: nil), modifierFlags: event.modifierFlags, timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil, eventNumber: event.eventNumber, clickCount: event.clickCount, pressure: event.pressure) { autoscroll(with: verticalEvent) }
        } else { autoscroll(with: event) }
    }
    override func mouseUp(with event: NSEvent) {
        synchronizeScrollPresentation()
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
                editor.seek(to: timelineTime(at: p, flags: event.modifierFlags))
            } else {
                updateMarquee(to: p); clearMarquee()
            }
            return
        }
        if selectingRange {
            if canSelectRange && didDragRange { updateTimeRange(to: p, flags: event.modifierFlags) }
            if canSelectRange && !didDragRange && rangeAnchor == nil {
                if event.clickCount == 2 { editor.range = nil }
                editor.seek(to: timelineTime(at: p, flags: event.modifierFlags))
            }
            selectingRange = false; rangeAnchor = nil; didDragRange = false; lastRangeDragPoint = nil
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
    private var centeredPlayheadOrigin: CGFloat {
        let width = viewportSize.width
        return min(max(0, frame.width - width), max(0, editor.cursor * editor.zoom - (width - header) / 2))
    }
    private func scrollHorizontally(to requested: CGFloat) {
        guard let scroll = enclosingScrollView else { return }
        let origin = min(max(0, frame.width - scroll.contentSize.width), max(0, requested))
        guard abs(viewportRect.minX - origin) > 0.001 else { return }
        if presentingTransport && !editor.isRecording && !selectingRange && dragClip == nil && trackDrag == nil && marqueeAnchor == nil && renamingTrack == nil {
            presentationOrigin = NSPoint(x: origin, y: viewportRect.minY)
            if !rulerSurface.isHidden { rulerSurface.isHidden = true }
            if frame.width > scroll.contentSize.width {
                scroll.horizontalScroller?.doubleValue = Double(origin / (frame.width - scroll.contentSize.width))
            }
            return
        }
        synchronizeScrollPresentation()
        scroll.contentView.scroll(to: NSPoint(x: origin, y: scroll.contentView.bounds.minY))
        scroll.reflectScrolledClipView(scroll.contentView)
    }
    private func followPlayhead(at time: Double = ProcessInfo.processInfo.systemUptime) {
        let target = centeredPlayheadOrigin
        if let animation = playbackScroll {
            scrollHorizontally(to: animation.position(target: target, at: time))
            if time - animation.startedAt >= PlaybackScroll.duration { playbackScroll = nil; pausedScrollCursor = nil }
        } else { scrollHorizontally(to: target) }
    }
    func centerOnPlayhead() {
        // Explicit zoom, playback arrows and boundary commands retain immediate centering.
        playbackScroll = nil; pausedScrollCursor = nil
        scrollHorizontally(to: centeredPlayheadOrigin)
    }
    func movePlayhead(direction: Double) {
        guard canSelectRange else { return }
        let visible = viewportRect
        let fragmentWidth = max(0, visible.width - header)
        guard fragmentWidth > 0 else { return }
        let step = Double(fragmentWidth) / editor.zoom * 0.01
        let position = editor.player?.seekPosition ?? editor.cursor
        let paused = !editor.isPlaying && !editor.isShuttling
        let origin = viewportRect.minX
        steppingPausedCursor = paused
        editor.seek(to: position + direction * step)
        steppingPausedCursor = false
        if paused {
            // Repeats keep the original one-second deadline and update the target,
            // so holding an arrow cannot continually restart and stall the scroll.
            if playbackScroll == nil {
                playbackScroll = PlaybackScroll(startedAt: ProcessInfo.processInfo.systemUptime, origin: origin)
            }
            pausedScrollCursor = editor.cursor
            scrollAnimationChanged?()
        } else { centerOnPlayhead() }
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
        else if event.keyCode == 123 || event.keyCode == 124 {
            let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
            if flags.contains(.command) { seekBoundary(end: event.keyCode == 124) }
            else if flags.isEmpty { movePlayhead(direction: event.keyCode == 123 ? -1 : 1) }
            else if (NSApp.delegate as? AppDelegate)?.handleShuttleShortcut(event) != true { super.keyDown(with: event) }
        }
        else if event.keyCode == 126 { NSApp.sendAction(#selector(AppDelegate.zoomIn), to: NSApp.delegate, from: self) }
        else if event.keyCode == 125 { NSApp.sendAction(#selector(AppDelegate.zoomOut), to: NSApp.delegate, from: self) }
        else if event.keyCode == 36 || event.keyCode == 76 { editor.restartFromLastStart() }
        else if event.keyCode == 49 { editor.playPause() }
        else if event.keyCode == 51 || event.keyCode == 117 { editor.deleteClips() }
        else { super.keyDown(with: event) }
    }
    override func keyUp(with event: NSEvent) {
        if (NSApp.delegate as? AppDelegate)?.handleShuttleShortcut(event) != true { super.keyUp(with: event) }
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        synchronizeScrollPresentation()
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
    @objc func effects() { if let id = editor.selectedTrack { editor.showEffects(for: id) } }
    @objc func addTrack() { editor.addTrack() }
    @objc func nest() { editor.addTrack(nested: true) }
    @objc func unparent() { if let id = editor.selectedTrack { editor.reparent(id, to: nil) } }
    @objc func remove() { editor.removeTrack() }
}
