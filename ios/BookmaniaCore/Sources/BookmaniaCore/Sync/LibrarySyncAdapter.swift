import Foundation

/// The iOS side of the WebDAV sync (as Android's AndroidSyncAdapter): the library store (works, categories,
/// chapters, history, text positions), the synced settings and the local source's files, plus the baselines (files
/// in the app's own storage). It lives in the core so its mapping is tested on Linux; the app gives it its stores.
public final class LibrarySyncAdapter: SyncAdapter, SyncFileAccess, @unchecked Sendable {
    private let store: LibraryStore
    private let preferences: PreferenceStore
    private let allPreferences: () -> [String: String]
    private let localRoot: URL
    private let directory: URL
    private let lock = NSLock()
    private var cachedBaseline: Sync.Baseline?

    /// - Parameters:
    ///   - allPreferences: every stored preference (key → text), as UserDefaults has them.
    ///   - localRoot: the local source folder (Documents/local).
    ///   - directory: where the baselines are kept.
    public init(store: LibraryStore, preferences: PreferenceStore, allPreferences: @escaping () -> [String: String], localRoot: URL, directory: URL) {
        self.store = store
        self.preferences = preferences
        self.allPreferences = allPreferences
        self.localRoot = localRoot
        self.directory = directory
    }

    /// The settings that are synced, with their type: the backups' set, without incognito mode (a choice for one
    /// device). Android's SyncSettingsKeys lists the same keys.
    public static func settingType(_ key: String) -> String? {
        guard key != ReaderPreferences.Keys.incognitoMode, let type = BackupMapper.preferenceType(key) else { return nil }
        switch type {
        case .string: return "string"
        case .int: return "int"
        case .bool: return "bool"
        }
    }

    private static func folder(_ work: String) -> String? { SyncIds.localFolder(work) }

    // MARK: Library

