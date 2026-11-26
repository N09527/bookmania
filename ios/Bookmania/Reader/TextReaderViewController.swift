import BookmaniaCore
import SwiftUI
import UIKit
import WebKit

/// The text reader (EbookReaderActivity on Android): the shared shell lays out one book document in a WKWebView; this
/// controller opens documents, applies the typesetting settings, turns pages with taps, swipes and a hardware
/// keyboard, moves to the next or previous document at the ends, and shows the page number. The settings panel, the
/// fold's shadow and the input are in the extensions of this class.
final class TextReaderViewController: UIViewController, WKNavigationDelegate {
    let chapter: LocalChapter
    let onClose: () -> Void
    let env = AppEnvironment.shared

    var webView: WKWebView!
    let schemeHandler = ReaderSchemeHandler()
    /// The fold's shadow between two columns, over the page.
    let gutterView = GutterShadowView()
    let touchLayer = UIView()
    let topBar = UIView()
    let bottomBar = UIView()
    let titleLabel = UILabel()
    let pageLabel = UILabel()
    let toolbarButtons = UIStackView()
    let spinner = UIActivityIndicatorView(style: .large)
    let messageView = UIStackView()

    var publication: Publication?
    /// The whole spine, as on Android: saved positions use its indices; page turns only go through linear items.
    var spine: [SpineItem] = []
    var spineIndex = 0
    lazy var bookKey = BookKey(chapter)
    var settings = EbookSettings()
    /// The book's own writing mode, used while the setting is "book".
    var bookVertical = false
    /// Resolved writing mode of the page.
    var vertical = false
    /// Whether the next page is on the left (taps, swipes and arrow keys follow it).
    var rtl = false
    var shellLoaded = false
    var busy = true
    var page = 0
    var pages = 1
    /// Pages shown side by side (2 with two columns).
    var columns = 1
    var chromeVisible = false
    var layoutTask: Task<Void, Never>?
    var turnTask: Task<Void, Never>?
    var resizeTask: Task<Void, Never>?
    /// Settings the shell lays out with now; a change lays the open document out again.
    var appliedJSON: String?
    var pendingRelayout = false
    /// Where the shell puts the gap between two columns (CSS px = points of the web view), or nil with one column.
    var gutterCSS: Double?
    /// The largest left + right margins that keep two columns, when the settings ask for two here.
    var marginMost: Int?

    // The typesetting panel (TextReaderViewController+Settings).
    var panelModel: EbookSettingsPanelModel?
    var panelHost: UIHostingController<SettingsPanelContainer>?
    var panelConstraints: [NSLayoutConstraint] = []

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

