import AppKit

/// Shared non-Glass appearance for editor and mixer buttons.
enum ButtonStyle {
    static func drawFace(_ rect: NSRect, activeColor: NSColor? = nil, hovered: Bool = false) {
        let color = activeColor?.withAlphaComponent(0.25) ?? NSColor.white.withAlphaComponent(0.06)
        color.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
        if hovered { drawHover(rect) }
    }

    static func drawHover(_ rect: NSRect) {
        NSColor.white.withAlphaComponent(0.10).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
        NSColor.white.withAlphaComponent(0.16).setStroke()
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.4, dy: 0.4), xRadius: 5, yRadius: 5)
        path.lineWidth = 0.7
        path.stroke()
    }
}
