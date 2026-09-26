import UIKit

/// Explicitly sized annotation canvas. Mapbox measures with `systemLayoutSizeFitting`, which must not
/// inherit the map's changing safe area or its full viewport size as the camera moves.
final class MapAnnotationContainer: UIView {
    var contentSize: CGSize {
        didSet {
            invalidateIntrinsicContentSize()
            setNeedsLayout()
        }
    }
    private let content: UIView

    init(content: UIView, size: CGSize) {
        self.content = content
        contentSize = size
        super.init(frame: CGRect(origin: .zero, size: size))
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
        clipsToBounds = false
        addSubview(content)
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: CGSize { contentSize }
    override func sizeThatFits(_ size: CGSize) -> CGSize { contentSize }
    override func systemLayoutSizeFitting(_ targetSize: CGSize) -> CGSize { contentSize }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Position is owned only by Mapbox. Never animate the content independently of the map frame.
        UIView.performWithoutAnimation { content.frame = bounds }
    }
}
