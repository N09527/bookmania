import BookmaniaCore
import UIKit

/// Plays page turns over a reader's page (PageTurner.kt and PageTurnRenderer.kt on Android):
///
/// 1. `hold()` takes a picture of the page shown now and covers the page with it.
/// 2. The reader changes the page under the picture.
/// 3. `play(_:)` waits until the page shows the new page, then the picture curls or slides away and reveals it. The
///    new page is pictured too when the turn needs it: for slides, and for the back of the leaf of a spread going
///    forward.
///
/// The curl is the flat fold of CurlGeometry, drawn with layers (masks, a transformed picture and gradients), so the
/// frames are put together by the GPU. Nothing in the page is run or read other than its pixels. Main thread only.
@MainActor
final class PageTurner {
    enum Style { case slide, curl }

    /// `edge`: the edge the page turns by (right for left-to-right reading, left for right-to-left, bottom for the
    /// vertical pager); `spread`: two pages side by side, one turns about the centre line; `forward`: to the next
    /// page (backwards the turn runs in reverse); `paper`: the colour of the back of a single page.
    struct Turn {
        var style: Style
        var edge: CurlEdge
        var spread: Bool
        var forward: Bool
        var paper: UIColor
    }

    /// Covers the page; added by the reader above the page view, with the same frame.
    let overlay = UIView()
    /// Takes a picture of the page as it is shown now (nil when it cannot).
    private let capture: () async -> UIImage?
    /// Waits until the page view has drawn what it shows now (or a short while).
    private let awaitDrawn: () async -> Void

    private var before: UIImage?
    private var generation = 0
    private(set) var holding = false
    private var link: CADisplayLink?
    private var linkTarget: DisplayLinkTarget?

    init(capture: @escaping () async -> UIImage?, awaitDrawn: @escaping () async -> Void) {
        self.capture = capture
        self.awaitDrawn = awaitDrawn
        overlay.isUserInteractionEnabled = false
        overlay.isHidden = true
        overlay.backgroundColor = .clear
        overlay.clipsToBounds = true
    }

    /// Takes a picture of the page shown now and covers the page with it. True once the picture is on the screen: the
    /// reader then changes the page and calls `play`. False to turn without animation (nothing is covered then).
    func hold() async -> Bool {
        end()
        let id = generation
        let size = overlay.bounds.size
        guard size.width > 0, size.height > 0, overlay.window != nil else { return false }
        guard let image = await capture(), id == generation else { return false }
        before = image
        clearLayers()
        let still = imageLayer(image)
        overlay.layer.addSublayer(still)
        overlay.isHidden = false
        holding = true
        return true
    }

    /// Plays `turn` once the reader has changed the page under the picture. Returns when the turn is over or was
    /// ended by `end()`.
    func play(_ turn: Turn) async {
        let id = generation
        guard holding, let current = before else { return }
        await awaitDrawn()
        guard id == generation else { return }
        let needsNext = turn.style == .slide || (turn.spread && turn.forward)
        var next: UIImage?
        if needsNext {
            next = await capture()
            guard id == generation else { return }
            // A spread going forward needs the new page for the back of the leaf: without it there is no curl.
            if next == nil && turn.style == .curl {
                close()
                return
            }
        }
        await animate(turn, current: current, next: next, id: id)
        if id == generation { close() }
    }

    /// Ends the turn in progress at once, showing the page as it is. A running animation stops at its next frame (the
    /// display link sees the new generation, stops and lets `play` return).
    func end() {
        generation += 1
        close()
    }

    private func close() {
        holding = false
        overlay.isHidden = true
        clearLayers()
    }

    private func clearLayers() {
        overlay.layer.sublayers?.forEach { $0.removeFromSuperlayer() }
    }

    // MARK: Frames

