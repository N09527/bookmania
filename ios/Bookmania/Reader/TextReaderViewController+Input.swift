import BookmaniaCore
import UIKit

/// Taps, swipes and the hardware keyboard (EbookReaderActivity's TouchListener and dispatchKeyEvent on Android).
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
        // The tap zones of the reader settings, read at each tap so a change applies at once.
        switch env.readerPreferences.navigation.turn(x: point.x / w, y: point.y / h, rtl: rtl) {
        case nil: setChrome(visible: true)
        case let forward?: turn(forward: forward)
        }
    }

    @objc func swiped(_ gesture: UISwipeGestureRecognizer) {
        guard !panelVisible, messageView.isHidden else { return }
        // Pages move with the finger: a swipe towards the side where reading continues turns forward.
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

    var pageKeysActive: Bool { !chromeVisible && !panelVisible && messageView.isHidden }

    @objc func pageKey(_ command: UIKeyCommand) {
        guard pageKeysActive else { return }
        switch command.input ?? "" {
        case UIKeyCommand.inputLeftArrow: turn(forward: rtl)
        case UIKeyCommand.inputRightArrow: turn(forward: !rtl)
        case UIKeyCommand.inputPageUp: turn(forward: false)
        default: turn(forward: true) // space, Page Down
        }
    }

    /// Turns the page, in the open document or into the next / previous linear document at its end.
    func turn(forward: Bool) {
        guard !busy, publication != nil else { return }
        // Turns run one after another and check `busy` again before they start (Android: turnLock), so quick taps
        // or a held key cannot open the next document twice and skip one.
        let previous = turnTask
        turnTask = Task { [weak self] in
            await previous?.value
            guard let self, !self.busy else { return }
            let result = await self.eval(forward ? "String(window.__reader.next())" : "String(window.__reader.prev())")
            switch result {
            case "ok":
                if let s = await self.status() {
                    self.apply(s)
                    self.layoutFinished()
                }
            case "end" where forward:
                if let next = self.linearIndices().first(where: { $0 > self.spineIndex }) {
                    self.openSpine(next, target: "'start'")
                } else {
                    self.toast(NSLocalizedString("End of the book", comment: ""))
                }
            case "start" where !forward:
                if let prev = self.linearIndices().last(where: { $0 < self.spineIndex }) {
                    self.openSpine(prev, target: "'end'")
                } else {
                    self.toast(NSLocalizedString("Beginning of the book", comment: ""))
                }
            default:
                break // the shell is busy: the page did not change
            }
        }
    }
}
