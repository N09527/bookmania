import Foundation

/// Converts between the library state and Android's backup (BackupCreator and the restorers on Android), for the
/// local source (id 0), which is the only one the iOS version has.
public enum BackupMapper {
    /// Android's LocalSource.ID.
    public static let localSourceId: Int64 = 0

    /// Preferences that travel in backups, with the type Android stores each with: the typesetting settings (the
    /// global ones and the per-work / per-file overrides, all strings), the readers' and the library's settings.
    public static func preferenceType(_ key: String) -> ReaderPreferences.PreferenceType? {
        if key.hasPrefix("pref_ebook_override_") { return .string }
        if EbookSettings.Key.allCases.contains(where: { EbookSettingsStore.globalKey($0) == key }) { return .string }
        if let t = ReaderPreferences.types[key] { return t }
        if let t = LibraryPreferences.types[key] { return t }
        return nil
    }

    // MARK: Creating

    /// A backup of the works in the library, and of the other works with read chapters or history (Android's
    /// "read manga not in the library"): their chapters, categories, history and text positions, the categories, and
    /// the preferences listed in `preferenceType`.
    public static func backup(works: [LocalWork], state: LibraryState, preferences: [String: String]) -> AndroidBackup {
        var backup = AndroidBackup()
        let categories = state.categories.sorted { ($0.order, $0.id) < ($1.order, $1.id) }
        backup.categories = categories.map { BackupCategoryRecord(name: $0.name, order: $0.order, flags: $0.flags) }
        let orderById = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0.order) })
        for work in works {
            let w = state.works[work.id] ?? WorkState()
            let chapterStates = work.chapters.map { state.chapters[$0.id] ?? ChapterState() }
            let read = chapterStates.contains { $0.read || $0.lastRead != nil || $0.lastPageRead > 0 }
            guard w.favorite || read else { continue }
            var m = BackupMangaRecord(source: localSourceId, url: work.id)
            m.title = work.title
            m.artist = work.artist
            m.author = work.author
            m.description = work.description
            m.genre = work.genres
            m.status = work.status
            m.dateAdded = w.dateAdded
            m.favorite = w.favorite
            m.chapterFlags = w.chapterFlags
            m.viewerFlags = w.viewerFlags
            m.categories = w.categoryIds.compactMap { orderById[$0] }
            // Android lists local chapters with the highest number first; source order 0 is the first of that list.
            let listed = Array(work.chapters.enumerated().reversed())
            for (order, (_, chapter)) in listed.enumerated() {
                let c = state.chapters[chapter.id] ?? ChapterState()
                var record = BackupChapterRecord(url: chapter.id, name: chapter.fileTitle)
                record.read = c.read
                record.bookmark = c.bookmark
                record.lastPageRead = c.lastPageRead
                record.pagesLeft = c.pagesLeft
                record.dateFetch = c.dateFetch
                record.dateUpload = chapter.modified.map { Int64($0.timeIntervalSince1970 * 1000) } ?? 0
                record.chapterNumber = -1 // not recognised (the local source would parse the name)
                record.sourceOrder = order
                record.ebookPosition = c.position?.toJSON()
                m.chapters.append(record)
                if let lastRead = c.lastRead {
                    m.history.append(BackupHistoryRecord(url: chapter.id, lastRead: lastRead, readDuration: c.readDuration))
                }
            }
            backup.mangas.append(m)
        }
        if !backup.mangas.isEmpty { backup.sources = [(name: "Local source", id: localSourceId)] }
        backup.preferences = preferences.keys.sorted().compactMap { key in
            guard let type = preferenceType(key), let text = preferences[key] else { return nil }
            switch type {
            case .string: return BackupPreferenceRecord(key: key, value: .string(text))
            case .int: return Int(text).map { BackupPreferenceRecord(key: key, value: .int($0)) }
            case .bool: return text == "true" || text == "false" ? BackupPreferenceRecord(key: key, value: .bool(text == "true")) : nil
            }
        }
        return backup
    }

    // MARK: Restoring

    public struct RestoreResult: Equatable, Sendable {
        /// Works of the local source restored.
        public var works = 0
        /// Works of other sources (online sources, which the iOS version does not have), skipped.
        public var skipped = 0
        public var positions = 0
        public var preferences = 0
    }

    /// Merges `backup` into `state` (and the preferences into `store`), as Android's restorers do:
    /// - categories missing by name are added;
    /// - a work takes the backup's library state, date added, categories (by order, then by name), chapter flags and
    ///   reading mode;
    /// - a chapter takes the backup's progress, except that a chapter read here stays read with its page, and a page
    ///   here is kept when the backup has none; bookmarks are kept from both;
    /// - the history takes the later read time and the longer duration;
    /// - a text position is taken unless the one here is newer.
    /// Works whose folder is not here yet keep their state for when it appears.
    public static func restore(_ backup: AndroidBackup, into state: inout LibraryState, preferences store: PreferenceStore?) -> RestoreResult {
        var result = RestoreResult()
        for c in backup.categories.sorted(by: { $0.order < $1.order }) where !state.categories.contains(where: { $0.name == c.name }) {
            let order = (state.categories.map(\.order).max() ?? -1) + 1
            state.categories.append(LibraryCategory(id: state.nextCategoryId, name: c.name, order: order, flags: c.flags))
            state.nextCategoryId += 1
        }
        for m in backup.mangas {
            guard m.source == localSourceId else {
                result.skipped += 1
                continue
            }
            result.works += 1
            var w = state.works[m.url] ?? WorkState()
            w.favorite = m.favorite
            if m.dateAdded > 0 { w.dateAdded = m.dateAdded }
            let ids: [Int64] = m.categories.compactMap { order in
                guard let name = backup.categories.first(where: { $0.order == order })?.name else { return nil }
                return state.categories.first { $0.name == name }?.id
            }
            if !ids.isEmpty { w.categoryIds = ids }
            w.chapterFlags = m.chapterFlags
            if let v = m.viewerFlags { w.viewerFlags = v } else if m.viewer != 0 { w.viewerFlags = m.viewer }
            state.works[m.url] = w
            for chapter in m.chapters {
                var c = state.chapters[chapter.url] ?? ChapterState()
                let here = c
                c.read = chapter.read
                c.lastPageRead = chapter.lastPageRead
                c.pagesLeft = chapter.pagesLeft
                if here.read && !chapter.read {
                    c.read = true
                    c.lastPageRead = here.lastPageRead
                    c.pagesLeft = here.pagesLeft
                } else if chapter.lastPageRead == 0 && here.lastPageRead != 0 {
                    c.lastPageRead = here.lastPageRead
                    c.pagesLeft = here.pagesLeft
                }
                c.bookmark = chapter.bookmark || here.bookmark
                if c.dateFetch == 0 { c.dateFetch = chapter.dateFetch }
                if let locator = EbookLocator.fromJSON(chapter.ebookPosition), (here.position?.updatedAt ?? Int64.min) < locator.updatedAt || here.position == nil {
                    c.position = locator
                    result.positions += 1
                }
                state.chapters[chapter.url] = c
            }
            for h in m.history {
                var c = state.chapters[h.url] ?? ChapterState()
                c.lastRead = max(h.lastRead, c.lastRead ?? 0)
                c.readDuration = max(h.readDuration, c.readDuration)
                state.chapters[h.url] = c
            }
        }
        if let store {
            for p in backup.preferences where preferenceType(p.key) != nil {
                store.set(p.key, p.value.text)
                result.preferences += 1
            }
        }
        return result
    }

    /// The file name Android gives backups (Backup.getFilename), with Bookmania's package name.
    public static func fileName(date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HH-mm"
        return "io.github.n09527.bookmania_\(f.string(from: date)).tachibk"
    }
}
