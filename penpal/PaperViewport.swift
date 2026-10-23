import UIKit

/// Page coordinates stay fixed while the viewport fits the page to the window.
/// Applying one transform to the entire editor keeps ink, ruling, typed replies,
/// and embedded blocks in the same coordinate system without rewriting data.
final class PaperViewport: UIView {
    let paperView = MagicPaperView()
    var pageWidth: CGFloat = 768 {
        didSet {
            if oldValue != pageWidth { setNeedsLayout() }
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        addSubview(paperView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0,
              pageWidth.isFinite, pageWidth > 0 else { return }
        let scale = bounds.width / pageWidth
        paperView.bounds = CGRect(x: 0, y: 0, width: pageWidth, height: bounds.height / scale)
        paperView.center = CGPoint(x: bounds.midX, y: bounds.midY)
        paperView.transform = CGAffineTransform(scaleX: scale, y: scale)
        paperView.layoutIfNeeded()
    }
}
