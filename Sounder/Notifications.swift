import AppKit
import QuartzCore

private let toastMovementDuration: TimeInterval = 0.2

enum ToastStyle { case success, hint, error }
enum UXHint: String {
    case nestTracks, selectFragments
}
struct ToastMessage: Identifiable {
    let id = UUID()
    let text: String
    let style: ToastStyle
    let expiresAt: Date
}

/// One instance per running app session. Project changes and Undo never reset hints.
final class ToastCenter {
    static let lifetime: TimeInterval = 4
    private(set) var messages: [ToastMessage] = []
    private var shownHints = Set<UXHint>()
    private var observers: [UUID: () -> Void] = [:]
    private let now: () -> Date
    private var timer: Timer?
    init(now: @escaping () -> Date = Date.init) { self.now = now }
    deinit { timer?.invalidate() }
    @discardableResult func observe(_ observer: @escaping () -> Void) -> UUID {
        let id = UUID(); observers[id] = observer; return id
    }
    func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }
    func show(_ text: String, style: ToastStyle) {
        guard !text.isEmpty else { return }
        messages.removeAll { $0.expiresAt <= now() }
        messages.append(ToastMessage(text: text, style: style, expiresAt: now().addingTimeInterval(Self.lifetime)))
        publish(); scheduleExpiration()
    }
    func hint(_ key: UXHint, _ text: String) {
        guard shownHints.insert(key).inserted else { return }
        show(text, style: .hint)
    }
    func expire() {
        let count = messages.count
        messages.removeAll { $0.expiresAt <= now() }
        if messages.count != count { publish() }
        scheduleExpiration()
    }
    private func publish() { for observer in Array(observers.values) { observer() } }
    private func scheduleExpiration() {
        timer?.invalidate(); timer = nil
        guard let next = messages.map(\.expiresAt).min() else { return }
        let timer = Timer(timeInterval: max(0.001, next.timeIntervalSince(now())), repeats: false) { [weak self] _ in self?.expire() }
        // Notifications also expire while a save panel or plug-in editor is open.
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .modalPanel)
        self.timer = timer
    }
}

private final class ToastCard: NSView {
    let message: ToastMessage
    let text = NSTextField(wrappingLabelWithString: "")
    init(_ message: ToastMessage) {
        self.message = message
        super.init(frame: .zero)
        wantsLayer = true; layer?.cornerRadius = 5
        switch message.style {
        case .success: layer?.backgroundColor = NSColor(calibratedRed: 0.12, green: 0.54, blue: 0.31, alpha: 0.8).cgColor
        case .hint: layer?.backgroundColor = NSColor(calibratedRed: 0.98, green: 0.76, blue: 0.18, alpha: 0.8).cgColor
        case .error: layer?.backgroundColor = NSColor(calibratedRed: 0.78, green: 0.17, blue: 0.20, alpha: 0.8).cgColor
        }
        text.stringValue = message.text
        text.font = .systemFont(ofSize: 12, weight: .medium)
        text.textColor = message.style == .hint ? NSColor(calibratedWhite: 0.12, alpha: 1) : .white
        text.maximumNumberOfLines = 0; addSubview(text)
        setAccessibilityElement(true); setAccessibilityRole(.staticText); setAccessibilityLabel(message.text)
    }
    required init?(coder: NSCoder) { fatalError() }
    func animateEntrance() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, let layer else { return }
        // Animate only the presentation layer so layout/reflow can keep the
        // final stack geometry without interrupting the entrance.
        let rise = CABasicAnimation(keyPath: "position.y")
        rise.isAdditive = true
        rise.fromValue = superview?.isFlipped == true ? 50 : -50
        rise.toValue = 0; rise.duration = toastMovementDuration
        rise.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(rise, forKey: "entrance")
    }
    func width(maximum: CGFloat) -> CGFloat {
        let measured = (message.text as NSString).size(withAttributes: [.font: text.font!])
        return min(maximum, ceil(measured.width) + 32)
    }
    func height(for width: CGFloat) -> CGFloat {
        let measured = (message.text as NSString).boundingRect(with: NSSize(width: max(1, width - 32), height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: text.font!])
        return max(44, ceil(measured.height) + 24)
    }
    override func layout() { super.layout(); text.frame = bounds.insetBy(dx: 14, dy: 12) }
}

final class ToastOverlay: NSView {
    private let center: ToastCenter
    private var observer: UUID?
    private var cards: [UUID: ToastCard] = [:]
    override var isFlipped: Bool { true }
    // The overlay never intercepts editing, scrolling or drag gestures underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    init(center: ToastCenter) {
        self.center = center
        super.init(frame: .zero)
        wantsLayer = true
        observer = center.observe { [weak self] in self?.synchronize() }
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { if let observer { center.removeObserver(observer) } }
    @discardableResult static func install(in parent: NSView, center: ToastCenter) -> ToastOverlay {
        let overlay = ToastOverlay(center: center); overlay.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(overlay, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: parent.safeAreaLayoutGuide.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: parent.bottomAnchor)
        ])
        overlay.synchronize(); return overlay
    }
    private func synchronize() {
        let ids = Set(center.messages.map(\.id))
        for id in Array(cards.keys) where !ids.contains(id) {
            if let card = cards.removeValue(forKey: id) {
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0.36; card.animator().alphaValue = 0
                }, completionHandler: { card.removeFromSuperview() })
            }
        }
        var appearing: [ToastCard] = []
        for message in center.messages where cards[message.id] == nil {
            let card = ToastCard(message); card.alphaValue = 0
            cards[message.id] = card; addSubview(card)
            appearing.append(card)
        }
        positionCards(animated: true)
        appearing.forEach { $0.animateEntrance() }
    }
    private func positionCards(animated: Bool) {
        let maximumWidth = min(340, max(0, bounds.width - 32))
        var y: CGFloat = 16
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animated ? toastMovementDuration : 0
            for message in center.messages {
                guard let card = cards[message.id] else { continue }
                let width = card.width(maximum: maximumWidth)
                let rect = NSRect(x: bounds.width - width - 16, y: y, width: width, height: card.height(for: width))
                if card.frame == .zero { card.frame = rect }
                if animated { card.animator().frame = rect; card.animator().alphaValue = 1 }
                else { card.frame = rect; card.alphaValue = 1 }
                y = rect.maxY + 8
            }
        }
    }
    override func layout() { super.layout(); positionCards(animated: false) }
    // Snapshot helpers also let UI tests verify stacking without depending on fonts.
    var visibleFrames: [NSRect] { center.messages.compactMap { cards[$0.id]?.frame } }
}
