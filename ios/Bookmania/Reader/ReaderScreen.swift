import BookmaniaCore
import SwiftUI

/// Presents the reader for a chapter (full screen).
struct ReaderScreen: UIViewControllerRepresentable {
    let chapter: LocalChapter
    let onClose: () -> Void

    func makeUIViewController(context: Context) -> ReaderContainerViewController {
        ReaderContainerViewController(chapter: chapter, onClose: onClose)
    }

    func updateUIViewController(_ uiViewController: ReaderContainerViewController, context: Context) {}
}

/// Holds the reader a chapter needs, and puts another one in its place when the user opens another chapter of the
/// work from the reader (the chapter panel), as Android starts the reader again for it.
final class ReaderContainerViewController: UIViewController {
    private let firstChapter: LocalChapter
    private let onClose: () -> Void
    private var current: UIViewController?

    init(chapter: LocalChapter, onClose: @escaping () -> Void) {
        firstChapter = chapter
        self.onClose = onClose
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        show(firstChapter, switchedFromImages: false)
    }

    override var childForStatusBarHidden: UIViewController? { current }
    override var childForHomeIndicatorAutoHidden: UIViewController? { current }

    /// Opens `chapter` in the reader it needs, replacing the one shown.
    func show(_ chapter: LocalChapter, switchedFromImages: Bool) {
        let child = reader(for: chapter, switchedFromImages: switchedFromImages)
        if let old = current {
            old.willMove(toParent: nil)
            old.view.removeFromSuperview()
            old.removeFromParent()
        }
        addChild(child)
        child.view.frame = view.bounds
        child.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(child.view)
        child.didMove(toParent: self)
        current = child
        setNeedsStatusBarAppearanceUpdate()
        setNeedsUpdateOfHomeIndicatorAutoHidden()
    }

    private func reader(for chapter: LocalChapter, switchedFromImages: Bool) -> UIViewController {
        let open: (LocalChapter, Bool) -> Void = { [weak self] target, switched in self?.show(target, switchedFromImages: switched) }
        switch chapter.kind {
        case .mobi, .azw3:
            return TextReaderViewController(chapter: chapter, switchedFromImages: switchedFromImages, onOpenChapter: open, onClose: onClose)
        case .archive, .folder:
            return ComicReaderViewController(chapter: chapter, onOpenChapter: open, onClose: onClose)
        case .epub:
            switch AppEnvironment.shared.ebookInfo.kind(chapter.id) {
            case EbookInfoCache.kindText?:
                return TextReaderViewController(chapter: chapter, switchedFromImages: switchedFromImages, onOpenChapter: open, onClose: onClose)
            case EbookInfoCache.kindComic?:
                return ComicReaderViewController(chapter: chapter, onOpenChapter: open, onClose: onClose)
            default:
                return ClassifyingViewController(chapter: chapter) { [weak self] in self?.show(chapter, switchedFromImages: switchedFromImages) }
            }
        }
    }
}

/// Decides once which reader an EPUB opens in (EbookRouter on Android): the classification of its content, kept for
/// the file. A file that cannot be read goes to the text reader, which explains why (DRM, damaged).
final class ClassifyingViewController: UIViewController {
    private let chapter: LocalChapter
    private let done: () -> Void

    init(chapter: LocalChapter, done: @escaping () -> Void) {
        self.chapter = chapter
        self.done = done
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let spinner = UIActivityIndicatorView(style: .large)
        spinner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        spinner.startAnimating()
        let file = chapter.file
        let id = chapter.id
        let info = AppEnvironment.shared.ebookInfo
        Task { [weak self] in
            await Task.detached(priority: .userInitiated) {
                do {
                    let publication = try BookOpener.open(try FileSource(url: file), extension: "epub")
                    defer { publication.close() }
                    let comic = ContentClassifier.classify(publication) == .comic
                    info.setAutoKind(id, comic ? EbookInfoCache.kindComic : EbookInfoCache.kindText)
                } catch {
                    // DRM, damaged or unreadable: the text reader explains it (not stored, so a replaced file is
                    // classified again).
                    info.setTransientKind(id, EbookInfoCache.kindText)
                }
            }.value
            self?.done()
        }
    }
}
