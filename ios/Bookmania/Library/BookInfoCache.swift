import BookmaniaCore
import Foundation

/// Titles, authors, descriptions and covers read from the book files (Android: LocalEbooks.fillMetadata and the cover
/// of the first chapter), cached in memory per file and modification date. Runs off the main thread.
actor BookInfoCache {
    static let shared = BookInfoCache()

    private var cache: [String: BookInfo?] = [:]

    func info(for chapter: LocalChapter) -> BookInfo? {
        switch chapter.kind {
        case .folder, .archive: return nil
        case .epub, .mobi, .azw3: break
        }
        let key = chapter.file.path + "|" + String(chapter.modified?.timeIntervalSince1970 ?? 0)
        if let hit = cache[key] { return hit }
        let info = try? BookInfoReader.read(chapter.file)
        cache.updateValue(info, forKey: key)
        return info
    }

    /// The first book of a work (reading order) that has a cover.
    func cover(for work: LocalWork) -> [UInt8]? {
        for chapter in work.chapters {
            if let cover = info(for: chapter)?.cover { return cover }
        }
        return nil
    }
}

/// Book descriptions are often HTML; the work page shows them as plain text.
func plainText(_ description: String) -> String {
    guard description.contains("<") else { return description }
    return Markup.parse(description, mode: .html).text
}
