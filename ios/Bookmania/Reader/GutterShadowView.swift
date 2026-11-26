import UIKit

/// The shadow in the fold between two facing pages (GutterShadow.kt on Android): a vertical band, darkest on the
/// centre line and fading out to both sides, drawn over the page. It takes no touches.
final class GutterShadowView: UIView {
    /// Half the width of the band. The two columns of the text reader are 40 pt apart, so the darker part stays
    /// between them and only the faint ends reach the text.
    static let halfWidth: CGFloat = 32

    private let gradient = CAGradientLayer()
    /// The centre line shown now (points in this view), or nil when there is no shadow.
    private(set) var centerX: CGFloat?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        backgroundColor = .clear
        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        // Black with these alphas: 0, 2 %, 7 %, 15 %, 25 %, 30 % on the centre line, and back (symmetric).
        let alphas: [CGFloat] = [0x00, 0x05, 0x12, 0x26, 0x40, 0x4D, 0x40, 0x26, 0x12, 0x05, 0x00]
        gradient.colors = alphas.map { UIColor.black.withAlphaComponent($0 / 255).cgColor }
        gradient.locations = [0, 0.15, 0.3, 0.4, 0.47, 0.5, 0.53, 0.6, 0.7, 0.85, 1].map { NSNumber(value: $0) }
        gradient.isHidden = true
        layer.addSublayer(gradient)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Shows the shadow centred on `x` (points in this view), or hides it when `x` is nil.
    func show(_ x: CGFloat?) {
        guard x != centerX else { return }
        centerX = x
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let x = centerX {
            gradient.isHidden = false
            gradient.frame = CGRect(x: x - GutterShadowView.halfWidth, y: 0, width: 2 * GutterShadowView.halfWidth, height: bounds.height)
        } else {
            gradient.isHidden = true
        }
        CATransaction.commit()
    }
}
