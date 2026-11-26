import BookmaniaCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Where the typesetting panel sits: at the bottom in portrait; in landscape a full-height side panel, on the left for
/// vertical text (whose pages start on the right) so the beginning of the page stays visible, as on Android.
enum PanelPlacement { case bottom, left, right }

/// The panel with its background: rounded on the side that faces the page.
struct SettingsPanelContainer: View {
    @ObservedObject var model: EbookSettingsPanelModel
    let placement: PanelPlacement

    var body: some View {
        EbookSettingsPanel(model: model)
            .background {
                shape
                    .fill(Color(uiColor: .systemBackground))
                    .shadow(color: .black.opacity(0.25), radius: 8)
                    .ignoresSafeArea()
            }
    }

    private var shape: UnevenRoundedRectangle {
        switch placement {
        case .bottom: return UnevenRoundedRectangle(topLeadingRadius: 16, topTrailingRadius: 16)
        case .left: return UnevenRoundedRectangle(bottomTrailingRadius: 16, topTrailingRadius: 16)
        case .right: return UnevenRoundedRectangle(topLeadingRadius: 16, bottomLeadingRadius: 16)
        }
    }
}

extension TextReaderViewController: UIDocumentPickerDelegate {

    // MARK: Settings

    func resolveMode() {
        vertical = settings.vertical(bookVertical: bookVertical)
        rtl = settings.rightToLeft(vertical: vertical)
    }

    /// What the shell lays out with; "book" values are null, so the book's own styles stay.
    func settingsJSON() -> String {
        let font = env.fontStore.find(settings.font).map { ReaderURLs.fontURL($0.id) }
        return ShellSettings(settings: settings, vertical: vertical, rtl: rtl, theme: readerTheme(), importedFontURL: font).json()
    }

    /// Lays the open document out again if what the shell uses changed; it returns to the same character.
    func applySettings() {
        guard publication != nil, shellLoaded, messageView.isHidden else { return }
        let json = settingsJSON()
        if json == appliedJSON { return }
        if busy {
            pendingRelayout = true
            return
        }
        busy = true
        Task { [weak self] in
            guard let self else { return }
            if await self.eval("String(window.__reader.relayout(\(json)))") == "true" {
                self.appliedJSON = json
                self.awaitLayout()
            } else {
                self.busy = false
            }
        }
    }

    /// Re-reads the effective settings after a change and applies them to the page.
    func refreshSettings() {
        settings = env.settingsStore.effective(bookKey)
        resolveMode()
        if let model = panelModel { fillPanel(model, scope: model.scope) }
        applySettings()
    }

    // MARK: Gutter shadow

    /// The fold's shadow on the gap between the two columns, when there are two and the setting is on. A CSS px of
    /// the page is a point of the web view.
    func showGutter() {
        if let center = gutterCSS, env.readerPreferences.textGutterShadow, messageView.isHidden {
            gutterView.show(CGFloat(center))
        } else {
            gutterView.show(nil)
        }
    }

    // MARK: Panel

    @objc func settingsTapped() {
        guard publication != nil, messageView.isHidden else { return }
        setChrome(visible: false)
        showPanel(env.settingsStore.initialScope(bookKey))
    }

    var panelVisible: Bool { panelHost != nil }

    /// Shows (or refreshes) the panel for `scope`.
    func showPanel(_ scope: SettingsScope) {
        let model = panelModel ?? makePanelModel()
        fillPanel(model, scope: scope)
        guard panelHost == nil else { return }
        let host = UIHostingController(rootView: SettingsPanelContainer(model: model, placement: placement(for: view.bounds.size)))
        // The panel moves above the keyboard itself (its bottom follows the keyboard), so the hosted view does not.
        host.safeAreaRegions = .container
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(host)
        view.addSubview(host.view)
        host.didMove(toParent: self)
        panelHost = host
        view.keyboardLayoutGuide.usesBottomSafeArea = false
        layoutPanel(for: view.bounds.size)
    }

    func closePanel() {
        guard let host = panelHost else { return }
        host.view.endEditing(true)
        host.willMove(toParent: nil)
        host.view.removeFromSuperview()
        host.removeFromParent()
        NSLayoutConstraint.deactivate(panelConstraints)
        panelConstraints = []
        panelHost = nil
        panelModel = nil
        becomeFirstResponder()
    }

    func placement(for size: CGSize) -> PanelPlacement {
        if size.width <= size.height { return .bottom }
        return vertical ? .left : .right
    }

