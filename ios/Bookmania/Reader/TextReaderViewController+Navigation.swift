import BookmaniaCore
import SwiftUI
import UIKit

/// A table of contents entry with its depth and the spine index of its target (nil without a target).
struct TocItem: Identifiable, Hashable {
    let id: Int
    let title: String
    let href: String?
    let depth: Int
    let spine: Int?
}

/// The table of contents, the whole-book slider, the chapter panel and links in the book (EbookReaderActivity's
/// navigation code and ChapterPanel.kt on Android).
extension TextReaderViewController {

    var tocItems: [TocItem] {
        var items = [TocItem]()
        func add(_ entries: [TocEntry], _ depth: Int) {
            for e in entries {
                let target = e.href.map { $0.before("#") }
                let spineIndex = target.flatMap { t in spine.firstIndex { $0.href == t } }
                items.append(TocItem(id: items.count, title: e.title, href: e.href, depth: depth, spine: spineIndex))
                if depth < 8 { add(e.children, depth + 1) }
            }
        }
        add(publication?.toc ?? [], 0)
        return items
    }

    // MARK: Contents

    @objc func contentsTapped() {
        let items = tocItems
        guard !items.isEmpty else {
            toast(NSLocalizedString("This book has no table of contents", comment: ""))
            return
        }
        setChrome(visible: false)
        // The current entry: the last one that starts in or before the open document.
        let current = items.last { ($0.spine ?? Int.max) <= spineIndex }?.id
        var host: UIViewController?
        let view = ContentsView(items: items, current: current, onSelect: { [weak self] item in
            host?.dismiss(animated: true)
            self?.goToHref(item.href)
        }, onClose: {
            host?.dismiss(animated: true)
        })
        let controller = UIHostingController(rootView: view)
        controller.modalPresentationStyle = .pageSheet
        controller.sheetPresentationController?.detents = [.medium(), .large()]
        controller.sheetPresentationController?.prefersGrabberVisible = true
        host = controller
        present(controller, animated: true)
    }

    /// Opens a container path with an optional `#fragment` (a table of contents target or a link).
    func goToHref(_ href: String?) {
        guard let href, !busy else { return }
        let path = href.before("#")
        let fragment = href.contains("#") ? href.after("#") : ""
        guard let index = spine.firstIndex(where: { $0.href == path }) else {
            toast(NSLocalizedString("The link target was not found in this book", comment: ""))
            return
        }
        endTurn()
        if index != spineIndex {
            openSpine(index, target: fragment.isEmpty ? "'start'" : "{fragment: \(ShellSettings.jsString(fragment))}")
            return
        }
        Task { [weak self] in
            guard let self else { return }
            let script = fragment.isEmpty ? "String(window.__reader.goPage(0))" : "String(window.__reader.goFragment(\(ShellSettings.jsString(fragment))))"
            if await self.eval(script) == "true" {
                await self.refreshPage()
            } else {
                self.toast(NSLocalizedString("The link target was not found in this book", comment: ""))
            }
        }
    }

    /// Takes the page numbers of the layout shown now (after a move inside the document).
    func refreshPage() async {
        if let s = await status(), s.ready, s.error == nil {
            apply(s)
            layoutFinished()
        }
    }

    // MARK: Whole-book slider

    /// The table of contents entry at a fraction of the book (shown while the slider is dragged).
    func tocTitle(at fraction: Double) -> String? {
        guard let progress = session?.progress else { return nil }
        let (index, _) = progress.locate(fraction)
        return tocItems.last { ($0.spine ?? Int.max) <= index }?.title
    }

    @objc func sliderMoved() {
        let fraction = Double(progressSlider.value)
        let percent = Int((fraction * 100).rounded())
        seekLabel.text = [tocTitle(at: fraction), "\(percent)%"].compactMap { $0 }.joined(separator: "\n")
        seekLabel.isHidden = false
        view.bringSubviewToFront(seekLabel)
    }

    /// Moves to a fraction of the whole book (the slider was released there).
    @objc func sliderReleased() {
        seekLabel.isHidden = true
        guard let progress = session?.progress, !busy else { return }
        let (index, docFraction) = progress.locate(Double(progressSlider.value))
        endTurn()
        if index == spineIndex {
            Task { [weak self] in
                guard let self else { return }
                if await self.eval("String(window.__reader.goProgress(\(docFraction)))") == "true" { await self.refreshPage() }
            }
        } else {
            openSpine(index, target: "{\"progression\": \(docFraction)}")
        }
    }

