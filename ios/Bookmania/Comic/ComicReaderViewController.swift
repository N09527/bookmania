import BookmaniaCore
import SwiftUI
import UIKit

/// The image reader for local image books (ZIP / CBZ archives, folders of images, image EPUBs), as Android's reader
/// for them: paged left to right, right to left or top to bottom, or a long strip; one or two pages (double pages,
/// with the fold's shadow); slides that follow the finger, or a curl for every turn (Bookmania's page curl option);
/// the tap zones and keys of the text reader; the last page read, the read state and the reading time.
final class ComicReaderViewController: UIViewController, UIPageViewControllerDataSource, UIPageViewControllerDelegate,
    UITableViewDataSource, UITableViewDelegate, UIGestureRecognizerDelegate {
    let chapter: LocalChapter
    let onOpenChapter: (LocalChapter, Bool) -> Void
    let onClose: () -> Void
    let env = AppEnvironment.shared

    private var book: ComicBook?
    private var loader: ComicImageLoader?
    private var pageCount = 0
    /// The page shown (the first page of the spread; in the long strip the page at the top).
    private var page = 0
    private var spreads: [[Int]] = []
    private var spreadIndex = 0
    private var mode = ReaderPreferences.ReadingMode.rightToLeft
    private var session: ReadingSession?
    private var lifecycleObservers: [NSObjectProtocol] = []

    private var pager: UIPageViewController?
    private var strip: UITableView?
    /// Height / width of the pages of the long strip, once known.
    private var ratios: [Int: CGFloat] = [:]
    private var pageTurner: PageTurner!
    private var turning = false
    private var swipes: [UISwipeGestureRecognizer] = []

    private let container = UIView()
    private let topBar = UIView()
    private let bottomBar = UIView()
    private let titleLabel = UILabel()
    private let pageLabel = UILabel()
    private let slider = UISlider()
    private let modeButton = UIButton(type: .system)
    private let spinner = UIActivityIndicatorView(style: .large)
    private let messageView = UIStackView()
    private var chromeVisible = false

    init(chapter: LocalChapter, onOpenChapter: @escaping (LocalChapter, Bool) -> Void, onClose: @escaping () -> Void) {
        self.chapter = chapter
        self.onOpenChapter = onOpenChapter
        self.onClose = onClose
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        lifecycleObservers.forEach(NotificationCenter.default.removeObserver)
        book?.close()
    }

    override var prefersStatusBarHidden: Bool { !chromeVisible }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var canBecomeFirstResponder: Bool { true }

    private var prefs: ReaderPreferences { env.readerPreferences }
    private var paged: Bool { mode != ReaderPreferences.ReadingMode.webtoon && mode != ReaderPreferences.ReadingMode.continuousVertical }
    private var rtl: Bool { mode == ReaderPreferences.ReadingMode.rightToLeft }
    private var verticalPager: Bool { mode == ReaderPreferences.ReadingMode.vertical }

    private func background() -> UIColor {
        let theme = ReaderTheme.resolve(setting: prefs.readerTheme, systemDark: traitCollection.userInterfaceStyle == .dark)
        let (r, g, b) = ReaderTheme.components(theme.backgroundHex)
        return UIColor(red: r, green: g, blue: b, alpha: 1)
    }

    // MARK: Setup

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = background()
        container.frame = view.bounds
        container.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(container)
        pageTurner = PageTurner(capture: { [weak self] in await self?.picture() }, awaitDrawn: {
            // The new page is set without animation; two frames later it is on the screen.
            try? await Task.sleep(nanoseconds: 34_000_000)
        })
        pageTurner.overlay.frame = view.bounds
        pageTurner.overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(pageTurner.overlay)
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        tap.delegate = self
        view.addGestureRecognizer(tap)
        setUpChrome()
        setUpMessage()
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.hidesWhenStopped = true
        view.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        spinner.startAnimating()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _: UITraitCollection) in
            self.view.backgroundColor = self.background()
            self.rebuild()
        }
        open()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
        if prefs.keepScreenOn { UIApplication.shared.isIdleTimerDisabled = true }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        UIApplication.shared.isIdleTimerDisabled = false
        pageTurner.end()
        session?.flushTimer()
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
        let chapters = UIButton(type: .system)
        chapters.setImage(UIImage(systemName: "books.vertical"), for: .normal)
        chapters.accessibilityLabel = NSLocalizedString("Chapters", comment: "")
        chapters.addTarget(self, action: #selector(chaptersTapped), for: .touchUpInside)
        modeButton.setImage(UIImage(systemName: "book.pages"), for: .normal)
        modeButton.accessibilityLabel = NSLocalizedString("Reading mode", comment: "")
        modeButton.showsMenuAsPrimaryAction = true
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.text = chapter.fileTitle
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = UIStackView(arrangedSubviews: [close, titleLabel, UIView(), chapters, modeButton])
        row.spacing = 8
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        topBar.addSubview(row)
        pageLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .regular)
        pageLabel.textAlignment = .center
        pageLabel.translatesAutoresizingMaskIntoConstraints = false
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.addTarget(self, action: #selector(sliderMoved), for: .valueChanged)
        slider.addTarget(self, action: #selector(sliderReleased), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        bottomBar.addSubview(pageLabel)
        bottomBar.addSubview(slider)
        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: view.topAnchor),
            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topBar.bottomAnchor.constraint(equalTo: guide.topAnchor, constant: 52),
            row.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -12),
            row.bottomAnchor.constraint(equalTo: topBar.bottomAnchor, constant: -6),
            row.heightAnchor.constraint(equalToConstant: 44),
            close.widthAnchor.constraint(equalToConstant: 44),
            chapters.widthAnchor.constraint(equalToConstant: 44),
            modeButton.widthAnchor.constraint(equalToConstant: 44),
            bottomBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            bottomBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomBar.topAnchor.constraint(equalTo: guide.bottomAnchor, constant: -84),
            pageLabel.topAnchor.constraint(equalTo: bottomBar.topAnchor, constant: 10),
            pageLabel.centerXAnchor.constraint(equalTo: bottomBar.centerXAnchor),
            slider.topAnchor.constraint(equalTo: pageLabel.bottomAnchor, constant: 8),
            slider.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 20),
            slider.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -20),
        ])
    }

    private func setUpMessage() {
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

    private func showMessage(title: String, message: String) {
        spinner.stopAnimating()
        container.isHidden = true
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

    // MARK: Opening

    private func open() {
        let chapter = self.chapter
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> Result<ComicBook, Error> in
                Result { try ComicBooks.open(chapter) }
            }.value
            guard let self else { return }
            switch result {
            case let .failure(error):
                if case let .drmProtected(scheme)? = error as? BookError {
                    self.showMessage(title: NSLocalizedString("This book is protected by DRM", comment: ""),
                                     message: String(format: NSLocalizedString("drm_message", comment: ""), scheme))
                } else {
                    self.showMessage(title: NSLocalizedString("Cannot open this book", comment: ""),
                                     message: NSLocalizedString("image_book_unreadable", comment: ""))
                }
            case let .success(book):
                self.opened(book)
            }
        }
    }

    private func opened(_ book: ComicBook) {
        guard book.pageCount > 0 else {
            book.close()
            if chapter.kind == .epub {
                // An EPUB without pages for the image reader opens as text from now on, with a notice (Android).
                env.ebookInfo.setUserKind(chapter.id, EbookInfoCache.kindText)
                let notice = NSLocalizedString("ebook_no_image_pages", comment: "")
                onOpenChapter(chapter, false)
                DispatchQueue.main.async { UIApplication.shared.topToast(notice) }
                return
            }
            showMessage(title: NSLocalizedString("Cannot open this book", comment: ""), message: NSLocalizedString("No pages found", comment: ""))
            return
        }
        self.book = book
        loader = ComicImageLoader(book: book)
        pageCount = book.pageCount
        spinner.stopAnimating()
        let state = env.library.chapter(chapter.id)
        page = ComicProgress.startPage(state, pageCount: pageCount)
        let work = env.library.work(chapter.id.before("/"))
        let own = (work.viewerFlags ?? 0) & 7
        mode = own != 0 ? own : prefs.defaultReadingMode
        let readerPrefs = prefs
        session = ReadingSession(store: env.library, chapterId: chapter.id, incognito: { readerPrefs.incognitoMode })
        session?.startTimer()
        observeLifecycle()
        updateModeMenu()
        rebuild()
    }

    private func observeLifecycle() {
        let center = NotificationCenter.default
        lifecycleObservers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.session?.flushTimer()
                AppEnvironment.shared.library.flush()
            }
        })
        lifecycleObservers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.session?.startTimer() }
        })
    }

    // MARK: Layout of the pages

    /// Two pages side by side: always, or in landscape for the automatic layout.
    private func doublePages(for size: CGSize) -> Bool {
        guard paged, !verticalPager else { return false }
        switch prefs.pageLayout {
        case 1: return true
        case 2: return size.width > size.height
        default: return false
        }
    }

    private func makeSpreads(double: Bool) -> [[Int]] {
        guard double else { return (0 ..< pageCount).map { [$0] } }
        return stride(from: 0, to: pageCount, by: 2).map { i in i + 1 < pageCount ? [i, i + 1] : [i] }
    }

    /// Builds the viewer for the reading mode and shows `page`.
    private func rebuild(size: CGSize? = nil) {
        guard let loader else { return }
        pageTurner.end()
        pager?.willMove(toParent: nil)
        pager?.view.removeFromSuperview()
        pager?.removeFromParent()
        pager = nil
        strip?.removeFromSuperview()
        strip = nil
        swipes.forEach { view.removeGestureRecognizer($0) }
        swipes = []
        let bounds = CGRect(origin: .zero, size: size ?? view.bounds.size)
        if paged {
            spreads = makeSpreads(double: doublePages(for: bounds.size))
            spreadIndex = spreads.firstIndex { $0.contains(page) } ?? 0
            let pager = UIPageViewController(transitionStyle: .scroll, navigationOrientation: verticalPager ? .vertical : .horizontal,
                                             options: [.interPageSpacing: 12])
            pager.delegate = self
            // With the page curl, every turn is a curl and the page does not follow the finger.
            pager.dataSource = prefs.pagerCurl ? nil : self
            pager.view.backgroundColor = background()
            addChild(pager)
            pager.view.frame = container.bounds
            pager.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            container.addSubview(pager.view)
            pager.didMove(toParent: self)
            pager.setViewControllers([spreadController(spreadIndex)], direction: .forward, animated: false)
            self.pager = pager
            if prefs.pagerCurl {
                let directions: [UISwipeGestureRecognizer.Direction] = verticalPager ? [.up, .down] : [.left, .right]
                for direction in directions {
                    let swipe = UISwipeGestureRecognizer(target: self, action: #selector(swiped(_:)))
                    swipe.direction = direction
                    swipe.delegate = self
                    view.addGestureRecognizer(swipe)
                    swipes.append(swipe)
                }
            }
            loader.preload(neighbours())
        } else {
            let table = UITableView(frame: container.bounds, style: .plain)
            table.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            table.separatorStyle = .none
            table.backgroundColor = background()
            table.dataSource = self
            table.delegate = self
            table.register(StripCell.self, forCellReuseIdentifier: StripCell.id)
            table.contentInsetAdjustmentBehavior = .never
            table.showsVerticalScrollIndicator = false
            container.addSubview(table)
            strip = table
            table.reloadData()
            table.layoutIfNeeded()
            if page > 0 { table.scrollToRow(at: IndexPath(row: page, section: 0), at: .top, animated: false) }
        }
        slider.semanticContentAttribute = rtl ? .forceRightToLeft : .forceLeftToRight
        slider.minimumValue = 0
        slider.maximumValue = Float(max(0, pageCount - 1))
        pageChanged()
    }

    private func spreadController(_ index: Int) -> SpreadViewController {
        SpreadViewController(spreadIndex: index, pages: spreads[index], loader: loader!, rtl: rtl,
                             gutter: prefs.pagerGutterShadow, background: background())
    }

    private func neighbours() -> [Int] {
        let around = [spreadIndex + 1, spreadIndex - 1, spreadIndex + 2].filter { spreads.indices.contains($0) }
        return around.flatMap { spreads[$0] }
    }

    // MARK: Paged mode

    func pageViewController(_ pageViewController: UIPageViewController, viewControllerBefore viewController: UIViewController) -> UIViewController? {
        guard let current = viewController as? SpreadViewController else { return nil }
        // Right to left: the page on the left (reached by swiping right) is the next one.
        let target = rtl ? current.spreadIndex + 1 : current.spreadIndex - 1
        return spreads.indices.contains(target) ? spreadController(target) : nil
    }

    func pageViewController(_ pageViewController: UIPageViewController, viewControllerAfter viewController: UIViewController) -> UIViewController? {
        guard let current = viewController as? SpreadViewController else { return nil }
        let target = rtl ? current.spreadIndex - 1 : current.spreadIndex + 1
        return spreads.indices.contains(target) ? spreadController(target) : nil
    }

    func pageViewController(_ pageViewController: UIPageViewController, didFinishAnimating finished: Bool,
                            previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
        guard completed, let current = pageViewController.viewControllers?.first as? SpreadViewController else { return }
        spreadIndex = current.spreadIndex
        page = spreads[spreadIndex].first ?? 0
        pageChanged()
        loader?.preload(neighbours())
    }

    /// Goes to the spread `target`: a curl, a slide, or at once.
    private func show(spread target: Int, forward: Bool, animated: Bool) {
        guard let pager, spreads.indices.contains(target), !turning else { return }
        let controller = spreadController(target)
        // The direction the new page comes from: the right going forward (the left for right-to-left books).
        let direction: UIPageViewController.NavigationDirection = forward != rtl ? .forward : .reverse
        let curl = animated && prefs.pagerCurl && !UIAccessibility.isReduceMotionEnabled
        if curl {
            turning = true
            let edge: CurlEdge = verticalPager ? .bottom : (rtl ? .left : .right)
            let turn = PageTurner.Turn(style: .curl, edge: edge, spread: spreads[spreadIndex].count == 2 || spreads[target].count == 2,
                                       forward: forward, paper: background())
            Task { [weak self] in
                guard let self else { return }
                let held = await self.pageTurner.hold()
                pager.setViewControllers([controller], direction: direction, animated: false)
                self.spreadIndex = target
                self.page = self.spreads[target].first ?? 0
                self.pageChanged()
                if held { await self.pageTurner.play(turn) }
                self.turning = false
                self.loader?.preload(self.neighbours())
            }
        } else {
            pager.setViewControllers([controller], direction: direction, animated: animated && !UIAccessibility.isReduceMotionEnabled)
            spreadIndex = target
            page = spreads[target].first ?? 0
            pageChanged()
            loader?.preload(neighbours())
        }
    }

    /// A picture of the page shown, for the curl.
    private func picture() async -> UIImage? {
        guard let pageView = pager?.view, pageView.bounds.width > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.opaque = true
        return UIGraphicsImageRenderer(bounds: pageView.bounds, format: format).image { _ in
            _ = pageView.drawHierarchy(in: pageView.bounds, afterScreenUpdates: false)
        }
    }

    // MARK: Long strip

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { pageCount }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        tableView.bounds.width * (ratios[indexPath.row] ?? 1.45)
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: StripCell.id, for: indexPath) as! StripCell
        let index = indexPath.row
        cell.index = index
        loader?.load(index) { [weak self, weak cell, weak tableView] image in
            guard let self, let cell, cell.index == index else { return }
            cell.pageView.image = image
            if let image, image.size.width > 0, self.ratios[index] == nil {
                self.ratios[index] = image.size.height / image.size.width
                // The row takes the page's real height, keeping what is shown where it is.
                UIView.performWithoutAnimation { tableView?.performBatchUpdates(nil) }
            }
        }
        return cell
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard let strip, scrollView === strip else { return }
        let probe = CGPoint(x: 1, y: strip.contentOffset.y + strip.bounds.height / 4)
        if let row = strip.indexPathForRow(at: probe)?.row, row != page {
            page = row
            pageChanged()
        }
    }

    // MARK: Progress

    private func pageChanged() {
        let shown: String
        if paged, spreads.indices.contains(spreadIndex), spreads[spreadIndex].count == 2 {
            shown = "\(spreads[spreadIndex][0] + 1)–\(spreads[spreadIndex][1] + 1)"
        } else {
            shown = "\(page + 1)"
        }
        pageLabel.text = "\(shown) / \(pageCount)"
        if !slider.isTracking { slider.value = Float(page) }
        guard !prefs.incognitoMode else { return }
        let extra = paged && spreads.indices.contains(spreadIndex) && spreads[spreadIndex].count == 2
        ComicProgress.save(env.library, chapterId: chapter.id, page: page, pageCount: pageCount, extraPage: extra)
    }

    @objc private func sliderMoved() {
        let target = Int(slider.value.rounded())
        pageLabel.text = "\(target + 1) / \(pageCount)"
    }

    @objc private func sliderReleased() {
        go(toPage: Int(slider.value.rounded()))
    }

    private func go(toPage target: Int) {
        let clamped = min(max(target, 0), pageCount - 1)
        if paged {
            guard let index = spreads.firstIndex(where: { $0.contains(clamped) }), index != spreadIndex else { return }
            show(spread: index, forward: index > spreadIndex, animated: false)
        } else if let strip {
            strip.scrollToRow(at: IndexPath(row: clamped, section: 0), at: .top, animated: false)
            page = clamped
            pageChanged()
        }
    }

    // MARK: Input

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        // Swipes turn pages only when the page is not zoomed in (then they move the page).
        if gestureRecognizer is UISwipeGestureRecognizer, let current = pager?.viewControllers?.first as? SpreadViewController {
            return !current.isZoomed
        }
        if let touchView = gestureRecognizer.view, gestureRecognizer is UITapGestureRecognizer {
            let point = gestureRecognizer.location(in: touchView)
            // Taps on the bars are the bars' own.
            if chromeVisible && (topBar.frame.contains(point) || bottomBar.frame.contains(point)) { return false }
            if !messageView.isHidden { return false }
        }
        return true
    }

    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        if chromeVisible {
            setChrome(visible: false)
            return
        }
        guard book != nil else {
            setChrome(visible: true)
            return
        }
        let point = gesture.location(in: view)
        let w = max(1, view.bounds.width), h = max(1, view.bounds.height)
        let horizontalRTL = paged && !verticalPager && rtl
        switch prefs.navigation.turn(x: point.x / w, y: point.y / h, rtl: horizontalRTL) {
        case nil: setChrome(visible: true)
        case let forward?: turn(forward: forward)
        }
    }

    @objc private func swiped(_ gesture: UISwipeGestureRecognizer) {
        switch gesture.direction {
        case .left: turn(forward: !rtl)
        case .right: turn(forward: rtl)
        case .up: turn(forward: true)
        case .down: turn(forward: false)
        default: break
        }
    }

    private func turn(forward: Bool) {
        if paged {
            let target = spreadIndex + (forward ? 1 : -1)
            guard spreads.indices.contains(target) else {
                toast(NSLocalizedString(forward ? "End of the book" : "Beginning of the book", comment: ""))
                return
            }
            show(spread: target, forward: forward, animated: true)
        } else if let strip {
            // The long strip moves by three quarters of the screen (Android's webtoon viewer).
            let distance = strip.bounds.height * 0.75 * (forward ? 1 : -1)
            let maxY = max(0, strip.contentSize.height - strip.bounds.height)
            let y = min(max(strip.contentOffset.y + distance, 0), maxY)
            strip.setContentOffset(CGPoint(x: 0, y: y), animated: !UIAccessibility.isReduceMotionEnabled)
        }
    }

    override var keyCommands: [UIKeyCommand]? {
        [UIKeyCommand.inputLeftArrow, UIKeyCommand.inputRightArrow, UIKeyCommand.inputUpArrow, UIKeyCommand.inputDownArrow,
         " ", UIKeyCommand.inputPageDown, UIKeyCommand.inputPageUp].map { input in
            let command = UIKeyCommand(input: input, modifierFlags: [], action: #selector(pageKey(_:)))
            command.wantsPriorityOverSystemBehavior = true
            command.allowsAutomaticMirroring = false
            return command
        }
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(pageKey(_:)) { return !chromeVisible && book != nil && presentedViewController == nil }
        return super.canPerformAction(action, withSender: sender)
    }

    @objc private func pageKey(_ command: UIKeyCommand) {
        switch command.input ?? "" {
        case UIKeyCommand.inputLeftArrow: turn(forward: rtl)
        case UIKeyCommand.inputRightArrow: turn(forward: !rtl)
        case UIKeyCommand.inputUpArrow, UIKeyCommand.inputPageUp: turn(forward: false)
        default: turn(forward: true) // down, space, Page Down
        }
    }

    // MARK: Chrome

    private func setChrome(visible: Bool) {
        if visible { pageTurner.end() }
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

    /// The reading mode for this work (saved in its viewer flags, as on Android), and "open as text" for EPUB.
    private func updateModeMenu() {
        let modes: [(Int, String)] = [
            (ReaderPreferences.ReadingMode.leftToRight, "Paged (left to right)"),
            (ReaderPreferences.ReadingMode.rightToLeft, "Paged (right to left)"),
            (ReaderPreferences.ReadingMode.vertical, "Paged (vertical)"),
            (ReaderPreferences.ReadingMode.webtoon, "Long strip"),
        ]
        var items: [UIMenuElement] = modes.map { value, title in
            UIAction(title: NSLocalizedString(title, comment: ""), state: value == mode ? .on : .off) { [weak self] _ in
                self?.setMode(value)
            }
        }
        if chapter.kind == .epub {
            items.append(UIMenu(options: .displayInline, children: [
                UIAction(title: NSLocalizedString("Open as text", comment: ""), image: UIImage(systemName: "text.alignleft")) { [weak self] _ in
                    guard let self else { return }
                    self.env.ebookInfo.setUserKind(self.chapter.id, EbookInfoCache.kindText)
                    self.session?.flushTimer()
                    self.onOpenChapter(self.chapter, true)
                },
            ]))
        }
        modeButton.menu = UIMenu(title: NSLocalizedString("Reading mode", comment: ""), children: items)
    }

    private func setMode(_ value: Int) {
        mode = value
        let id = chapter.id.before("/")
        env.library.updateWork(id) { w in w.viewerFlags = ((w.viewerFlags ?? 0) & ~7) | value }
        updateModeMenu()
        rebuild()
    }

    @objc private func chaptersTapped() {
        setChrome(visible: false)
        let folder = chapter.file.deletingLastPathComponent()
        let current = chapter.id
        let store = env.library
        Task { [weak self] in
            let work = await Task.detached(priority: .userInitiated) { LocalLibrary.work(at: folder) }.value
            guard let self else { return }
            var host: UIViewController?
            let states = Dictionary(uniqueKeysWithValues: work.chapters.map { ($0.id, store.chapter($0.id)) })
            let panel = ChapterPanelView(chapters: work.chapters, current: current, states: states, onSelect: { [weak self] target in
                host?.dismiss(animated: true) {
                    guard let self, target.id != current else { return }
                    self.session?.flushTimer()
                    self.onOpenChapter(target, false)
                }
            }, onClose: {
                host?.dismiss(animated: true)
            })
            let controller = UIHostingController(rootView: panel)
            controller.modalPresentationStyle = .pageSheet
            controller.sheetPresentationController?.detents = [.medium(), .large()]
            controller.sheetPresentationController?.prefersGrabberVisible = true
            host = controller
            self.present(controller, animated: true)
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
        session?.flushTimer()
        onClose()
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        pageTurner.end()
        // Double pages follow the orientation in the automatic layout.
        let showsTwo = spreads.contains { $0.count == 2 }
        let changes = paged && doublePages(for: size) != showsTwo
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in
            guard let self else { return }
            if changes { self.rebuild(size: size) } else { self.strip?.reloadData() }
        }
    }
}

extension UIApplication {
    /// A short notice over the key window (after a reader was replaced by another).
    func topToast(_ text: String) {
        guard let window = connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first else { return }
        let label = PaddedLabel()
        label.text = text
        label.numberOfLines = 0
        label.textAlignment = .center
        label.textColor = .white
        label.backgroundColor = UIColor.black.withAlphaComponent(0.8)
        label.layer.cornerRadius = 10
        label.clipsToBounds = true
        label.translatesAutoresizingMaskIntoConstraints = false
        window.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: window.centerXAnchor),
            label.widthAnchor.constraint(lessThanOrEqualTo: window.widthAnchor, constant: -48),
            label.bottomAnchor.constraint(equalTo: window.safeAreaLayoutGuide.bottomAnchor, constant: -60),
        ])
        UIView.animate(withDuration: 0.3, delay: 3, options: []) {
            label.alpha = 0
        } completion: { _ in
            label.removeFromSuperview()
        }
    }
}
