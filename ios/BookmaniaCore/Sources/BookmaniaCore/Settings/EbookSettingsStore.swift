import Foundation

/// String preferences; UserDefaults in the app, a dictionary in tests.
public protocol PreferenceStore: AnyObject {
    func string(_ key: String) -> String?
    func set(_ key: String, _ value: String?)
}

public final class MemoryPreferenceStore: PreferenceStore {
    public private(set) var values: [String: String] = [:]
    private let lock = NSLock()
    public init(_ values: [String: String] = [:]) { self.values = values }
    public func string(_ key: String) -> String? { lock.lock(); defer { lock.unlock() }; return values[key] }
    public func set(_ key: String, _ value: String?) { lock.lock(); values[key] = value; lock.unlock() }
}

/// Which level a change applies to.
public enum SettingsScope: Int, CaseIterable, Sendable { case global, work, file }

/// Identifies a book for per-work and per-file settings (URLs are stable across backups, ids are not).
public struct BookKey: Equatable, Sendable {
    public let sourceId: Int64
    public let mangaUrl: String
    public let chapterUrl: String

    public init(sourceId: Int64 = 0, mangaUrl: String, chapterUrl: String) {
        self.sourceId = sourceId
        self.mangaUrl = mangaUrl
        self.chapterUrl = chapterUrl
    }

    /// A local chapter (the local source's id is 0, as on Android).
    public init(_ chapter: LocalChapter) {
        let work = chapter.id.before("/")
        self.init(sourceId: 0, mangaUrl: work, chapterUrl: chapter.id)
    }
}

/// The three settings levels, stored with the preference keys of Android's EbookSettingsStore so they can travel in
/// backups: global values as `pref_ebook_<key>`, per-work / per-file overrides as one JSON object each under
/// `pref_ebook_override_<sha1 of the identity>`.
public final class EbookSettingsStore: @unchecked Sendable {
    private let store: PreferenceStore

    public init(_ store: PreferenceStore) { self.store = store }

    public func effective(_ book: BookKey) -> EbookSettings {
        EbookSettings.resolve([global(), overrides(.work, book), overrides(.file, book)])
    }

    /// Values a level sets itself (the global level returns only the keys that were changed).
    public func levelValues(_ scope: SettingsScope, _ book: BookKey) -> [String: String] {
        scope == .global ? global() : overrides(scope, book)
    }

    /// The settings as seen from `scope`: that level and the ones above it, ignoring nearer levels.
    public func resolvedAt(_ scope: SettingsScope, _ book: BookKey) -> EbookSettings {
        switch scope {
        case .global: return EbookSettings.resolve([global()])
        case .work: return EbookSettings.resolve([global(), overrides(.work, book)])
        case .file: return effective(book)
        }
    }

    /// Keys that a level nearer than `scope` sets for `book`, with the nearest such level (which wins).
    public func overriddenBelow(_ scope: SettingsScope, _ book: BookKey) -> [EbookSettings.Key: SettingsScope] {
        var result = [EbookSettings.Key: SettingsScope]()
        for level in SettingsScope.allCases.filter({ $0.rawValue > scope.rawValue }).reversed() {
            for key in overrides(level, book).keys {
                if let k = EbookSettings.Key(rawValue: key), result[k] == nil { result[k] = level }
            }
        }
        return result
    }

    /// The level the settings panel starts on: the nearest one that already has values for `book`, else global.
    public func initialScope(_ book: BookKey) -> SettingsScope {
        if !overrides(.file, book).isEmpty { return .file }
        if !overrides(.work, book).isEmpty { return .work }
        return .global
    }

    public func set(_ scope: SettingsScope, _ book: BookKey, _ key: EbookSettings.Key, _ value: String) {
        if scope == .global {
            store.set(EbookSettingsStore.globalKey(key), value)
        } else {
            var map = overrides(scope, book)
            map[key.rawValue] = value
            writeOverrides(scope, book, map)
        }
    }

    /// Removes everything `scope` sets, so it inherits again (global: back to the defaults).
    public func clear(_ scope: SettingsScope, _ book: BookKey) {
        if scope == .global {
            for k in EbookSettings.Key.allCases { store.set(EbookSettingsStore.globalKey(k), nil) }
        } else {
            store.set(EbookSettingsStore.overrideKey(scope, book), nil)
        }
    }

    private func global() -> [String: String] {
        var out = [String: String]()
        for k in EbookSettings.Key.allCases {
            if let v = store.string(EbookSettingsStore.globalKey(k)) { out[k.rawValue] = v }
        }
        return out
    }

    private func overrides(_ scope: SettingsScope, _ book: BookKey) -> [String: String] {
        guard let text = store.string(EbookSettingsStore.overrideKey(scope, book)), !text.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return [:] }
        // Only setting keys; the identity fields written with them are ignored here.
        var out = [String: String]()
        for (k, v) in object where EbookSettings.Key(rawValue: k) != nil {
            if let s = v as? String { out[k] = s }
        }
        return out
    }

    private func writeOverrides(_ scope: SettingsScope, _ book: BookKey, _ values: [String: String]) {
        let key = EbookSettingsStore.overrideKey(scope, book)
        if values.isEmpty {
            store.set(key, nil)
            return
        }
        // The identity is stored alongside, so a backup stays readable and can be re-keyed if needed.
        var object = values
        object["_source"] = String(book.sourceId)
        object["_manga"] = book.mangaUrl
        if scope == .file { object["_chapter"] = book.chapterUrl }
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            store.set(key, text)
        }
    }

    private static let prefix = "pref_ebook_"

    public static func globalKey(_ key: EbookSettings.Key) -> String { prefix + key.rawValue }

    public static func overrideKey(_ scope: SettingsScope, _ book: BookKey) -> String {
        let identity: String
        switch scope {
        case .work: identity = "work\u{0}\(book.sourceId)\u{0}\(book.mangaUrl)"
        case .file: identity = "file\u{0}\(book.sourceId)\u{0}\(book.mangaUrl)\u{0}\(book.chapterUrl)"
        case .global: preconditionFailure("The global level has no override key")
        }
        return prefix + "override_" + SHA1.hash(Array(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
