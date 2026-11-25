import Foundation

public final class EpubPublication: Publication {
    private let zip: ZipReader
    public let metadata: BookMetadata
    public let spine: [SpineItem]
    public let toc: [TocEntry]
    public let readingDirection: ReadingDirection
    public let writingModeHint: WritingModeHint
    public let isFixedLayout: Bool
    private let mediaTypes: [String: String]
    /// Container path -> obfuscation algorithm.
    private let obfuscation: [String: String]
    private let uniqueIdentifier: String?
    private let uuidIdentifier: String?
    /// Path of the package document (OPF).
    public let packagePath: String

    public var format: BookFormat { .epub }

    init(zip: ZipReader, metadata: BookMetadata, spine: [SpineItem], toc: [TocEntry], readingDirection: ReadingDirection,
         writingModeHint: WritingModeHint, isFixedLayout: Bool, mediaTypes: [String: String], obfuscation: [String: String],
         uniqueIdentifier: String?, uuidIdentifier: String?, packagePath: String) {
        self.zip = zip
        self.metadata = metadata
        self.spine = spine
        self.toc = toc
        self.readingDirection = readingDirection
        self.writingModeHint = writingModeHint
        self.isFixedLayout = isFixedLayout
        self.mediaTypes = mediaTypes
        self.obfuscation = obfuscation
        self.uniqueIdentifier = uniqueIdentifier
        self.uuidIdentifier = uuidIdentifier
        self.packagePath = packagePath
    }

    public var resourcePaths: [String] { zip.names }

    public func open(_ href: String) throws -> [UInt8]? {
        guard let entry = zip.find(BookPaths.splitFragment(href).path) else { return nil }
        let bytes = try zip.read(entry)
        guard let algorithm = obfuscation[entry.name] else { return bytes }
        return FontObfuscation.deobfuscate(bytes, algorithm: algorithm, uniqueIdentifier: uniqueIdentifier, uuidIdentifier: uuidIdentifier)
    }

    public func mediaType(_ href: String) -> String? {
        let path = BookPaths.splitFragment(href).path
        let name = zip.find(path)?.name ?? path
        return mediaTypes[name] ?? mediaTypeFromName(name)
    }

    public func close() { zip.close() }
}

/// EPUB 2 and 3 (port of core/ebook `EpubParser.kt`).
public enum EpubParser {
    private static let container = "META-INF/container.xml"
    private static let appleOptions = "META-INF/com.apple.ibooks.display-options.xml"
    private static let cssBudget: Int64 = 4 << 20

    /// Parses an EPUB. The source is owned by the result (closed with it), or closed on failure.
    public static func parse(_ source: RandomAccessSource) throws -> EpubPublication {
        let zip: ZipReader
        do {
            zip = try ZipReader(source: source)
        } catch {
            source.close()
            if let e = error as? BookError { throw e }
            throw BookError.corrupt("Not a readable EPUB")
        }
        do {
            return try parse(zip)
        } catch {
            zip.close()
            if let e = error as? BookError { throw e }
            throw BookError.corrupt("Not a readable EPUB: \(error)")
        }
    }

    private struct Item {
        let id: String
        let path: String
        let mediaType: String
        let properties: Set<String>
    }

    private struct Encryption {
        let obfuscated: [String: String]
        let drmScheme: String?
    }

    static func parse(_ zip: ZipReader) throws -> EpubPublication {
        let encryption = try readEncryption(zip)
        if let scheme = encryption.drmScheme { throw BookError.drmProtected(scheme: scheme) }

        let opfPath = try findPackagePath(zip)
        guard let opfBytes = try zip.readBytes(opfPath) else { throw BookError.corrupt("Package document missing: \(opfPath)") }
        guard let pkg = Markup.parse(opfBytes, mode: .xml).descendantsNamed("package").first else {
            throw BookError.corrupt("Invalid package document")
        }

        // Metadata
        let md = pkg.descendantsNamed("metadata").first
        let uidRef = pkg.attr("unique-identifier")
        let identifiers = md?.descendantsNamed("identifier") ?? []
        let uniqueEl = identifiers.first { !uidRef.isEmpty && $0.attr("id") == uidRef } ?? identifiers.first
        let uniqueId = uniqueEl?.text.trimmed.nilIfEmpty
        let uuidId = identifiers.map { $0.text.trimmed }.first { FontObfuscation.adobeKey($0) != nil }
        let metas = md?.descendantsNamed("meta") ?? []
        func metaProperty(_ p: String) -> String? { metas.first { $0.attr("property") == p }?.text.trimmed }
        func metaName(_ n: String) -> String? {
            metas.first { $0.attr("name").caseInsensitiveCompare(n) == .orderedSame }?.attr("content").trimmed
        }

        // Manifest
        let manifestItems = pkg.descendantsNamed("manifest").first?.childrenNamed("item") ?? []
        let items: [Item] = manifestItems.compactMap { el in
            let href = el.attr("href")
            guard !href.trimmed.isEmpty, let resolved = BookPaths.resolve(opfPath, href) else { return nil }
            let path = BookPaths.splitFragment(resolved).path
            let actual = zip.find(path)?.name ?? path
            let declared = el.attr("media-type").trimmed
            let mediaType = declared.isEmpty ? (mediaTypeFromName(actual) ?? "application/octet-stream") : declared
            let props = Set(el.attr("properties").split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).map(String.init))
            return Item(id: el.attr("id"), path: actual, mediaType: mediaType, properties: props)
        }
        var byId = [String: Item]()
        for item in items where byId[item.id] == nil { byId[item.id] = item }

