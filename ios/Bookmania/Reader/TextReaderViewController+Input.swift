import BookmaniaCore
import UIKit
import WebKit

/// Taps, swipes, the hardware keyboard and page turns (EbookReaderActivity's TouchListener, dispatchKeyEvent and
/// turnPage on Android).
extension TextReaderViewController {

    @objc func tapped(_ gesture: UITapGestureRecognizer) {
        if panelVisible {
            closePanel()
            return
        }
        if chromeVisible {
            setChrome(visible: false)
            return
        }
        guard publication != nil, messageView.isHidden else {
            setChrome(visible: true)
            return
        }
        guard !busy else { return }
        let point = gesture.location(in: touchLayer)
        let w = max(1, touchLayer.bounds.width)
        let h = max(1, touchLayer.bounds.height)
        Task { [weak self] in
            guard let self else { return }
            if let link = await self.link(at: point) {
                self.openLink(link)
                return
            }
            // The tap zones of the reader settings, read at each tap so a change applies at once.
            switch self.env.readerPreferences.navigation.turn(x: point.x / w, y: point.y / h, rtl: self.rtl) {
            case nil: self.setChrome(visible: true)
            case let forward?: self.turn(forward: forward)
            }
        }
    }

    @objc func swiped(_ gesture: UISwipeGestureRecognizer) {
        guard !panelVisible, messageView.isHidden else { return }
        // Swiping right brings in the page on the left, which comes next when pages turn right to left.
        let towardsLeft = gesture.direction == .left
        turn(forward: rtl ? !towardsLeft : towardsLeft)
    }

    /// The page keys of Android's reader: left and right follow the page direction (with right-to-left pages the
    /// left key turns forward), space and Page Down turn forward, Page Up back.
    override var keyCommands: [UIKeyCommand]? {
        [UIKeyCommand.inputLeftArrow, UIKeyCommand.inputRightArrow, " ", UIKeyCommand.inputPageDown, UIKeyCommand.inputPageUp].map { input in
            let command = UIKeyCommand(input: input, modifierFlags: [], action: #selector(pageKey(_:)))
            command.wantsPriorityOverSystemBehavior = true
            command.allowsAutomaticMirroring = false // the book's direction decides, not the interface's
            return command
        }
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        // As on Android, the page keys are left to the system while the bars, the panel or a message are shown.
        if action == #selector(pageKey(_:)) { return pageKeysActive }
        return super.canPerformAction(action, withSender: sender)
    }

    var pageKeysActive: Bool { !chromeVisible && !panelVisible && messageView.isHidden && presentedViewController == nil }

    @objc func pageKey(_ command: UIKeyCommand) {
        guard pageKeysActive else { return }
        switch command.input ?? "" {
        case UIKeyCommand.inputLeftArrow: turn(forward: rtl)
        case UIKeyCommand.inputRightArrow: turn(forward: !rtl)
        case UIKeyCommand.inputPageUp: turn(forward: false)
        default: turn(forward: true) // space, Page Down
        }
    }

    // MARK: Turning

    /// The page turn animation, or nil to turn at once (also while the bars or the panel are shown, or when the system
    /// asks for reduced motion).
    func turnStyle() -> PageTurner.Style? {
        if chromeVisible || panelVisible || !messageView.isHidden || UIAccessibility.isReduceMotionEnabled { return nil }
        switch env.readerPreferences.textPageTurn {
        case ReaderPreferences.pageTurnSlide: return .slide
        case ReaderPreferences.pageTurnCurl: return .curl
        default: return nil
        }
    }

    /// Turns the page, in the open document or into the next / previous linear document at its end. With a page turn
    /// animation the page shown now is held on top (a picture, see PageTurner) while the shell moves on, then slides or
    /// curls away: by the right edge for left-to-right pages, by the left edge for right-to-left pages; with two
    /// columns one page turns about the centre line.
    func turn(forward: Bool) {
        guard !busy, publication != nil else { return }
        // Turns run one after another and check `busy` again before they start (Android: turnLock), so quick taps
        // or a held key cannot open the next document twice and skip one.
        let previous = turnTask
        turnTask = Task { [weak self] in
            await previous?.value
            guard let self, !self.busy else { return }
            let style = self.turnStyle()
            if style == nil { self.pageTurner.end() } // a turn still playing ends before the page changes again
            let held = style != nil ? await self.pageTurner.hold() : false
            guard !self.busy else {
                self.pageTurner.end()
                return
            }
            let turn = held ? style.map { PageTurner.Turn(style: $0, edge: self.rtl ? .left : .right, spread: self.columns == 2,
                                                          forward: forward, paper: self.backgroundColor()) } : nil
            let result = await self.eval(forward ? "String(window.__reader.next())" : "String(window.__reader.prev())")
            switch result {
            case "ok":
                if let s = await self.status() {
                    self.apply(s)
                    Task { await self.capturePosition() }
                }
                if let turn { await self.pageTurner.play(turn) }
            case "end" where forward, "start" where !forward:
                let here = self.spineIndex
                let target = forward ? self.linearIndices().first(where: { $0 > here }) : self.linearIndices().last(where: { $0 < here })
                if let target {
                    if let turn { self.holdUntilLaidOut(turn) }
                    self.openSpine(target, target: forward ? "'start'" : "'end'")
                } else {
                    self.pageTurner.end()
                    self.toast(NSLocalizedString(forward ? "End of the book" : "Beginning of the book", comment: ""))
                }
            default:
                self.pageTurner.end() // the shell is busy: the page did not change
            }
        }
    }

    /// Keeps the old page on top while the next document is laid out, and plays `turn` when it is ready (see
    /// layoutFinished). A slow layout shows the reader (and its progress indicator) after a short while.
    func holdUntilLaidOut(_ turn: PageTurner.Turn) {
        pendingTurn = turn
        pendingTurnTask?.cancel()
        pendingTurnTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled, let self, self.pendingTurn != nil else { return }
            self.pendingTurn = nil
            self.pageTurner.end()
        }
    }

    /// Ends a turn in progress or waiting, showing the page as it is.
    func endTurn() {
        pendingTurn = nil
        pendingTurnTask?.cancel()
        pageTurner?.end()
    }

    /// A picture of the page as shown now, with the fold's shadow when it is shown (the shadow is a view above the web
    /// view, which the web view's snapshot does not include).
    func pagePicture() async -> UIImage? {
        let config = WKSnapshotConfiguration()
        config.afterScreenUpdates = true
        let image: UIImage? = await withCheckedContinuation { continuation in
            webView.takeSnapshot(with: config) { image, _ in continuation.resume(returning: image) }
        }
        guard let image else { return nil }
        let size = webView.bounds.size
        guard image.size.width > 0, abs(image.size.width - size.width) < 1, abs(image.size.height - size.height) < 1 else { return nil }
        // The page's own background under the picture, so a transparent snapshot does not show what lies beneath.
        let background = backgroundColor()
        let gutter = gutterView.centerX
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            background.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            image.draw(in: CGRect(origin: .zero, size: size))
            if let gutter { GutterShadowView.draw(in: context.cgContext, centerX: gutter, height: size.height) }
        }
    }

    /// Waits until the web view has drawn what the shell shows now: two animation frames of the page (or a while).
    func awaitPageDrawn() async {
        let script = "await new Promise(function (r) { requestAnimationFrame(function () { requestAnimationFrame(r); }); }); return true;"
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var resumed = false
            let finish = {
                if !resumed {
                    resumed = true
                    continuation.resume()
                }
            }
            webView.callAsyncJavaScript(script, arguments: [:], in: nil, in: .page) { _ in finish() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { finish() }
        }
    }
}