    public func librarySnapshot() -> Sync.LibrarySnapshot {
        let state = store.snapshot
        let names = Dictionary(state.categories.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        var works: [String: Sync.WorkValue] = [:]
        for (folder, w) in state.works {
            works[SyncIds.localWorkKey(folder)] = Sync.WorkValue(
                favorite: w.favorite, added: w.dateAdded, categories: w.categoryIds.compactMap { names[$0] }.sorted(),
                chapterFlags: w.chapterFlags, viewerFlags: w.viewerFlags
            )
        }
        // A work of the last sync this store no longer has (all its values were reset) reads as not in the library.
        for key in loadBaseline().library.works.keys where works[key] == nil {
            if Self.folder(key) != nil { works[key] = Sync.WorkValue() }
        }
        var categories: [String: Sync.CategoryValue] = [:]
        for c in state.categories { categories[c.name] = Sync.CategoryValue(order: c.order, flags: c.flags) }
        var settings: [String: Sync.SettingValue] = [:]
        for (key, text) in allPreferences() {
            guard let type = Self.settingType(key) else { continue }
            switch type {
            case "int": if let i = Int64(text) { settings[key] = Sync.SettingValue(type: type, value: .int(i)) }
            case "bool": if text == "true" || text == "false" { settings[key] = Sync.SettingValue(type: type, value: .bool(text == "true")) }
            default: settings[key] = Sync.SettingValue(type: type, value: .string(text))
            }
        }
        return Sync.LibrarySnapshot(works: works, categories: categories, settings: settings)
    }

    public func applyLibrary(_ changes: Sync.LibraryChanges) -> Set<String> {
        var ids = Set<String>()
        store.update { state in
            for (name, v) in changes.categories {
                if let i = state.categories.firstIndex(where: { $0.name == name }) {
                    state.categories[i].order = v.order
                    state.categories[i].flags = v.flags
                } else {
                    state.categories.append(LibraryCategory(id: state.nextCategoryId, name: name, order: v.order, flags: v.flags))
                    state.nextCategoryId += 1
                }
                ids.insert("c:\(name)")
            }
            for name in changes.deletedCategories {
                guard let id = state.categories.first(where: { $0.name == name })?.id else { continue }
                state.categories.removeAll { $0.id == id }
                for (url, var w) in state.works where w.categoryIds.contains(id) {
                    w.categoryIds.removeAll { $0 == id }
                    state.works[url] = w
                }
            }
            let idByName = Dictionary(state.categories.map { ($0.name, $0.id) }, uniquingKeysWith: { a, _ in a })
            for (key, v) in changes.works {
                // Online works need their source (the extension stages); they stay in the baseline until then.
                guard let folder = Self.folder(key) else { continue }
                var w = state.works[folder] ?? WorkState()
                w.favorite = v.favorite
                w.dateAdded = v.added
                w.categoryIds = v.categories.compactMap { idByName[$0] }
                w.chapterFlags = v.chapterFlags
                w.viewerFlags = v.viewerFlags
                state.works[folder] = w
                ids.insert("w:\(key)")
            }
        }
        for (key, s) in changes.settings {
            guard Self.settingType(key) != nil else { continue }
            preferences.set(key, s.value?.text)
            ids.insert("s:\(key)")
        }
        return ids
    }

    // MARK: Progress

    public func progressSnapshot(_ work: String) -> Sync.ProgressSnapshot {
        guard let folder = Self.folder(work) else { return Sync.ProgressSnapshot() }
        let prefix = folder + "/"
        var chapters: [String: Sync.ChapterValue] = [:]
        for (id, c) in store.snapshot.chapters where id.hasPrefix(prefix) {
            chapters[id] = Sync.ChapterValue(
                read: c.read, page: c.lastPageRead, left: c.pagesLeft, bookmark: c.bookmark,
                locator: c.position?.toJSON(), lastRead: c.lastRead ?? 0, duration: c.readDuration
            )
        }
        // Chapters with files but no state yet are untouched: nothing to claim, so they need no entry.
        return Sync.ProgressSnapshot(chapters: chapters)
    }

    public func applyProgress(_ work: String, _ changes: Sync.ProgressChanges) -> Set<String> {
        guard let folder = Self.folder(work) else { return [] }
        var ids = Set<String>()
        store.update { state in
            for (key, change) in changes.chapters where key.hasPrefix(folder + "/") {
                var c = state.chapters[key] ?? ChapterState()
                if let p = change.progress {
                    c.read = p.read
                    c.lastPageRead = p.page
                    c.pagesLeft = p.left
                    ids.insert("\(key)|progress")
                }
                if let b = change.bookmark {
                    c.bookmark = b
                    ids.insert("\(key)|bookmark")
                }
                if let p = change.position {
                    if let text = p.locator {
                        if let locator = EbookLocator.fromJSON(text) {
                            c.position = locator
                            ids.insert("\(key)|position")
                        }
                    } else {
                        c.position = nil
                        ids.insert("\(key)|position")
                    }
                }
                if let h = change.history {
                    if h.lastRead > 0 { c.lastRead = h.lastRead }
                    c.readDuration = h.duration
                }
                state.chapters[key] = c
            }
        }
        return ids
    }

    // MARK: Baselines

    private var baselineFile: URL { directory.appendingPathComponent("baseline.json") }
    private func workFile(_ work: String) -> URL { directory.appendingPathComponent("works").appendingPathComponent(SyncIds.progressFileName(work)) }

    private func write(_ text: String, to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(text.utf8).write(to: url, options: .atomic)
    }

    public func loadBaseline() -> Sync.Baseline {
        lock.lock()
        defer { lock.unlock() }
        if let cachedBaseline { return cachedBaseline }
        let b = Sync.decode(Sync.Baseline.self, try? Data(contentsOf: baselineFile)) ?? Sync.Baseline()
        cachedBaseline = b
        return b
    }

    public func saveBaseline(_ baseline: Sync.Baseline) {
        write(Sync.encode(baseline), to: baselineFile)
        lock.lock()
        cachedBaseline = baseline
        lock.unlock()
    }

    public func loadWorkBaseline(_ work: String) -> Sync.WorkBaseline {
        Sync.decode(Sync.WorkBaseline.self, try? Data(contentsOf: workFile(work))) ?? Sync.WorkBaseline()
    }

    public func saveWorkBaseline(_ work: String, _ baseline: Sync.WorkBaseline) {
        write(Sync.encode(baseline), to: workFile(work))
    }

    /// Forgets the last syncs (another server or account).
    public func reset() {
        try? FileManager.default.removeItem(at: directory)
        lock.lock()
        cachedBaseline = nil
        lock.unlock()
    }

    // MARK: Book files of the local source

    private func entries(_ url: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey], options: [.skipsHiddenFiles])) ?? []
    }

    private func isDirectory(_ url: URL) -> Bool { (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
    private func size(_ url: URL) -> Int64 { Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }

    public func list(works: Set<String>) -> [Sync.FileItem] {
        var out: [Sync.FileItem] = []
        for work in works {
            let folder = localRoot.appendingPathComponent(work)
            guard isDirectory(folder) else { continue }
            for f in entries(folder) where !f.lastPathComponent.hasPrefix(".") {
                if isDirectory(f) {
                    for g in entries(f) where !g.lastPathComponent.hasPrefix(".") && !isDirectory(g) {
                        out.append(Sync.FileItem(work: work, path: "\(f.lastPathComponent)/\(g.lastPathComponent)", size: size(g)))
                    }
                } else {
                    out.append(Sync.FileItem(work: work, path: f.lastPathComponent, size: size(f)))
                }
            }
        }
        return out
    }

    public func fileURL(work: String, path: String) -> URL {
        path.split(separator: "/").reduce(localRoot.appendingPathComponent(work)) { $0.appendingPathComponent(String($1)) }
    }

    public func save(work: String, path: String, from temporary: URL) throws {
        let target = fileURL(work: work, path: path)
        if FileManager.default.fileExists(atPath: target.path) { throw SyncError(.format, "\(work)/\(path) exists") }
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: temporary, to: target)
    }
}