    private func animate(_ turn: Turn, current: UIImage, next: UIImage?, id: Int) async {
        let bounds = overlay.bounds
        clearLayers()
        let draw: (Double) -> Void
        let duration: Double
        switch turn.style {
        case .slide:
            duration = PageTurnTiming.slideSeconds
            let currentLayer = imageLayer(current)
            let nextLayer = next.map(imageLayer)
            overlay.layer.addSublayer(currentLayer)
            if let nextLayer { overlay.layer.addSublayer(nextLayer) }
            // The direction the old page leaves in: towards the hinge going forward, away from it going back.
            let sign: CGFloat
            switch turn.edge {
            case .right, .bottom: sign = turn.forward ? -1 : 1
            case .left: sign = turn.forward ? 1 : -1
            }
            let vertical = turn.edge == .bottom
            let extent = vertical ? bounds.height : bounds.width
            draw = { t in
                let offset = sign * extent * CGFloat(PageTurnTiming.slide(t))
                let shift = { (layer: CALayer, by: CGFloat) in
                    layer.frame = vertical ? bounds.offsetBy(dx: 0, dy: by) : bounds.offsetBy(dx: by, dy: 0)
                }
                shift(currentLayer, offset)
                if let nextLayer { shift(nextLayer, offset - sign * extent) }
            }
        case .curl:
            duration = PageTurnTiming.curlSeconds
            let curl = CurlLayers(in: overlay.layer, bounds: bounds, turn: turn, current: current, next: next)
            draw = { t in
                let p = PageTurnTiming.curl(t)
                curl.show(turn.forward ? p : 1 - p)
            }
        }
        draw(0)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let start = CACurrentMediaTime()
            let target = DisplayLinkTarget { [weak self] link in
                let done = self.map { id == $0.generation } != true
                let t = min(1, (CACurrentMediaTime() - start) / duration)
                if !done {
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    draw(t)
                    CATransaction.commit()
                }
                if done || t >= 1 {
                    link.invalidate()
                    if let self, self.link === link {
                        self.link = nil
                        self.linkTarget = nil
                    }
                    continuation.resume()
                }
            }
            let link = CADisplayLink(target: target, selector: #selector(DisplayLinkTarget.tick(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
            self.linkTarget = target
        }
    }

    private func imageLayer(_ image: UIImage) -> CALayer {
        let layer = CALayer()
        layer.contents = image.cgImage
        layer.contentsScale = image.scale
        layer.contentsGravity = .resize
        layer.frame = overlay.bounds
        return layer
    }
}

/// Calls a closure on every display frame (CADisplayLink needs an object target).
private final class DisplayLinkTarget: NSObject {
    let onTick: (CADisplayLink) -> Void

    init(_ onTick: @escaping (CADisplayLink) -> Void) { self.onTick = onTick }

    @objc func tick(_ link: CADisplayLink) { onTick(link) }
}

/// The layers of one curl (PageTurnRenderer.drawCurl on Android). Going forward, the leaf of the current page is lifted
/// and the new page (the reader's view) shows under it. Going back, the turn runs backwards: the leaf of the previous
/// page (the reader's view) comes back over the current page. On a spread the back of the leaf carries the page that
/// lies there once the turn is over (the new page going forward, the other half of the current page going back); a
/// single page shows the back of the paper.
@MainActor
private final class CurlLayers {
    private let leaf: CurlLeaf
    private let turn: PageTurner.Turn
    private let bounds: CGRect
    private let base = CALayer()
    private let baseMask = CAShapeLayer()
    private let shadow = CAGradientLayer()
    private let shadowMask = CAShapeLayer()
    private let flap = CALayer()
    private let flapMask = CAShapeLayer()
    private let flapContent = CALayer()
    private let flapShade = CAGradientLayer()
    private let flapShadeMask = CAShapeLayer()
    private let hasBack: Bool

