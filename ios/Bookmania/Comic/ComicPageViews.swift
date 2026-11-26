import BookmaniaCore
import UIKit

/// Decodes the pages of an image book off the main thread, keeping a few decoded pages.
final class ComicImageLoader: @unchecked Sendable {
    private let book: ComicBook
    private let cache = NSCache<NSNumber, UIImage>()
    private let queue = DispatchQueue(label: "bookmania.comic.images", qos: .userInitiated, attributes: .concurrent)
    private let lock = NSLock()
    private var waiting: [Int: [(UIImage?) -> Void]] = [:]

    init(book: ComicBook) {
        self.book = book
        cache.countLimit = 10
    }

    func cached(_ index: Int) -> UIImage? { cache.object(forKey: NSNumber(value: index)) }

    /// Calls `done` on the main thread with the decoded page (nil when it cannot be read).
    func load(_ index: Int, _ done: @escaping (UIImage?) -> Void) {
        if let image = cached(index) {
            done(image)
            return
        }
        lock.lock()
        if waiting[index] != nil {
            waiting[index]!.append(done)
            lock.unlock()
            return
        }
        waiting[index] = [done]
        lock.unlock()
        let book = self.book
        queue.async { [weak self] in
            var image: UIImage?
            if let bytes = try? book.pageData(index), let decoded = UIImage(data: Data(bytes)) {
                image = decoded.preparingForDisplay() ?? decoded
            }
            DispatchQueue.main.async {
                guard let self else { return }
                if let image { self.cache.setObject(image, forKey: NSNumber(value: index)) }
                self.lock.lock()
                let callbacks = self.waiting.removeValue(forKey: index) ?? []
                self.lock.unlock()
                callbacks.forEach { $0(image) }
            }
        }
    }

    /// Starts decoding pages that will be shown soon.
    func preload(_ indices: [Int]) {
        for i in indices { load(i) { _ in } }
    }
}

/// One spread of the paged modes: one page, or two side by side (the first on the right for right-to-left books),
/// with pinch zoom and the fold's shadow between two pages.
final class SpreadViewController: UIViewController, UIScrollViewDelegate {
    let spreadIndex: Int
    let pages: [Int]
    private let loader: ComicImageLoader
    private let rtl: Bool
    private let gutter: Bool
    private let background: UIColor
    private let scroll = UIScrollView()
    private let content = UIView()
    private var imageViews: [UIImageView] = []
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let gutterView = GutterShadowView()

    init(spreadIndex: Int, pages: [Int], loader: ComicImageLoader, rtl: Bool, gutter: Bool, background: UIColor) {
        self.spreadIndex = spreadIndex
        self.pages = pages
        self.loader = loader
        self.rtl = rtl
        self.gutter = gutter
        self.background = background
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = background
        scroll.frame = view.bounds
        scroll.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 4
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.delegate = self
        view.addSubview(scroll)
        content.frame = scroll.bounds
        scroll.addSubview(content)
        // The first page sits on the side where reading starts.
        let order = rtl ? pages.reversed() : pages
        for index in order {
            let imageView = UIImageView()
            imageView.contentMode = .scaleAspectFit
            imageView.tag = index
            content.addSubview(imageView)
            imageViews.append(imageView)
        }
        gutterView.isHidden = !(gutter && pages.count == 2)
        content.addSubview(gutterView)
        spinner.hidesWhenStopped = true
        spinner.center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        spinner.autoresizingMask = [.flexibleLeftMargin, .flexibleRightMargin, .flexibleTopMargin, .flexibleBottomMargin]
        view.addSubview(spinner)
        load()
    }

    private func load() {
        var missing = 0
        for imageView in imageViews {
            if let image = loader.cached(imageView.tag) {
                imageView.image = image
            } else {
                missing += 1
                spinner.startAnimating()
                loader.load(imageView.tag) { [weak self, weak imageView] image in
                    imageView?.image = image ?? UIImage(systemName: "exclamationmark.triangle")
                    self?.spinner.stopAnimating()
                    self?.view.setNeedsLayout()
                }
            }
        }
        if missing == 0 { spinner.stopAnimating() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard scroll.zoomScale == 1 else { return }
        content.frame = CGRect(origin: .zero, size: scroll.bounds.size)
        scroll.contentSize = content.bounds.size
        let bounds = content.bounds
        if imageViews.count == 2 {
            // Two pages meet in the middle, each fitted into its half.
            let half = bounds.width / 2
            let left = imageViews[0], right = imageViews[1]
            left.frame = fitted(left.image, in: CGRect(x: 0, y: 0, width: half, height: bounds.height), align: .right)
            right.frame = fitted(right.image, in: CGRect(x: half, y: 0, width: half, height: bounds.height), align: .left)
            gutterView.frame = bounds
            gutterView.show(half)
        } else {
            imageViews.first?.frame = bounds
            gutterView.show(nil)
        }
    }

    private enum Align { case left, right }

    /// The image's frame fitted into `rect`, pushed to one side (so the two pages of a spread touch).
    private func fitted(_ image: UIImage?, in rect: CGRect, align: Align) -> CGRect {
        guard let size = image?.size, size.width > 0, size.height > 0 else { return rect }
        let scale = min(rect.width / size.width, rect.height / size.height)
        let w = size.width * scale, h = size.height * scale
        let x = align == .right ? rect.maxX - w : rect.minX
        return CGRect(x: x, y: rect.minY + (rect.height - h) / 2, width: w, height: h)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { content }

    func resetZoom() { scroll.setZoomScale(1, animated: false) }

    var isZoomed: Bool { scroll.zoomScale > 1.01 }
}

/// A page of the long strip: the image at the full width.
final class StripCell: UITableViewCell {
    static let id = "strip"
    let pageView = UIImageView()
    var index = -1

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = .clear
        pageView.contentMode = .scaleAspectFit
        pageView.frame = contentView.bounds
        pageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentView.addSubview(pageView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func prepareForReuse() {
        super.prepareForReuse()
        pageView.image = nil
        index = -1
    }
}
