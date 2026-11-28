import Foundation

/// Identifiers of sync-format.md section 2 (as Android's SyncIds).
public enum SyncIds {
    /// Android's LocalSource.ID.
    public static let localSource: Int64 = 0

    public static func workKey(source: Int64, url: String) -> String { "\(source):\(url)" }

    public static func localWorkKey(_ folder: String) -> String { workKey(source: localSource, url: folder) }

    /// The local source's work folder of a work key, or nil for another source.
    public static func localFolder(_ workKey: String) -> String? {
        workKey.hasPrefix("\(localSource):") ? String(workKey.dropFirst("\(localSource):".count)) : nil
    }

    /// The progress file of a work: the SHA-1 of the work key's UTF-8 bytes, in lower-case hex.
    public static func progressFileName(_ workKey: String) -> String {
        SHA1.hash(Array(workKey.utf8)).map { String(format: "%02x", $0) }.joined() + ".json"
    }

    public static func newDeviceID() -> String { UUID().uuidString.lowercased() }
}

/// The checks on file names from the server before anything is written locally (sync-format.md section 5.3).
public enum SyncNames {
    public static func validSegment(_ segment: String) -> Bool {
        guard !segment.isEmpty, segment != ".", segment != "..", !segment.hasPrefix("."), segment.utf8.count <= 255 else { return false }
        for u in segment.unicodeScalars {
            if u == "/" || u == "\\" || u.value < 0x20 || (0x7F ... 0x9F).contains(u.value) { return false }
        }
        return true
    }

    public static func validPath(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        return (1 ... 2).contains(parts.count) && parts.allSatisfy(validSegment)
    }

    public static func valid(_ item: Sync.FileItem) -> Bool { validSegment(item.work) && validPath(item.path) }
}