    // The reader takes the keyboard (the page keys), not the web view.
    override var canBecomeFirstResponder: Bool { true }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
        if env.readerPreferences.keepScreenOn { UIApplication.shared.isIdleTimerDisabled = true }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        UIApplication.shared.isIdleTimerDisabled = false
    }

    // MARK: Setup

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = backgroundColor()

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
        gutterView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(gutterView)
        let fontStore = env.fontStore
        schemeHandler.fontFile = { fontStore.file($0) }

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
            gutterView.topAnchor.constraint(equalTo: webView.topAnchor),
            gutterView.bottomAnchor.constraint(equalTo: webView.bottomAnchor),
            gutterView.leadingAnchor.constraint(equalTo: webView.leadingAnchor),
            gutterView.trailingAnchor.constraint(equalTo: webView.trailingAnchor),
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

        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _: UITraitCollection) in
            self.appearanceChanged()
        }

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
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        toolbarButtons.axis = .horizontal
        toolbarButtons.spacing = 4
        toolbarButtons.translatesAutoresizingMaskIntoConstraints = false
        toolbarButtons.isHidden = true // until a book is open
        addToolbarButton("textformat.size", label: "Typesetting", action: #selector(settingsTapped))
        pageLabel.translatesAutoresizingMaskIntoConstraints = false
        pageLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .regular)
        pageLabel.textAlignment = .center
        topBar.addSubview(close)
        topBar.addSubview(titleLabel)
        topBar.addSubview(toolbarButtons)
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
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: toolbarButtons.leadingAnchor, constant: -8),
            titleLabel.centerYAnchor.constraint(equalTo: close.centerYAnchor),
            toolbarButtons.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -8),
            toolbarButtons.centerYAnchor.constraint(equalTo: close.centerYAnchor),
            bottomBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            bottomBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomBar.topAnchor.constraint(equalTo: guide.bottomAnchor, constant: -48),
            pageLabel.centerXAnchor.constraint(equalTo: bottomBar.centerXAnchor),
            pageLabel.topAnchor.constraint(equalTo: bottomBar.topAnchor, constant: 12),
        ])
    }

    func addToolbarButton(_ symbol: String, label: String, action: Selector) {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: symbol), for: .normal)
        button.accessibilityLabel = NSLocalizedString(label, comment: "")
        button.addTarget(self, action: action, for: .touchUpInside)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 44).isActive = true
        button.heightAnchor.constraint(equalToConstant: 44).isActive = true
        toolbarButtons.addArrangedSubview(button)
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
        if publication.spine.isEmpty {
            publication.close()
            spinner.stopAnimating()
            showMessage(title: NSLocalizedString("Cannot open this book", comment: ""),
                        message: NSLocalizedString("ebook_no_content", comment: ""))
            return
        }
        self.publication = publication
        schemeHandler.publication = publication
        spine = publication.spine
        bookVertical = publication.writingModeHint == .vertical
        settings = env.settingsStore.effective(bookKey)
        resolveMode()
        if let title = publication.metadata.title { titleLabel.text = title }
        toolbarButtons.isHidden = false
        if shellLoaded { openInitial() }
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

    func showMessage(title: String, message: String) {
        busy = true
        closePanel()
        webView.isHidden = true
        gutterView.show(nil)
        toolbarButtons.isHidden = true
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
        if publication != nil { openInitial() }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        shellFailed(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        shellFailed(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // The web content process crashed or was ended by the system; this web view shows nothing any more.
        spinner.stopAnimating()
        showMessage(title: NSLocalizedString("Cannot open this book", comment: ""), message: "WebKit content process ended")
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

    // MARK: Navigation

    /// Indices of the linear spine items (page turns go through these); all items when none is linear.
    func linearIndices() -> [Int] {
        let all = spine.indices.filter { spine[$0].linear }
        return all.isEmpty ? Array(spine.indices) : all
    }

    /// Opens the first document (a saved position comes with the reading progress, iOS stage 3).
    func openInitial() {
        openSpine(linearIndices().first ?? 0, target: "'start'")
    }

    func openSpine(_ index: Int, target: String) {
        guard index >= 0, index < spine.count else { return }
        spineIndex = index
        busy = true
        pendingRelayout = false
        let url = ReaderURLs.bookURL(spine[index].href)
        let json = settingsJSON()
        appliedJSON = json
        let script = "String(window.__reader.open(\(ShellSettings.jsString(url)), \(json), \(target)))"
        webView.evaluateJavaScript(script, completionHandler: nil)
        awaitLayout()
    }

    struct Status {
        var ready: Bool
        var error: String?
        var page: Int
        var pages: Int
        var cols: Int
        var seq: Int
        var gutter: Double?
        var twoWanted: Bool
        var marginMost: Int?
    }

    func eval(_ script: String) async -> String? {
        await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(script) { result, _ in
                continuation.resume(returning: result as? String)
            }
        }
    }

    func status() async -> Status? {
        guard let text = await eval("JSON.stringify(window.__reader ? window.__reader.status() : null)"),
              let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return nil }
        return Status(
            ready: object["ready"] as? Bool ?? false,
            error: object["error"] as? String,
            page: object["page"] as? Int ?? 0,
            pages: object["pages"] as? Int ?? 1,
            cols: object["cols"] as? Int ?? 1,
            seq: object["seq"] as? Int ?? -1,
            gutter: (object["gutter"] as? NSNumber)?.doubleValue,
            twoWanted: object["twoWanted"] as? Bool ?? false,
            marginMost: (object["marginMost"] as? NSNumber)?.intValue
        )
    }

    /// Takes the page, the page count, the columns and the gap between them from a finished layout.
    func apply(_ s: Status) {
        page = s.page
        pages = max(1, s.pages)
        columns = max(1, s.cols)
        gutterCSS = s.gutter.flatMap { $0.isFinite ? $0 : nil }
        // The panel limits the side margins to what keeps two columns on this screen.
        marginMost = s.twoWanted ? s.marginMost.flatMap { $0 >= 0 ? $0 : nil } : nil
        showGutter()
        updatePageLabel()
        if let model = panelModel, model.marginMost != marginMost { model.marginMost = marginMost }
    }

    /// Polls the shell until the current layout is finished, then shows the page.
    func awaitLayout() {
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
                if elapsed > 0.3 { self.spinner.startAnimating() }
                if let s = current, s.ready {
                    self.spinner.stopAnimating()
                    self.busy = false
                    if let error = s.error {
                        self.showMessage(title: NSLocalizedString("Cannot open this book", comment: ""), message: error)
                        return
                    }
                    self.apply(s)
                    if self.pendingRelayout {
                        self.pendingRelayout = false
                        self.applySettings()
                    } else {
                        self.layoutFinished()
                    }
                    if !self.isFirstResponder { self.becomeFirstResponder() }
                    return
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    /// A layout of the open document is shown (an open, a relayout, a page turn to another document).
    func layoutFinished() {}

    /// Waits for the relayout the shell starts by itself after the viewport changed (its layout counter `seq` moves
    /// on), then takes the new page numbers. If no new layout shows up within 15 seconds, the current one is taken.
    func refreshAfterResize() {
        guard publication != nil, shellLoaded, messageView.isHidden else { return }
        resizeTask?.cancel()
        gutterView.show(nil) // until the new layout tells where the columns are
        resizeTask = Task { [weak self] in
            guard let self else { return }
            let before = await self.status()?.seq ?? -1
            let start = Date()
            while !Task.isCancelled, Date().timeIntervalSince(start) < 60 {
                try? await Task.sleep(nanoseconds: 200_000_000)
                if Task.isCancelled || self.busy { continue }
                guard let s = await self.status() else { continue }
                if s.error != nil { return }
                if s.ready && (s.seq != before || Date().timeIntervalSince(start) > 15) {
                    self.apply(s)
                    self.layoutFinished()
                    return
                }
            }
        }
    }

    func updatePageLabel() {
        // Two columns: both pages of the spread, e.g. "3–4/35" (the last spread can hold one page).
        let shown = columns > 1 && page + 2 <= pages ? "\(page + 1)–\(page + 2)" : "\(page + 1)"
        pageLabel.text = "\(spineIndex + 1)/\(spine.count) · \(shown)/\(pages)"
    }

    // MARK: Chrome

    func setChrome(visible: Bool) {
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

    func toast(_ text: String) {
        let label = PaddedLabel()
        label.text = text
        label.numberOfLines = 0
        label.textAlignment = .center
        label.textColor = .white
        label.backgroundColor = UIColor.black.withAlphaComponent(0.75)
        label.layer.cornerRadius = 10
        label.clipsToBounds = true
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -48),
            label.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -60),
        ])
        UIView.animate(withDuration: 0.3, delay: 1.8, options: []) {
            label.alpha = 0
        } completion: { _ in
            label.removeFromSuperview()
        }
    }

    @objc func closeTapped() {
        layoutTask?.cancel()
        resizeTask?.cancel()
        onClose()
    }

    // MARK: Size and appearance

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        // The shell lays the document out again by itself when the viewport changes; page, page count and columns
        // change with it, so they are read again once it is done.
        refreshAfterResize()
        coordinator.animate(alongsideTransition: { [weak self] _ in
            self?.layoutPanel(for: size)
        })
    }

    private func appearanceChanged() {
        view.backgroundColor = backgroundColor()
        applySettings()
    }

    /// The reader's colours for the setting and the system appearance.
    func readerTheme() -> ReaderTheme {
        ReaderTheme.resolve(setting: env.readerPreferences.readerTheme, systemDark: traitCollection.userInterfaceStyle == .dark)
    }

    func backgroundColor() -> UIColor {
        let (r, g, b) = ReaderTheme.components(readerTheme().backgroundHex)
        return UIColor(red: r, green: g, blue: b, alpha: 1)
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

    override func textRect(forBounds bounds: CGRect, limitedToNumberOfLines numberOfLines: Int) -> CGRect {
        let inner = super.textRect(forBounds: bounds.inset(by: UIEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)), limitedToNumberOfLines: numberOfLines)
        return inner.inset(by: UIEdgeInsets(top: -8, left: -16, bottom: -8, right: -16))
    }
}
