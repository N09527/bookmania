import Foundation

/// What the library shows about a book file: its metadata and cover image (Android: LocalEbooks.fillMetadata and the
/// cover copied from the first chapter).
public struct BookInfo: Sendable {
    public let metadata: BookMetadata
    public let cover: [UInt8]?

    public init(metadata: BookMetadata, cover: [UInt8]?) {
        self.metadata = metadata
        self.cover = cover
    }
}

public enum BookInfoReader {
    /// Reads the metadata and cover of an EPUB, MOBI or AZW3 file, without the work the reader needs (no writing
    /// mode detection for EPUB, no text decompression for MOBI). Throws like `BookOpener.open`.
    public static func read(_ url: URL) throws -> BookInfo {
        let source = try FileSource(url: url)
        let ext = url.pathExtension.lowercased()
        let format: BookFormat
        do {
            format = try FormatDetector.detect(source, extension: ext)
        } catch {
            source.close()
            throw BookError.unreadable("Cannot read the file")
        }
        switch format {
        case .epub:
            let zip: ZipReader
            do {
                zip = try ZipReader(source: source)
            } catch {
                source.close()
                throw error
            }
            defer { zip.close() }
            let publication = try EpubParser.parse(zip, detectWritingMode: false)
            let cover = publication.metadata.coverHref.flatMap { try? publication.open($0) } ?? nil
            return BookInfo(metadata: publication.metadata, cover: cover)
        case .mobi, .kf8:
            defer { source.close() }
            return try MobiParser.info(source)
        case .kfx:
            source.close()
            throw BookError.unsupported("KFX books are not supported")
        case .unknown:
            source.close()
            throw BookError.unreadable("Unknown or damaged book file")
        }
    }
}