    // MARK: Chapters

    /// The chapter panel: the other chapters (files) of the work.
    @objc func chaptersTapped() {
        setChrome(visible: false)
        let folder = chapter.file.deletingLastPathComponent()
        let current = chapter.id
        let store = env.library
        Task { [weak self] in
            let work = await Task.detached(priority: .userInitiated) { LocalLibrary.work(at: folder) }.value
            guard let self else { return }
            var host: UIViewController?
            let states = Dictionary(uniqueKeysWithValues: work.chapters.map { ($0.id, store.chapter($0.id)) })
            let view = ChapterPanelView(chapters: work.chapters, current: current, states: states, onSelect: { [weak self] target in
                host?.dismiss(animated: true) {
                    guard let self, target.id != current else { return }
                    self.leaveSession()
                    self.onOpenChapter(target, false)
                }
            }, onClose: {
                host?.dismiss(animated: true)
            })
            let controller = UIHostingController(rootView: view)
            controller.modalPresentationStyle = .pageSheet
            controller.sheetPresentationController?.detents = [.medium(), .large()]
            controller.sheetPresentationController?.prefersGrabberVisible = true
            host = controller
            self.present(controller, animated: true)
        }
    }

    // MARK: Links

    /// The link under a point of the page (web view points are the shell's CSS px), or nil.
    func link(at point: CGPoint) async -> String? {
        let p = webView.convert(point, from: touchLayer)
        guard webView.bounds.contains(p) else { return nil }
        guard let result = await eval("String(window.__reader.hit(\(Double(p.x)), \(Double(p.y))) || '')"), !result.isEmpty else { return nil }
        return result
    }

    /// A link in the book: to a place in the book, or (asked first) to a web page or an e-mail address.
    func openLink(_ url: String) {
        if let target = ReaderURLs.bookPath(of: url) {
            guard let index = spine.firstIndex(where: { $0.href == target.path }) else {
                toast(NSLocalizedString("The link target was not found in this book", comment: ""))
                return
            }
            let fragment = target.fragment ?? ""
            if index == spineIndex && fragment.isEmpty { return }
            goToHref(fragment.isEmpty ? target.path : target.path + "#" + fragment)
            return
        }
        guard let external = URL(string: url), let scheme = external.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) else { return }
        let alert = UIAlertController(title: NSLocalizedString("Open this link in the browser?", comment: ""), message: url, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: ""), style: .cancel))
        alert.addAction(UIAlertAction(title: NSLocalizedString("Open in browser", comment: ""), style: .default) { _ in
            UIApplication.shared.open(external)
        })
        present(alert, animated: true)
    }
}

/// The table of contents, with the current entry marked.
struct ContentsView: View {
    let items: [TocItem]
    let current: Int?
    let onSelect: (TocItem) -> Void
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List(items) { item in
                    Button {
                        onSelect(item)
                    } label: {
                        HStack {
                            Text(verbatim: item.title)
                                .padding(.leading, CGFloat(item.depth) * 16)
                                .foregroundStyle(item.href == nil ? Color.secondary : Color.primary)
                            Spacer(minLength: 8)
                            if item.id == current { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                        }
                    }
                    .disabled(item.href == nil)
                    .id(item.id)
                }
                .listStyle(.plain)
                .onAppear {
                    if let current { proxy.scrollTo(current, anchor: .center) }
                }
            }
            .navigationTitle(Text("Contents"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", action: onClose)
                }
            }
        }
    }
}

/// The other chapters (files) of the work; the open one is marked.
struct ChapterPanelView: View {
    let chapters: [LocalChapter]
    let current: String
    let states: [String: ChapterState]
    let onSelect: (LocalChapter) -> Void
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List(chapters) { chapter in
                    let state = states[chapter.id] ?? ChapterState()
                    Button {
                        onSelect(chapter)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: chapter.fileTitle)
                                    .foregroundStyle(state.read ? Color.secondary : Color.primary)
                                if chapter.id == current {
                                    Text("Reading now").font(.caption).foregroundStyle(Color.accentColor)
                                }
                            }
                            Spacer(minLength: 8)
                            if state.bookmark { Image(systemName: "bookmark.fill").foregroundStyle(Color.accentColor) }
                        }
                    }
                    .id(chapter.id)
                }
                .listStyle(.plain)
                .onAppear { proxy.scrollTo(current, anchor: .center) }
            }
            .navigationTitle(Text("Chapters"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", action: onClose)
                }
            }
        }
    }
}
