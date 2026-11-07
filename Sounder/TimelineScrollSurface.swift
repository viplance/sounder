import AppKit
import QuartzCore

/// A viewport-sized, layer-only presentation of the scrolling canvas. Tiles
/// contain document pixels; only the two content layers translate per frame.
/// Keep only visible tiles, independently of the length of the recording.
final class TimelineScrollSurface: NSView {
    private let body = CALayer()
    private let ruler = CALayer()
    private let bodyContent = CALayer()
    private let rulerContent = CALayer()
    private var tiles: [Int: (body: CALayer, ruler: CALayer)] = [:]
    private var tileGeometry: (y: CGFloat, height: CGFloat, scale: CGFloat)?
    private var needsRebuild = true
    private let tileWidth: CGFloat = 512
    var paint: ((_ rect: NSRect, _ ruler: Bool) -> Void)?
    private(set) var tileBuildCount = 0
    var retainedTileCount: Int { tiles.count }
    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {}
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true; layer?.isGeometryFlipped = true
        layer?.addSublayer(body); layer?.addSublayer(ruler)
        body.masksToBounds = true; ruler.masksToBounds = true
        body.addSublayer(bodyContent); ruler.addSublayer(rulerContent)
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }
    // Keep the old pixels until their replacements can be committed together.
    func invalidateTiles() { needsRebuild = true }
    func present(viewport: NSRect, headerWidth: CGFloat, rulerHeight: CGFloat) {
        let scale = window?.backingScaleFactor ?? 2
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        if needsRebuild || tileGeometry?.y != viewport.minY || tileGeometry?.height != viewport.height || tileGeometry?.scale != scale {
            for tile in tiles.values { tile.body.removeFromSuperlayer(); tile.ruler.removeFromSuperlayer() }
            tiles.removeAll(); tileGeometry = (viewport.minY, viewport.height, scale)
            needsRebuild = false
        }
        let bodyFrame = NSRect(x: headerWidth, y: rulerHeight, width: max(0, viewport.width - headerWidth), height: max(0, viewport.height - rulerHeight))
        let rulerFrame = NSRect(x: headerWidth, y: 0, width: bodyFrame.width, height: rulerHeight)
        if body.frame != bodyFrame { body.frame = bodyFrame }
        if ruler.frame != rulerFrame { ruler.frame = rulerFrame }
        let left = viewport.minX + headerWidth
        let first = Int(floor(left / tileWidth))
        let last = max(first, Int(ceil(viewport.maxX / tileWidth)) - 1)
        for index in Array(tiles.keys) where index < first || index > last {
            let tile = tiles.removeValue(forKey: index)!
            tile.body.removeFromSuperlayer(); tile.ruler.removeFromSuperlayer()
        }
        for index in first...last where tiles[index] == nil {
            let x = CGFloat(index) * tileWidth
            let bodyRect = NSRect(x: x, y: viewport.minY + rulerHeight, width: tileWidth, height: body.frame.height)
            let rulerRect = NSRect(x: x, y: viewport.minY, width: tileWidth, height: rulerHeight)
            let bodyTile = makeTile(in: bodyRect, ruler: false, scale: scale)
            let rulerTile = makeTile(in: rulerRect, ruler: true, scale: scale)
            bodyTile.frame.origin = NSPoint(x: x, y: 0); rulerTile.frame.origin = NSPoint(x: x, y: 0)
            bodyContent.addSublayer(bodyTile); rulerContent.addSublayer(rulerTile)
            tiles[index] = (bodyTile, rulerTile); tileBuildCount += 1
        }
        let translation = CATransform3DMakeTranslation(-left, 0, 0)
        bodyContent.transform = translation; rulerContent.transform = translation
        if isHidden { isHidden = false }
    }
    private func makeTile(in rect: NSRect, ruler: Bool, scale: CGFloat) -> CALayer {
        let tile = CALayer()
        tile.frame.size = rect.size; tile.contentsScale = scale
        guard rect.height > 0,
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(ceil(rect.width * scale)), pixelsHigh: Int(ceil(rect.height * scale)), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else { return tile }
        NSGraphicsContext.saveGraphicsState()
        let context = graphics.cgContext
        context.translateBy(x: 0, y: CGFloat(bitmap.pixelsHigh)); context.scaleBy(x: scale, y: -scale)
        context.translateBy(x: -rect.minX, y: -rect.minY)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        NSBezierPath(rect: rect).addClip()
        paint?(rect, ruler)
        NSGraphicsContext.restoreGraphicsState()
        tile.contents = bitmap.cgImage
        return tile
    }
}
