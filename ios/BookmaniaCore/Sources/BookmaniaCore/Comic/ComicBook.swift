import Foundation

/// The pages of an image book (Android's page loaders for the image reader): the images of a ZIP / CBZ archive or of a
/// folder in the natural order of their names (ZipPageLoader, DirectoryPageLoader), or the images of an EPUB's pages
/// in reading order (EpubPageLoader: each page's `img src` and SVG `image xlink:href`).
public protocol ComicBook: AnyObject {
    var pageCount: Int { get }
    /// A name for the page (its path), for diagnostics.
    func pageName(_ index: Int) -> String
    /// The image file's bytes.
    func pageData(_ index: Int) throws -> [UInt8]
    func close()
}

public enum ComicBooks {
    /// File extensions taken for images (Android's ImageUtil.isImage checks the name, then the content).
    public static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "avif", "heif", "heic", "bmp", "jxl"]

    public static func isImageName(_ name: String) -> Bool {
        let file = name.afterLast("/", missing: name)
        if file.hasPrefix(".") { return false }
        return imageExtensions.contains(file.afterLast(".", missing: "").lowercased())
    }

    /// The image book of a local chapter; throws a BookError when it cannot be read.
    public static func open(_ chapter: LocalChapter) throws -> ComicBook {
        switch chapter.kind {
        case .folder: return try FolderComic(chapter.file)
        case .archive: return try ArchiveComic(try FileSource(url: chapter.file))
        case .epub: return try EpubComic(BookOpener.open(try FileSource(url: chapter.file), extension: "epub"))
        case .mobi, .azw3: throw BookError.unsupported("Not an image book")
        }
    }
}

/// The images of a folder.
public final class FolderComic: ComicBook {
    private let files: [URL]

    public init(_ folder: URL, fileManager: FileManager = .default) throws {
        guard let entries = try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey],
                                                                 options: [.skipsHiddenFiles]) else {
            throw BookError.unreadable("Cannot list the folder")
        }
        files = entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory != true && ComicBooks.isImageName($0.lastPathComponent) }
            .sorted { LocalLibrary.naturalCompare($0.lastPathComponent, $1.lastPathComponent) == .orderedAscending }
    }

    public var pageCount: Int { files.count }
    public func pageName(_ index: Int) -> String { files[index].lastPathComponent }

    public func pageData(_ index: Int) throws -> [UInt8] {
        guard let data = try? Data(contentsOf: files[index]) else { throw BookError.unreadable("Cannot read \(files[index].lastPathComponent)") }
        return [UInt8](data)
    }

    public func close() {}
}

/// The images of a ZIP / CBZ archive (anywhere in it; macOS's resource forks are skipped).
public final class ArchiveComic: ComicBook {
    private let zip: ZipReader
    private let names: [String]

    public init(_ source: RandomAccessSource) throws {
        let reader = try ZipReader(source: source)
        let images = reader.names
            .filter { name in
                guard let entry = reader.entries[name], !entry.isDirectory else { return false }
                return !name.hasPrefix("__MACOSX/") && ComicBooks.isImageName(name)
            }
            .sorted { LocalLibrary.naturalCompare($0, $1) == .orderedAscending }
        if images.contains(where: { reader.entries[$0]?.isEncrypted == true }) {
            reader.close()
            throw BookError.drmProtected(scheme: "ZIP encryption")
        }
        zip = reader
        names = images
    }

    public var pageCount: Int { names.count }
    public func pageName(_ index: Int) -> String { names[index] }

    public func pageData(_ index: Int) throws -> [UInt8] {
        guard let bytes = try zip.readBytes(names[index]) else { throw BookError.corrupt("Missing \(names[index])") }
        return bytes
    }

    public func close() { zip.close() }
}

/// The images of an EPUB's pages, in reading order.
public final class EpubComic: ComicBook {
    private let publication: Publication
    private let paths: [String]

    public init(_ publication: Publication) throws {
        self.publication = publication
        paths = EpubComic.imagePaths(publication)
    }

    static func imagePaths(_ publication: Publication) -> [String] {
        var result = [String]()
        for item in publication.spine {
            let type = item.mediaType.lowercased()
            guard type.contains("html") || type.contains("xml"), let bytes = try? publication.open(item.href) else { continue }
            let doc = Markup.parse(bytes, mode: .xml)
            for element in doc.allElements {
                let href: String
                switch element.localName {
                case "img": href = element.attr("src")
                case "image": href = element.attr("xlink:href").nilIfEmpty ?? element.attr("href")
                default: continue
                }
                // Relative to the page document (resolve takes the document's path and uses its folder).
                guard !href.isEmpty, !BookPaths.isExternal(href), let path = BookPaths.resolve(item.href, href) else { continue }
                result.append(BookPaths.splitFragment(path).path)
            }
        }
        return result
    }

    public var pageCount: Int { paths.count }
    public func pageName(_ index: Int) -> String { paths[index] }

    public func pageData(_ index: Int) throws -> [UInt8] {
        guard let bytes = try publication.open(paths[index]) else { throw BookError.corrupt("Missing \(paths[index])") }
        return bytes
    }

    public func close() { publication.close() }
}

/// Where the image reader starts and what it saves (ReaderViewModel on Android): a read chapter starts at its first
/// page, another one at its last page read; a page written by the text reader (an estimate of text pages) is turned
/// into the same fraction of the book (EbookRouter.imageReaderStartPage).
public enum ComicProgress {
    public static func startPage(_ state: ChapterState, pageCount: Int) -> Int {
        guard pageCount > 0, !state.read else { return 0 }
        let page = state.lastPageRead
        if let saved = state.position, let chapterPage = saved.chapterPage, chapterPage == page {
            let total = page + state.pagesLeft
            let fraction = saved.total ?? (total > 0 ? Double(page) / Double(total) : 0)
            return min(pageCount - 1, Int((min(max(fraction, 0), 1) * Double(pageCount)).rounded(.down)))
        }
        return (0 ..< pageCount).contains(page) ? page : 0
    }

    /// Saves the page shown (saveChapterProgress on Android): `lastPageRead` is its index, `pagesLeft` the pages from it
    /// to the end (1 on the last page); the last page marks the chapter read, and so does the page before it when the
    /// last spread shows both (`extraPage`). Returns whether the chapter was finished just now.
    @discardableResult
    public static func save(_ store: LibraryStore, chapterId: String, page: Int, pageCount: Int, extraPage: Bool = false) -> Bool {
        var finished = false
        store.updateChapter(chapterId) { c in
            c.lastPageRead = page
            c.pagesLeft = max(0, pageCount - page)
            let last = page >= pageCount - 1 || (extraPage && page == pageCount - 2)
            if last && !c.read {
                c.read = true
                finished = true
            }
        }
        return finished
    }
}
