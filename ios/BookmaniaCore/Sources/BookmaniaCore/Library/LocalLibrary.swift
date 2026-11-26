import Foundation

/// A work of the local source: a folder in `local/`, as on Android (`<storage>/local/<work>/<chapters>`).
public struct LocalWork: Identifiable, Hashable, Sendable {
    /// The folder name; the work's URL in Android backups.
    public let id: String
    public let folder: URL
    public var title: String
    public var author: String?
    public var artist: String?
    public var description: String?
    /// Genres, as ComicInfo.xml or details.json list them.
    public var genres: [String] = []
    /// Publishing status with Android's numbers (SManga): 0 unknown, 1 ongoing, 2 completed, 3 licensed,
    /// 4 publishing finished, 5 cancelled, 6 on hiatus.
    public var status: Int = 0
    /// `cover.jpg` (or another `cover.*` image) in the folder.
    public var coverFile: URL?
    public var chapters: [LocalChapter]

    public init(id: String, folder: URL, title: String, author: String? = nil, artist: String? = nil, description: String? = nil,
                genres: [String] = [], status: Int = 0, coverFile: URL? = nil, chapters: [LocalChapter]) {
        self.id = id
        self.folder = folder
        self.title = title
        self.author = author
        self.artist = artist
        self.description = description
        self.genres = genres
        self.status = status
        self.coverFile = coverFile
        self.chapters = chapters
    }
}

/// A chapter of a local work: a book file, an archive of images or a folder of images.
public struct LocalChapter: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable {
        case epub, mobi, azw3, archive, folder

        /// Text-only formats open in the text reader; EPUB is decided by its content.
        public var isTextOnly: Bool { self == .mobi || self == .azw3 }
    }

    /// "<work folder>/<file name>", the chapter's URL in Android backups.
    public let id: String
    public let file: URL
    public let kind: Kind
    /// File name without extension (folder name for folders); a book's own title may replace it for display.
    public let fileTitle: String
    public let modified: Date?

    public init(id: String, file: URL, kind: Kind, fileTitle: String, modified: Date?) {
        self.id = id
        self.file = file
        self.kind = kind
        self.fileTitle = fileTitle
        self.modified = modified
    }
}

/// Lists the local source the way Android's LocalSource does: works are the folders of `local/`, chapters are the
/// supported files and the sub-folders of a work. Hidden files are skipped.
public enum LocalLibrary {

    /// Archive extensions read as image chapters. (RAR, CBR and 7z, which Android also lists, have no reader on
    /// iOS yet.)
    public static let archiveExtensions: Set<String> = ["zip", "cbz"]

    public static func kind(of url: URL, isDirectory: Bool) -> LocalChapter.Kind? {
        if isDirectory { return .folder }
        switch url.pathExtension.lowercased() {
        case "epub": return .epub
        case "mobi": return .mobi
        case "azw3": return .azw3
        case let ext where archiveExtensions.contains(ext): return .archive
        default: return nil
        }
    }

