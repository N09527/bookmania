import Foundation

/// Where the app keeps its files. The Documents folder is visible in the Files app (UIFileSharingEnabled), and its
/// "local" folder is the local source, laid out as on Android: one folder per work, the book files inside.
enum AppPaths {
    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static var local: URL { documents.appendingPathComponent("local", isDirectory: true) }

    /// Creates the local folder so it shows up in the Files app right away.
    static func prepare() {
        try? FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
    }
}