    init(in parent: CALayer, bounds: CGRect, turn: PageTurner.Turn, current: UIImage, next: UIImage?) {
        self.turn = turn
        self.bounds = bounds
        leaf = CurlLeaf.of(width: Double(bounds.width), height: Double(bounds.height), edge: turn.edge, spread: turn.spread)
        if turn.forward && turn.spread {
            // The other half of the spread stays where it is until the leaf comes down on it.
            let other = CurlLayers.picture(current, bounds)
            let mask = CAShapeLayer()
            let rect = turn.edge == .left
                ? CGRect(x: leaf.right, y: 0, width: Double(bounds.width) - leaf.right, height: Double(bounds.height))
                : CGRect(x: 0, y: 0, width: leaf.left, height: Double(bounds.height))
            mask.path = CGPath(rect: rect, transform: nil)
            other.mask = mask
            parent.addSublayer(other)
        }
        let picture = CurlLayers.picture(current, bounds)
        base.frame = bounds
        base.addSublayer(picture)
        base.mask = baseMask
        parent.addSublayer(base)

        shadow.frame = bounds
        shadow.colors = [UIColor.black.withAlphaComponent(0x55 / 255.0).cgColor, UIColor.clear.cgColor]
        shadow.mask = shadowMask
        parent.addSublayer(shadow)

        let back: UIImage? = turn.spread ? (turn.forward ? next : current) : nil
        hasBack = back != nil
        flap.frame = bounds
        flap.mask = flapMask
        if let back {
            flapContent.contents = back.cgImage
            flapContent.contentsScale = back.scale
            flapContent.contentsGravity = .resize
            flapContent.anchorPoint = .zero
            flapContent.bounds = CGRect(origin: .zero, size: bounds.size)
            flapContent.position = .zero
        } else {
            flapContent.frame = bounds
            flapContent.backgroundColor = turn.paper.cgColor
        }
        flap.addSublayer(flapContent)
        parent.addSublayer(flap)

        flapShade.frame = bounds
        let shade: [UInt32] = hasBack ? [0x30, 0x06, 0x14] : [0x40, 0x0A, 0x22]
        flapShade.colors = shade.map { UIColor.black.withAlphaComponent(CGFloat($0) / 255).cgColor }
        flapShade.locations = [0, 0.35, 1]
        flapShade.mask = flapShadeMask
        parent.addSublayer(flapShade)
    }

    private static func picture(_ image: UIImage, _ bounds: CGRect) -> CALayer {
        let layer = CALayer()
        layer.contents = image.cgImage
        layer.contentsScale = image.scale
        layer.contentsGravity = .resize
        layer.frame = bounds
        return layer
    }

    private func path(_ points: [Vec]) -> CGPath? {
        guard points.count >= 3 else { return nil }
        let p = CGMutablePath()
        p.move(to: CGPoint(x: points[0].x, y: points[0].y))
        for v in points.dropFirst() { p.addLine(to: CGPoint(x: v.x, y: v.y)) }
        p.closeSubpath()
        return p
    }

    private func unit(_ v: Vec) -> CGPoint {
        CGPoint(x: v.x / max(1, Double(bounds.width)), y: v.y / max(1, Double(bounds.height)))
    }

    /// The turn at time `t` (0 = not started, 1 = turned).
    func show(_ t: Double) {
        let frame = CurlGeometry.frame(leaf, t)
        let empty = CGPath(rect: .zero, transform: nil)
        baseMask.path = path(turn.forward ? frame.flat : frame.lifted) ?? empty
        let liftedPath = path(frame.lifted)
        let flapPath = path(frame.flap)
        guard let foldPoint = frame.foldPoint, let normal = frame.foldNormal else {
            shadow.isHidden = true
            flap.isHidden = true
            flapShade.isHidden = true
            return
        }
        // The shadow the curled paper casts on the page under it, along the fold.
        let shadowWidth = min(frame.depth, max(Double(bounds.width), Double(bounds.height)) * 0.05)
        if shadowWidth >= 1, let liftedPath {
            shadow.isHidden = false
            shadowMask.path = liftedPath
            shadow.startPoint = unit(foldPoint)
            shadow.endPoint = unit(foldPoint + normal * shadowWidth)
        } else {
            shadow.isHidden = true
        }
        guard let flapPath else {
            flap.isHidden = true
            flapShade.isHidden = true
            return
        }
        flap.isHidden = false
        flapMask.path = flapPath
        if hasBack {
            let m = frame.backToFlap
            flapContent.setAffineTransform(CGAffineTransform(a: m.a, b: m.b, c: m.c, d: m.d, tx: m.tx, ty: m.ty))
        }
        // The paper bends at the fold: darker there, lighter across the flap, a little darker at its end.
        flapShade.isHidden = false
        flapShadeMask.path = flapPath
        flapShade.startPoint = unit(foldPoint)
        flapShade.endPoint = unit(foldPoint - normal * frame.depth)
    }
}