    func layoutPanel(for size: CGSize) {
        guard let host = panelHost, let model = panelModel else { return }
        let placement = placement(for: size)
        host.rootView = SettingsPanelContainer(model: model, placement: placement)
        NSLayoutConstraint.deactivate(panelConstraints)
        let panel = host.view!
        let keyboardTop = view.keyboardLayoutGuide.topAnchor
        switch placement {
        case .bottom:
            // Keep most of the page visible above the panel.
            let height = min(size.height * 0.62, 150 + size.height * 0.3)
            panelConstraints = [
                panel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                panel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                panel.bottomAnchor.constraint(equalTo: keyboardTop),
                panel.heightAnchor.constraint(equalToConstant: height),
                panel.topAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.topAnchor),
            ]
            panelConstraints[3].priority = .defaultHigh
        case .left, .right:
            let width = min(420, size.width * 0.5)
            panelConstraints = [
                panel.topAnchor.constraint(equalTo: view.topAnchor),
                panel.bottomAnchor.constraint(equalTo: keyboardTop),
                panel.widthAnchor.constraint(equalToConstant: width),
                placement == .left
                    ? panel.leftAnchor.constraint(equalTo: view.leftAnchor)
                    : panel.rightAnchor.constraint(equalTo: view.rightAnchor),
            ]
        }
        NSLayoutConstraint.activate(panelConstraints)
        view.bringSubviewToFront(panel)
    }

    private func makePanelModel() -> EbookSettingsPanelModel {
        let model = EbookSettingsPanelModel()
        model.onScopeChange = { [weak self] scope in self?.showPanel(scope) }
        model.onSet = { [weak self] key, value in
            guard let self, let scope = self.panelModel?.scope else { return }
            self.env.settingsStore.set(scope, self.bookKey, key, value)
            self.refreshSettings()
        }
        model.onResetScope = { [weak self] in
            guard let self, let scope = self.panelModel?.scope else { return }
            self.env.settingsStore.clear(scope, self.bookKey)
            self.refreshSettings()
        }
        model.onImportFont = { [weak self] in self?.importFont() }
        model.onDeleteFont = { [weak self] font in self?.confirmDeleteFont(font) }
        model.onPageTurn = { [weak self] value in
            guard let self else { return }
            // One setting for all books, outside the three levels.
            self.env.readerPreferences.textPageTurn = value
            self.panelModel?.pageTurn = self.env.readerPreferences.textPageTurn
        }
        model.onGutterShadow = { [weak self] value in
            guard let self else { return }
            self.env.readerPreferences.textGutterShadow = value
            self.panelModel?.gutterShadow = value
            self.showGutter()
        }
        model.onClose = { [weak self] in self?.closePanel() }
        panelModel = model
        return model
    }

    func fillPanel(_ model: EbookSettingsPanelModel, scope: SettingsScope) {
        let store = env.settingsStore
        model.settings = store.resolvedAt(scope, bookKey)
        model.scope = scope
        model.scopeHasValues = !store.levelValues(scope, bookKey).isEmpty
        model.overridden = store.overriddenBelow(scope, bookKey)
        model.fonts = env.fontStore.list()
        model.pageTurn = env.readerPreferences.textPageTurn
        model.gutterShadow = env.readerPreferences.textGutterShadow
        model.marginMost = marginMost
    }

    // MARK: Fonts

    func importFont() {
        // Font files often come without a specific type; the content is checked instead.
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        let store = env.fontStore
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> Result<FontStore.Pending, Error> in
                Result { try store.read(url) }
            }.value
            try? FileManager.default.removeItem(at: url) // the picker's copy
            guard let self else { return }
            switch result {
            case let .failure(error):
                self.toast(NSLocalizedString("ebook_font_invalid", comment: "") + (error is InvalidFontError ? "" : "\n\(error.localizedDescription)"))
            case let .success(pending):
                if pending.info.supportsVertical {
                    self.saveFont(pending)
                    return
                }
                var missing = [String]()
                if !pending.info.hasVerticalMetrics { missing.append("vhea/vmtx") }
                if !pending.info.hasVerticalGlyphs { missing.append("vert/vrt2") }
                let alert = UIAlertController(
                    title: pending.name,
                    message: String(format: NSLocalizedString("ebook_font_no_vertical", comment: ""), missing.joined(separator: ", ")),
                    preferredStyle: .alert
                )
                alert.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: ""), style: .cancel))
                alert.addAction(UIAlertAction(title: NSLocalizedString("Import", comment: ""), style: .default) { [weak self] _ in
                    self?.saveFont(pending)
                })
                self.present(alert, animated: true)
            }
        }
    }

    private func saveFont(_ pending: FontStore.Pending) {
        let store = env.fontStore
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> Result<ImportedFont, Error> in
                Result { try store.save(pending) }
            }.value
            guard let self else { return }
            switch result {
            case let .failure(error):
                self.toast(error.localizedDescription)
            case let .success(font):
                self.toast(String(format: NSLocalizedString("ebook_font_imported", comment: ""), font.name))
                if let model = self.panelModel { self.fillPanel(model, scope: model.scope) }
            }
        }
    }

    private func confirmDeleteFont(_ font: ImportedFont) {
        let alert = UIAlertController(title: nil, message: String(format: NSLocalizedString("ebook_font_delete_confirm", comment: ""), font.name),
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: ""), style: .cancel))
        alert.addAction(UIAlertAction(title: NSLocalizedString("Delete", comment: ""), style: .destructive) { [weak self] _ in
            guard let self else { return }
            self.env.fontStore.delete(font.id)
            self.refreshSettings()
        })
        present(alert, animated: true)
    }
}
