import BookmaniaCore
import Foundation

/// Preferences in UserDefaults, under the same keys as on Android (strings only; see ReaderPreferences.types).
final class UserDefaultsPreferenceStore: PreferenceStore {
    private let defaults: UserDefaults

    init(_ defaults: UserDefaults = .standard) { self.defaults = defaults }

    func string(_ key: String) -> String? { defaults.string(forKey: key) }

    func set(_ key: String, _ value: String?) {
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
    }

    /// Every stored preference of the app's own keys (for backups).
    func all(prefix: String = "") -> [String: String] {
        var out = [String: String]()
        for (key, value) in defaults.dictionaryRepresentation() where key.hasPrefix(prefix) {
            if let s = value as? String { out[key] = s }
        }
        return out
    }
}

/// The app's shared services. The stores are safe to use from any thread (UserDefaults is).
final class AppEnvironment: @unchecked Sendable {
    static let shared = AppEnvironment()

    let preferences = UserDefaultsPreferenceStore()
    let settingsStore: EbookSettingsStore
    let fontStore: FontStore
    let readerPreferences: ReaderPreferences
    /// Read state, bookmarks, history, positions, the library and its categories.
    let library: LibraryStore
    /// Character counts of text books, per file version (not backed up).
    let ebookInfo: EbookInfoCache

    private init() {
        settingsStore = EbookSettingsStore(preferences)
        fontStore = FontStore(directory: AppPaths.fonts, store: preferences)
        readerPreferences = ReaderPreferences(preferences)
        library = LibraryStore(file: AppPaths.support.appendingPathComponent("library.json"))
        ebookInfo = EbookInfoCache(file: AppPaths.support.appendingPathComponent("ebook-info.json"))
        library.onChange = {
            DispatchQueue.main.async { NotificationCenter.default.post(name: .libraryChanged, object: nil) }
        }
    }
}

extension Notification.Name {
    /// The library store changed (read state, history, the library, categories); posted on the main thread.
    static let libraryChanged = Notification.Name("bookmania.libraryChanged")
}
