import Foundation

/// Where the app keeps its files. The Documents folder is visible in the Files app (UIFileSharingEnabled), and its
/// "local" folder is the local source, laid out as on Android: one folder per work, the book files inside.
enum AppPaths {
    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static var local: URL { documents.appendingPathComponent("local", isDirectory: true) }

    /// The app's private data (not shown in the Files app): imported fonts, the library state, caches.
    static var support: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Bookmania", isDirectory: true)
    }

    /// Imported fonts (`<id>.ttf|otf`), as Android keeps them in the app's private files.
    static var fonts: URL { support.appendingPathComponent("fonts", isDirectory: true) }

    /// Creates the local folder so it shows up in the Files app right away.
    static func prepare() {
        try? FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
    }
}