    /// All works under `root` (the `local` folder), sorted by title (case-insensitive natural order).
    public static func scan(root: URL, fileManager: FileManager = .default) -> [LocalWork] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey, .isHiddenKey]
        guard let folders = try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: keys,
                                                                 options: [.skipsHiddenFiles]) else { return [] }
        var works = [LocalWork]()
        for folder in folders where isDirectory(folder) {
            works.append(work(at: folder, fileManager: fileManager))
        }
        return works.sorted { naturalCompare($0.title, $1.title) == .orderedAscending }
    }

    /// One work, with its chapters in reading order (natural order of the names).
    public static func work(at folder: URL, fileManager: FileManager = .default) -> LocalWork {
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey]
        let entries = (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                            options: [.skipsHiddenFiles])) ?? []
        var chapters = [LocalChapter]()
        var cover: URL? = nil
        var details: [String: String] = [:]
        for entry in entries {
            let dir = isDirectory(entry)
            let name = entry.lastPathComponent
            if !dir && name.lowercased().hasPrefix("cover.") && ["jpg", "jpeg", "png", "webp", "gif"].contains(entry.pathExtension.lowercased()) {
                cover = entry
                continue
            }
            if !dir && name.lowercased() == "comicinfo.xml" {
                details.merge(comicInfo(entry)) { a, _ in a }
                continue
            }
            if !dir && entry.pathExtension.lowercased() == "json" {
                details.merge(detailsJSON(entry)) { _, b in b }
                continue
            }
            guard let kind = kind(of: entry, isDirectory: dir) else { continue }
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            chapters.append(LocalChapter(
                id: "\(folder.lastPathComponent)/\(name)",
                file: entry,
                kind: kind,
                fileTitle: dir ? name : entry.deletingPathExtension().lastPathComponent,
                modified: modified
            ))
        }
        chapters.sort { naturalCompare($0.fileTitle, $1.fileTitle) == .orderedAscending }
        return LocalWork(
            id: folder.lastPathComponent,
            folder: folder,
            title: details["title"]?.nilIfEmpty ?? folder.lastPathComponent,
            author: details["author"]?.nilIfEmpty,
            artist: details["artist"]?.nilIfEmpty,
            description: details["description"]?.nilIfEmpty,
            genres: (details["genre"] ?? "").split(separator: ",").map { String($0).trimmed }.filter { !$0.isEmpty },
            status: details["status"].flatMap { Int($0) }.flatMap { (0 ... 6).contains($0) ? $0 : nil } ?? 0,
            coverFile: cover,
            chapters: chapters
        )
    }

    /// Case-insensitive natural order ("2" before "10"), like Android's `compareToCaseInsensitiveNaturalOrder`.
    public static func naturalCompare(_ a: String, _ b: String) -> ComparisonResult {
        a.compare(b, options: [.caseInsensitive, .numeric], range: nil, locale: nil)
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }

    /// Title, writer and summary of a ComicInfo.xml (Android gives it priority over details.json).
    static func comicInfo(_ url: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        let doc = Markup.parse([UInt8](data), mode: .xml)
        var out = [String: String]()
        if let series = doc.descendantsNamed("series").first?.text.trimmed.nilIfEmpty { out["title"] = series }
        else if let title = doc.descendantsNamed("title").first?.text.trimmed.nilIfEmpty { out["title"] = title }
        if let writer = doc.descendantsNamed("writer").first?.text.trimmed.nilIfEmpty { out["author"] = writer }
        if let penciller = doc.descendantsNamed("penciller").first?.text.trimmed.nilIfEmpty { out["artist"] = penciller }
        if let summary = doc.descendantsNamed("summary").first?.text.trimmed.nilIfEmpty { out["description"] = summary }
        if let genre = doc.descendantsNamed("genre").first?.text.trimmed.nilIfEmpty { out["genre"] = genre }
        // Android writes the status as <ty:PublishingStatusTachiyomi> (ComicInfoPublishingStatus).
        if let status = doc.descendantsNamed("publishingstatustachiyomi").first?.text.trimmed {
            let values = ["ongoing": 1, "completed": 2, "licensed": 3, "publishing finished": 4, "cancelled": 5, "on hiatus": 6]
            if let n = values[status.lowercased()] { out["status"] = String(n) }
        }
        return out
    }

    /// The legacy `details.json` (title, author, description).
    static func detailsJSON(_ url: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        var out = [String: String]()
        for key in ["title", "author", "artist", "description"] {
            if let v = object[key] as? String { out[key] = v }
        }
        if let genres = object["genre"] as? [String] { out["genre"] = genres.joined(separator: ", ") }
        else if let genre = object["genre"] as? String { out["genre"] = genre }
        // A number, or a number as text.
        if let n = object["status"] as? Int { out["status"] = String(n) }
        else if let t = object["status"] as? String, Int(t) != nil { out["status"] = t }
        return out
    }
}