        // Spine
        let spineEl = pkg.descendantsNamed("spine").first
        let itemRefs = spineEl?.childrenNamed("itemref") ?? []
        let spine: [SpineItem] = itemRefs.compactMap { ref in
            guard let item = byId[ref.attr("idref")], zip.has(item.path) else { return nil }
            return SpineItem(href: item.path, mediaType: item.mediaType, linear: ref.attr("linear").lowercased() != "no")
        }
        if spine.isEmpty { throw BookError.corrupt("The book has no readable content (empty spine)") }
        let direction: ReadingDirection
        switch spineEl?.attr("page-progression-direction").trimmed.lowercased() {
        case "rtl": direction = .rtl
        case "ltr": direction = .ltr
        default: direction = .default
        }

        // Layout
        let fixed = metaProperty("rendition:layout") == "pre-paginated" ||
            metaName("fixed-layout") == "true" ||
            (!itemRefs.isEmpty && itemRefs.allSatisfy { $0.attr("properties").contains("rendition:layout-pre-paginated") }) ||
            appleFixedLayout(zip)

        // Cover
        var cover = items.first { $0.properties.contains("cover-image") }?.path
        if cover == nil, let id = metaName("cover"), let item = byId[id], item.mediaType.hasPrefix("image/") {
            cover = item.path
        }

        // Table of contents: EPUB 3 navigation document, then EPUB 2 NCX.
        var toc: [TocEntry] = []
        if let nav = items.first(where: { $0.properties.contains("nav") }) {
            toc = (try? parseNav(zip, nav.path)) ?? []
        }
        if toc.isEmpty {
            let ncx = spineEl.flatMap { byId[$0.attr("toc")] } ?? items.first { $0.mediaType == "application/x-dtbncx+xml" }
            if let ncx { toc = (try? parseNcx(zip, ncx.path)) ?? [] }
        }

        let languages = (md?.descendantsNamed("language") ?? []).map { $0.text.trimmed }.filter { !$0.isEmpty }
        let metadata = BookMetadata(
            title: md?.descendantsNamed("title").first?.text.trimmed.nilIfEmpty,
            authors: (md?.descendantsNamed("creator") ?? []).map { $0.text.trimmed }.filter { !$0.isEmpty },
            languages: languages,
            identifier: uniqueId,
            description: md?.descendantsNamed("description").first?.text.trimmed.nilIfEmpty,
            coverHref: cover,
            publisher: md?.descendantsNamed("publisher").first?.text.trimmed.nilIfEmpty,
            date: md?.descendantsNamed("date").first?.text.trimmed.nilIfEmpty
        )
        let writingMode = detectWritingMode(zip, items, spine, metaName("primary-writing-mode"), direction, languages)

        var mediaTypes = [String: String]()
        for item in items where mediaTypes[item.path] == nil { mediaTypes[item.path] = item.mediaType }
        var obfuscation = [String: String]()
        for (k, v) in encryption.obfuscated { obfuscation[zip.find(k)?.name ?? k] = v }

