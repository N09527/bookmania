import BookmaniaCore
import UIKit
import WebKit

/// The text reader (EbookReaderActivity on Android, stage 2 scope): the shared shell lays out one book document in a
/// WKWebView; this controller opens documents, turns pages with taps and swipes, moves to the next or previous
/// document at the ends, and shows the page number. Typesetting settings, two columns, page turn animations,
/// positions and the table of contents come in later stages.
final class TextReaderViewController: UIViewController, WKNavigationDelegate {
    private let chapter: LocalChapter
    private let onClose: () -> Void

    private var webView: WKWebView!
    private let schemeHandler = ReaderSchemeHandler()
    private let touchLayer = UIView()
    private let topBar = UIView()
    private let bottomBar = UIView()
    private let titleLabel = UILabel()
    private let pageLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .large)
    private let messageView = UIStackView()

    private var publication: Publication?
    private var spine: [SpineItem] = []
    private var spineIndex = 0
    private var vertical = false
    private var rtl = false
    private var shellLoaded = false
    private var busy = true
    private var page = 0
    private var pages = 1
    private var columns = 1
    private var chromeVisible = false
    private var layoutTask: Task<Void, Never>?

    init(chapter: LocalChapter, onClose: @escaping () -> Void) {
        self.chapter = chapter
        self.onClose = onClose
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        publication?.close()
    }

    override var prefersStatusBarHidden: Bool { !chromeVisible }
    override var prefersHomeIndicatorAutoHidden: Bool { true }

    // MARK: Setup

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.current(traitCollection).background

        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(schemeHandler, forURLScheme: ReaderURLs.scheme)
        config.websiteDataStore = .nonPersistent()
        config.dataDetectorTypes = []
        config.suppressesIncrementalRendering = false
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.allowsLinkPreview = false
        webView.allowsBackForwardNavigationGestures = false
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)

        // All input goes to the native layer (the book frames are passive, as on Android).
        touchLayer.translatesAutoresizingMaskIntoConstraints = false
        touchLayer.backgroundColor = .clear
        view.addSubview(touchLayer)
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        touchLayer.addGestureRecognizer(tap)
        for direction in [UISwipeGestureRecognizer.Direction.left, .right] {
            let swipe = UISwipeGestureRecognizer(target: self, action: #selector(swiped(_:)))
            swipe.direction = direction
            touchLayer.addGestureRecognizer(swipe)
            tap.require(toFail: swipe)
        }

        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: guide.topAnchor),
            webView.bottomAnchor.constraint(equalTo: guide.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            touchLayer.topAnchor.constraint(equalTo: view.topAnchor),
            touchLayer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            touchLayer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            touchLayer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        setUpChrome()
        setUpMessageView()
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.hidesWhenStopped = true
        view.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        spinner.startAnimating()

        loadShell()
        openBook()
    }

    private func setUpChrome() {
        for bar in [topBar, bottomBar] {
            bar.translatesAutoresizingMaskIntoConstraints = false
            bar.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.94)
            bar.alpha = 0
            view.addSubview(bar)
        }
        let close = UIButton(type: .system)
        close.setImage(UIImage(systemName: "xmark"), for: .normal)
        close.accessibilityLabel = NSLocalizedString("Close", comment: "")
        close.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        close.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.text = chapter.fileTitle
        pageLabel.translatesAutoresizingMaskIntoConstraints = false
        pageLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .regular)
        pageLabel.textAlignment = .center
        topBar.addSubview(close)
        topBar.addSubview(titleLabel)
        bottomBar.addSubview(pageLabel)
        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: view.topAnchor),
            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topBar.bottomAnchor.constraint(equalTo: guide.topAnchor, constant: 52),
            close.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 8),
            close.bottomAnchor.constraint(equalTo: topBar.bottomAnchor, constant: -6),
            close.widthAnchor.constraint(equalToConstant: 44),
            close.heightAnchor.constraint(equalToConstant: 44),
            titleLabel.leadingAnchor.constraint(equalTo: close.trailingAnchor, constant: 4),
            titleLabel.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -16),
            titleLabel.centerYAnchor.constraint(equalTo: close.centerYAnchor),
            bottomBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            bottomBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomBar.topAnchor.constraint(equalTo: guide.bottomAnchor, constant: -48),
            pageLabel.centerXAnchor.constraint(equalTo: bottomBar.centerXAnchor),
            pageLabel.topAnchor.constraint(equalTo: bottomBar.topAnchor, constant: 12),
        ])
    }

    private func setUpMessageView() {
        messageView.axis = .vertical
        messageView.spacing = 12
        messageView.alignment = .center
        messageView.isHidden = true
        messageView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(messageView)
        NSLayoutConstraint.activate([
            messageView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            messageView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 32),
            messageView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -32),
        ])
    }

    private func loadShell() {
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "bookmania-reader-v1",
            encodedContentRuleList: ReaderURLs.contentRules
        ) { [weak self] list, _ in
            guard let self else { return }
            // Without the rule list the reader does not load anything: it is what keeps books off the network.
            guard let list else {
                self.showMessage(title: NSLocalizedString("Cannot open this book", comment: ""), message: "Content rules")
                return
            }
            self.webView.configuration.userContentController.add(list)
            if let url = URL(string: ReaderURLs.shellURL) { self.webView.load(URLRequest(url: url)) }
        }
    }

    private func openBook() {
        let url = chapter.file
        let ext = url.pathExtension.lowercased()
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let publication = try BookOpener.open(try FileSource(url: url), extension: ext)
                let comic = ext == "epub" && ContentClassifier.classify(publication) == .comic
                await self?.bookOpened(publication, comic: comic)
            } catch {
                await self?.bookFailed(error)
            }
        }
    }

    private func bookOpened(_ publication: Publication, comic: Bool) {
        if comic {
            publication.close()
            spinner.stopAnimating()
            showMessage(title: NSLocalizedString("Picture book", comment: ""),
                        message: NSLocalizedString("comic_reader_later", comment: ""))
            return
        }
        self.publication = publication
        schemeHandler.publication = publication
        spine = publication.spine.filter { $0.linear }
        if spine.isEmpty { spine = publication.spine }
        vertical = publication.writingModeHint == .vertical
        switch publication.readingDirection {
        case .rtl: rtl = true
        case .ltr: rtl = false
        case .default: rtl = vertical
        }
        if let title = publication.metadata.title { titleLabel.text = title }
        if shellLoaded { openSpine(0, target: "'start'") }
    }

    private func bookFailed(_ error: Error) {
        spinner.stopAnimating()
        let bookError = error as? BookError
        switch bookError {
        case let .drmProtected(scheme)?:
            showMessage(title: NSLocalizedString("This book is protected by DRM", comment: ""),
                        message: String(format: NSLocalizedString("drm_message", comment: ""), scheme))
        case .unsupported?:
            showMessage(title: NSLocalizedString("Cannot open this book", comment: ""),
                        message: NSLocalizedString("kfx_message", comment: ""))
        default:
            showMessage(title: NSLocalizedString("Cannot open this book", comment: ""),
                        message: NSLocalizedString("corrupt_message", comment: ""))
        }
    }

    private func showMessage(title: String, message: String) {
        busy = true
        webView.isHidden = true
        messageView.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let titleView = UILabel()
        titleView.text = title
        titleView.font = .preferredFont(forTextStyle: .title3)
        titleView.numberOfLines = 0
        titleView.textAlignment = .center
        let body = UILabel()
        body.text = message
        body.numberOfLines = 0
        body.textAlignment = .center
        body.textColor = .secondaryLabel
        let close = UIButton(configuration: .borderedProminent())
        close.setTitle(NSLocalizedString("Close", comment: ""), for: .normal)
        close.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        [titleView, body, close].forEach(messageView.addArrangedSubview)
        messageView.isHidden = false
        view.bringSubviewToFront(messageView)
    }

    // MARK: Shell

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        shellLoaded = true
        if publication != nil { openSpine(spineIndex, target: "'start'") }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        shellFailed(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        shellFailed(error)
    }

    private func shellFailed(_ error: Error) {
        guard !shellLoaded else { return }
        spinner.stopAnimating()
        showMessage(title: NSLocalizedString("Cannot open this book", comment: ""),
                    message: NSLocalizedString("shell_failed", comment: "") + "\n\n" + error.localizedDescription)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        // Only the shell (main frame) and the book documents (its frames) of this origin may load; links never
        // navigate the reader.
        guard let url = navigationAction.request.url, let route = ReaderURLs.route(url) else { return .cancel }
        if navigationAction.targetFrame?.isMainFrame == true {
            if case .shell = route { return .allow }
            return .cancel
        }
        return navigationAction.targetFrame == nil ? .cancel : .allow
    }

    private func settingsJSON() -> String {
        let theme = Theme.current(traitCollection)
        var s = ShellSettings(vertical: vertical, rtl: rtl)
        s.background = theme.backgroundHex
        s.textColor = theme.textHex
        s.dark = theme.dark
        return s.json()
    }

    private func openSpine(_ index: Int, target: String) {
        guard index >= 0, index < spine.count else { return }
        spineIndex = index
        busy = true
        let url = ReaderURLs.bookURL(spine[index].href)
        let script = "String(window.__reader.open(\(ShellSettings.jsString(url)), \(settingsJSON()), \(target)))"
        webView.evaluateJavaScript(script, completionHandler: nil)
        awaitLayout()
    }

    private struct Status {
        var ready: Bool
        var error: String?
        var page: Int
        var pages: Int
        var cols: Int
    }

    private func eval(_ script: String) async -> String? {
        await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(script) { result, _ in
                continuation.resume(returning: result as? String)
            }
        }
    }

    private func status() async -> Status? {
        guard let text = await eval("JSON.stringify(window.__reader ? window.__reader.status() : null)"),
              let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return nil }
        return Status(
            ready: object["ready"] as? Bool ?? false,
            error: object["error"] as? String,
            page: object["page"] as? Int ?? 0,
            pages: object["pages"] as? Int ?? 1,
            cols: object["cols"] as? Int ?? 1
        )
    }

    /// Polls the shell until the current layout is finished, then shows the page.
    private func awaitLayout() {
        layoutTask?.cancel()
        layoutTask = Task { [weak self] in
            let started = Date()
            var shellRuns = false
            while !Task.isCancelled {
                guard let self else { return }
                let elapsed = Date().timeIntervalSince(started)
                let current = await self.status()
                if current != nil { shellRuns = true }
                if !shellRuns && elapsed > 15 {
                    self.spinner.stopAnimating()
                    self.showMessage(title: NSLocalizedString("Cannot open this book", comment: ""),
                                     message: NSLocalizedString("shell_failed", comment: ""))
                    return
                }
                if elapsed > 90 {
                    self.spinner.stopAnimating()
                    self.showMessage(title: NSLocalizedString("Cannot open this book", comment: ""),
                                     message: NSLocalizedString("layout_timeout", comment: ""))
                    return
                }
                if let s = current, s.ready {
                    self.spinner.stopAnimating()
                    self.busy = false
                    if let error = s.error {
                        self.showMessage(title: NSLocalizedString("Cannot open this book", comment: ""), message: error)
                    } else {
                        self.page = s.page
                        self.pages = max(1, s.pages)
                        self.columns = max(1, s.cols)
                        self.updatePageLabel()
                    }
                    return
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    private func updatePageLabel() {
        let shown = min(pages, page + 1)
        pageLabel.text = "\(shown) / \(pages)    \(spineIndex + 1) / \(spine.count)"
    }

    // MARK: Input

    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        let x = gesture.location(in: touchLayer).x
        let width = touchLayer.bounds.width
        if chromeVisible {
            setChrome(visible: false)
        } else if x < width / 3 {
            turn(forward: rtl)
        } else if x > width * 2 / 3 {
            turn(forward: !rtl)
        } else {
            setChrome(visible: true)
        }
    }

    @objc private func swiped(_ gesture: UISwipeGestureRecognizer) {
        // Pages move with the finger: a swipe towards the side where reading continues turns forward.
        let towardsLeft = gesture.direction == .left
        turn(forward: rtl ? !towardsLeft : towardsLeft)
    }

    private func turn(forward: Bool) {
        guard !busy, publication != nil else { return }
        Task { [weak self] in
            guard let self else { return }
            let result = await self.eval(forward ? "String(window.__reader.next())" : "String(window.__reader.prev())")
            switch result {
            case "ok":
                if let s = await self.status() {
                    self.page = s.page
                    self.pages = max(1, s.pages)
                    self.updatePageLabel()
                }
            case "end" where forward:
                if self.spineIndex + 1 < self.spine.count {
                    self.openSpine(self.spineIndex + 1, target: "'start'")
                } else {
                    self.toast(NSLocalizedString("End of the book", comment: ""))
                }
            case "start" where !forward:
                if self.spineIndex > 0 {
                    self.openSpine(self.spineIndex - 1, target: "'end'")
                } else {
                    self.toast(NSLocalizedString("Beginning of the book", comment: ""))
                }
            default:
                break
            }
        }
    }

    private func setChrome(visible: Bool) {
        chromeVisible = visible
        UIView.animate(withDuration: 0.2) {
            self.topBar.alpha = visible ? 1 : 0
            self.bottomBar.alpha = visible ? 1 : 0
            self.setNeedsStatusBarAppearanceUpdate()
        }
        if visible {
            view.bringSubviewToFront(topBar)
            view.bringSubviewToFront(bottomBar)
        }
    }

    private func toast(_ text: String) {
        let label = PaddedLabel()
        label.text = text
        label.textColor = .white
        label.backgroundColor = UIColor.black.withAlphaComponent(0.75)
        label.layer.cornerRadius = 10
        label.clipsToBounds = true
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -60),
        ])
        UIView.animate(withDuration: 0.3, delay: 1.6, options: []) {
            label.alpha = 0
        } completion: { _ in
            label.removeFromSuperview()
        }
    }

    @objc private func closeTapped() {
        layoutTask?.cancel()
        onClose()
    }

    // MARK: Size and appearance

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in
            // The shell relayouts itself on resize; wait for it, then show the new page numbers.
            guard let self, self.publication != nil, self.shellLoaded else { return }
            self.busy = true
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 300_000_000)
                self?.awaitLayout()
            }
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle else { return }
        view.backgroundColor = Theme.current(traitCollection).background
        guard publication != nil, shellLoaded, !busy else { return }
        busy = true
        webView.evaluateJavaScript("String(window.__reader.relayout(\(settingsJSON())))", completionHandler: nil)
        awaitLayout()
    }
}

/// Reader colours: the light theme, or the dark one of the Android reader (rgb 32,33,37 with #E0E0E0 text).
struct Theme {
    let background: UIColor
    let backgroundHex: String
    let textHex: String
    let dark: Bool

    static func current(_ traits: UITraitCollection) -> Theme {
        if traits.userInterfaceStyle == .dark {
            return Theme(background: UIColor(red: 32 / 255, green: 33 / 255, blue: 37 / 255, alpha: 1),
                         backgroundHex: "#202125", textHex: "#E0E0E0", dark: true)
        }
        return Theme(background: .white, backgroundHex: "#FFFFFF", textHex: "#000000", dark: false)
    }
}

/// A label with some padding, for short messages.
final class PaddedLabel: UILabel {
    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: UIEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)))
    }

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(width: size.width + 32, height: size.height + 16)
    }
}