        return EpubPublication(
            zip: zip, metadata: metadata, spine: spine, toc: toc, readingDirection: direction,
            writingModeHint: writingMode, isFixedLayout: fixed, mediaTypes: mediaTypes, obfuscation: obfuscation,
            uniqueIdentifier: uniqueId, uuidIdentifier: uuidId, packagePath: opfPath
        )
    }

    private static func findPackagePath(_ zip: ZipReader) throws -> String {
        if let bytes = try zip.readBytes(container) {
            let doc = Markup.parse(bytes, mode: .xml)
            let rootfile = doc.descendantsNamed("rootfile").first {
                let type = $0.attr("media-type").trimmed
                return type.isEmpty || type == "application/oebps-package+xml"
            }
            if let fullPath = rootfile?.attr("full-path"), let resolved = BookPaths.resolve("", fullPath),
               let name = zip.find(resolved)?.name {
                return name
            }
        }
        if let opf = zip.names.first(where: { $0.lowercased().hasSuffix(".opf") }) { return opf }
        throw BookError.corrupt("No package document (OPF) found")
    }

    /// Font obfuscation is fine; any other encryption, or known DRM files, means DRM.
    private static func readEncryption(_ zip: ZipReader) throws -> Encryption {
        var knownScheme: String? = nil
        if zip.has("META-INF/license.lcpl") { knownScheme = "Readium LCP" }
        else if zip.has("META-INF/sinf.xml") { knownScheme = "Apple FairPlay" }
        guard let bytes = try zip.readBytes("META-INF/encryption.xml") else {
            return Encryption(obfuscated: [:], drmScheme: knownScheme)
        }
        var obfuscated = [String: String]()
        var otherEncryption = false
        for data in Markup.parse(bytes, mode: .xml).descendantsNamed("encrypteddata") {
            let algorithm = data.descendantsNamed("encryptionmethod").first?.attr("Algorithm").trimmed ?? ""
            let uri = data.descendantsNamed("cipherreference").first?.attr("URI").trimmed ?? ""
            guard let resolved = BookPaths.resolve("", uri) else { continue }
            let path = BookPaths.splitFragment(resolved).path
            if FontObfuscation.isObfuscation(algorithm) { obfuscated[path] = algorithm } else { otherEncryption = true }
        }
        let scheme = knownScheme ?? (otherEncryption ? (zip.has("META-INF/rights.xml") ? "Adobe ADEPT" : "unknown") : nil)
        return Encryption(obfuscated: obfuscated, drmScheme: scheme)
    }

    private static func appleFixedLayout(_ zip: ZipReader) -> Bool {
        guard let bytes = try? zip.readBytes(appleOptions) else { return false }
        return Markup.parse(bytes, mode: .xml).descendantsNamed("option").contains {
            $0.attr("name") == "fixed-layout" && $0.text.trimmed == "true"
        }
    }

    private static func parseNav(_ zip: ZipReader, _ navPath: String) throws -> [TocEntry] {
        guard let bytes = try zip.readBytes(navPath) else { return [] }
        let doc = Markup.parse(bytes, mode: .xml)
        let navs = doc.descendantsNamed("nav")
        guard let nav = navs.first(where: { el in
            el.attr("epub:type").split(separator: " ").contains("toc") || el.attr("role") == "doc-toc"
        }) ?? navs.first else { return [] }
        guard let ol = nav.childrenNamed("ol").first ?? nav.descendantsNamed("ol").first else { return [] }
        return parseNavList(ol, navPath)
    }

    private static func parseNavList(_ ol: MLElement, _ base: String) -> [TocEntry] {
        ol.childrenNamed("li").compactMap { li in
            let label = li.childElements.first { $0.localName == "a" || $0.localName == "span" }
            let title = label?.text.trimmed ?? ""
            var href: String? = nil
            if let a = label, a.localName == "a" {
                let h = a.attr("href")
                if !h.trimmed.isEmpty { href = BookPaths.resolve(base, h) }
            }
            let children = li.childrenNamed("ol").first.map { parseNavList($0, base) } ?? []
            if title.isEmpty && children.isEmpty { return nil }
            return TocEntry(title: title.isEmpty ? "…" : title, href: href, children: children)
        }
    }

    private static func parseNcx(_ zip: ZipReader, _ ncxPath: String) throws -> [TocEntry] {
        guard let bytes = try zip.readBytes(ncxPath) else { return [] }
        let doc = Markup.parse(bytes, mode: .xml)
        guard let navMap = doc.descendantsNamed("navmap").first else { return [] }
        return parseNavPoints(navMap, ncxPath)
    }

    private static func parseNavPoints(_ parent: MLElement, _ base: String) -> [TocEntry] {
        parent.childrenNamed("navpoint").map { np in
            let title = np.firstChildNamed("navlabel")?.descendantsNamed("text").first?.text.trimmed ?? ""
            var src: String? = nil
            if let s = np.firstChildNamed("content")?.attr("src"), !s.trimmed.isEmpty { src = BookPaths.resolve(base, s) }
            return TocEntry(title: title.isEmpty ? "…" : title, href: src, children: parseNavPoints(np, base))
        }
    }

    private static func detectWritingMode(_ zip: ZipReader, _ items: [Item], _ spine: [SpineItem], _ primaryWritingMode: String?,
                                          _ direction: ReadingDirection, _ languages: [String]) -> WritingModeHint {
        var budget = cssBudget
        var stylesheets = [String]()
        for item in items where item.mediaType == "text/css" {
            guard let entry = zip.find(item.path) else { continue }
            if entry.size > budget { break }
            budget -= entry.size
            if let bytes = try? zip.read(entry) { stylesheets.append(utf8(bytes)) }
        }
        let documents = spine.filter { $0.linear }.prefix(3).compactMap { item -> [UInt8]? in
            try? zip.readBytes(item.href)
        }
        return WritingModeDetector.detect(stylesheets: stylesheets, firstDocuments: documents,
                                          primaryWritingMode: primaryWritingMode, direction: direction, languages: languages)
    }
}
