import Foundation

// Swift port of parts of foliate-js mobi.js (MIT License, Copyright (c) 2022 John Factotum), via core/ebook.

/// Opens MOBI 6, KF8 (AZW3) and joint MOBI files. DRM-protected files are refused.
public enum MobiParser {
    public static func parse(_ source: RandomAccessSource) throws -> Publication {
        do {
            let file = try MobiFile(source)
            if file.isKf8 { return try Kf8Publication(file, source) }
            return try Mobi6Publication(file, source)
        } catch {
            source.close()
            if let e = error as? BookError { throw e }
            throw BookError.corrupt("Not a readable MOBI/AZW3 file: \(error)")
        }
    }
}

/// A small LRU cache for assembled documents (the reader may load a document in two frames).
final class DocumentCache {
    private let capacity: Int
    private var map = [String: [UInt8]]()
    private var order = [String]()
    private let lock = NSLock()

    init(capacity: Int = 6) { self.capacity = capacity }

    func get(_ key: String, _ make: () throws -> [UInt8]) rethrows -> [UInt8] {
        lock.lock()
        if let v = map[key] {
            order.removeAll { $0 == key }
            order.append(key)
            lock.unlock()
            return v
        }
        lock.unlock()
        let v = try make()
        lock.lock()
        map[key] = v
        order.removeAll { $0 == key }
        order.append(key)
        while order.count > capacity { map[order.removeFirst()] = nil }
        lock.unlock()
        return v
    }
}

/// Paths and helpers shared by both MOBI flavours.
class MobiPublicationBase {
    let file: MobiFile
    private let source: RandomAccessSource
    private var extensionCache = [Int: String]()
    private let lock = NSLock()
    private let metadataLock = NSLock()
    private var metadataCache: BookMetadata?

    init(file: MobiFile, source: RandomAccessSource) {
        self.file = file
        self.source = source
    }

    var headers: MobiHeaders { file.headers }
    var encoding: TextEncoding { file.headers.encoding }

    /// Book-relative path of resource `id` (1-based), choosing the folder from the record type.
    func resourcePath(_ id: Int) -> String {
        if file.resourceMagic(id) == "FONT" { return "fonts/\(padded(id, 5)).ttf" }
        lock.lock()
        defer { lock.unlock() }
        let ext: String
        if let cached = extensionCache[id] {
            ext = cached
        } else {
            let head = ((try? file.resource(id)) ?? nil).map { Array($0.prefix(16)) } ?? []
            ext = MobiPublicationBase.sniffImageExtension(head)
            extensionCache[id] = ext
        }
        return "images/\(padded(id, 5)).\(ext)"
    }

    var metadata: BookMetadata {
        metadataLock.lock()
        if let m = metadataCache { metadataLock.unlock(); return m }
        metadataLock.unlock()
        let m = makeMetadata()
        metadataLock.lock()
        metadataCache = m
        metadataLock.unlock()
        return m
    }

    private func makeMetadata() -> BookMetadata {
        let h = file.baseHeaders.exth.isEmpty ? headers : file.baseHeaders
        let coverOffset = (h.exthUint(201) ?? h.exthUint(202)).flatMap { $0 < nullIndex ? $0 : nil }
        let languages = h.exthStrings(524)
        let coverHref = coverOffset.map { resourcePath(Int($0) + 1) }
        return BookMetadata(
            title: h.exthString(503) ?? h.encoding.decode(h.title).trimmed.nilIfEmpty,
            authors: h.exthStrings(100),
            languages: languages.isEmpty ? [mobiLanguage(h.localeLanguage, h.localeRegion)].compactMap { $0 } : languages,
            identifier: h.exthString(104) ?? h.exthString(113) ?? String(h.uid),
            description: h.exthString(103),
            coverHref: coverHref,
            publisher: h.exthString(101),
            date: h.exthString(106)
        )
    }

    var readingDirection: ReadingDirection {
        switch (headers.exthString(527) ?? file.baseHeaders.exthString(527))?.lowercased() {
        case "rtl": return .rtl
        case "ltr": return .ltr
        default: return .default
        }
    }

    var isFixedLayout: Bool { (headers.exthString(122) ?? file.baseHeaders.exthString(122)) == "true" }

    func mediaType(_ href: String) -> String? {
        let path = href.before("#")
        if path.hasPrefix("text/") && path.hasSuffix(".xhtml") { return "application/xhtml+xml" }
        if path.hasPrefix("text/") { return "text/html" }
        if path.hasPrefix("styles/") { return "text/css" }
        if path.hasPrefix("fonts/") { return "font/ttf" }
        if path.hasSuffix(".svg") { return "image/svg+xml" }
        if path.hasSuffix(".jpg") { return "image/jpeg" }
        if path.hasSuffix(".png") { return "image/png" }
        if path.hasSuffix(".gif") { return "image/gif" }
        if path.hasSuffix(".bmp") { return "image/bmp" }
        if path.hasSuffix(".webp") { return "image/webp" }
        return nil
    }

    /// Images and fonts; the subclass handles documents and stylesheets.
    func openResource(_ path: String) throws -> [UInt8]? {
        if let m = MobiPublicationBase.resourcePathRx.matchEntire(path), let id = Int(m.group(2)) {
            return try file.resource(id)
        }
        return nil
    }

    func close() { source.close() }

    private static let resourcePathRx = Rx(#"(images|fonts)/(\d{5})\.\w+"#)

    static func sniffImageExtension(_ b: [UInt8]) -> String {
        if b.count >= 3 && b[0] == 0xFF && b[1] == 0xD8 { return "jpg" }
        if b.count >= 4 && b[0] == 0x89 && b[1] == UInt8(ascii: "P") && b[2] == UInt8(ascii: "N") { return "png" }
        if b.count >= 4 && ascii(b, 0, 4) == "GIF8" { return "gif" }
        if b.count >= 2 && b[0] == UInt8(ascii: "B") && b[1] == UInt8(ascii: "M") { return "bmp" }
        if b.count >= 12 && ascii(b, 0, 4) == "RIFF" && ascii(b, 8, 4) == "WEBP" { return "webp" }
        return "bin"
    }
}

/// KF8 (AZW3, and the KF8 part of joint MOBI files): XHTML rebuilt from skeletons and fragments.
final class Kf8Publication: MobiPublicationBase, Publication {
    var format: BookFormat { .kf8 }

    private struct Skel { let numFrag: Int; let offset: Int; let length: Int }
    private struct Frag { let insertOffset: Int; let index: Int64; let offset: Int; let length: Int }
    private struct Section { let number: Int; let skel: Skel; let frags: [Frag]; let length: Int }

    private let flows: [(Int, Int)]
    private let sections: [Section]
    private let cache = DocumentCache()
    private let lazyLock = NSLock()
    private var spineCache: [SpineItem]?
    private var tocCache: [TocEntry]?
    private var writingModeCache: WritingModeHint?

    init(_ file: MobiFile, _ source: RandomAccessSource) throws {
        let h = file.headers
        var flows = [(Int, Int)]()
        if h.fdst != nullIndex {
            let rec = try file.partRecord(h.fdst)
            if ascii(rec, 0, 4) != "FDST" { throw BookError.corrupt("Missing FDST record") }
            let n = Int(try be32(rec, 8))
            for i in 0 ..< n { flows.append((Int(try be32(rec, 12 + i * 8)), Int(try be32(rec, 16 + i * 8)))) }
        }
        if h.skelIndex == nullIndex || h.fragIndex == nullIndex { throw BookError.corrupt("KF8 index missing") }
        let load: (Int) throws -> [UInt8] = { try file.record($0) }
        let skels = try MobiIndex.read(file.start + Int(h.skelIndex), load, h.encoding).entries.map { e -> Skel in
            guard let offset = e.tag(6, 0), let length = e.tag(6, 1) else { throw BookError.corrupt("Bad skeleton entry") }
            return Skel(numFrag: Int(e.tag(1) ?? 0), offset: Int(offset), length: Int(length))
        }
        let fragData = try MobiIndex.read(file.start + Int(h.fragIndex), load, h.encoding)
        let frags = try fragData.entries.enumerated().map { (i, e) -> Frag in
            guard let insert = Int(e.name.trimmed) else { throw BookError.corrupt("Bad fragment entry") }
            return Frag(insertOffset: insert, index: e.tag(4) ?? Int64(i), offset: Int(e.tag(6, 0) ?? 0), length: Int(e.tag(6, 1) ?? 0))
        }
        var fragStart = 0
        var sections = [Section]()
        for (i, skel) in skels.enumerated() {
            let end = min(frags.count, fragStart + max(0, skel.numFrag))
            let list = Array(frags[min(fragStart, end) ..< end])
            fragStart = end
            sections.append(Section(number: i, skel: skel, frags: list, length: skel.length + list.reduce(0) { $0 + $1.length }))
        }
        self.flows = flows
        self.sections = sections
        super.init(file: file, source: source)
    }

    var spine: [SpineItem] {
        lazyLock.lock()
        defer { lazyLock.unlock() }
        if let s = spineCache { return s }
        let s = sections.filter { !$0.frags.isEmpty }.map { SpineItem(href: partPath($0.number), mediaType: "application/xhtml+xml") }
        spineCache = s
        return s
    }

    var resourcePaths: [String] { spine.map { $0.href } }

    var toc: [TocEntry] {
        lazyLock.lock()
        if let t = tocCache { lazyLock.unlock(); return t }
        lazyLock.unlock()
        let t = (try? readNcx()) ?? []
        lazyLock.lock()
        tocCache = t
        lazyLock.unlock()
        return t
    }

    var writingModeHint: WritingModeHint {
        lazyLock.lock()
        if let w = writingModeCache { lazyLock.unlock(); return w }
        lazyLock.unlock()
        var css = [String]()
        if flows.count > 1 {
            for i in 1 ..< flows.count {
                if let t = flowText(i), !t.drop(while: { $0.isWhitespace }).hasPrefix("<") { css.append(t) }
            }
        }
        let docs = spine.prefix(3).compactMap { try? partBytes($0.href) }
        let w = WritingModeDetector.detect(stylesheets: css, firstDocuments: docs,
                                           primaryWritingMode: headers.exthString(525) ?? file.baseHeaders.exthString(525),
                                           direction: readingDirection, languages: metadata.languages)
        lazyLock.lock()
        writingModeCache = w
        lazyLock.unlock()
        return w
    }

    func open(_ href: String) throws -> [UInt8]? {
        let path = href.before("#")
        if path.hasPrefix("text/part") { return try? partBytes(path) }
        if let m = Kf8Publication.flowPathRx.matchEntire(path), let index = Int(m.group(2)) {
            guard let text = flowText(index) else { return nil }
            return Array(rewriteLinks(text, fromDir: m.group(1)).utf8)
        }
        return try openResource(path)
    }

    private func partPath(_ sectionNumber: Int) -> String { "text/part\(padded(sectionNumber, 4)).xhtml" }

    private func partBytes(_ path: String) throws -> [UInt8] {
        try cache.get(path) {
            guard let m = Kf8Publication.partPathRx.matchEntire(path), let number = Int(m.group(1)),
                  number >= 0, number < sections.count else { throw BookError.corrupt("Unknown part \(path)") }
            let html = encoding.decode(try assemble(sections[number]))
            return Array(addAidIds(rewriteLinks(html, fromDir: "text")).utf8)
        }
    }

    private func assemble(_ section: Section) throws -> [UInt8] {
        let text = try file.fullText()
        let skel = section.skel
        let end = skel.offset + section.length
        if skel.offset < 0 || end > text.count || end < skel.offset { throw BookError.corrupt("Part outside the text") }
        let raw = Array(text[skel.offset ..< end])
        var skeleton = Array(raw[0 ..< min(skel.length, raw.count)])
        for frag in section.frags {
            let insert = min(max(frag.insertOffset - skel.offset, 0), skeleton.count)
            let off = skel.length + frag.offset
            if off < 0 || frag.length < 0 || off + frag.length > raw.count { throw BookError.corrupt("Fragment outside its part") }
            skeleton.insert(contentsOf: raw[off ..< off + frag.length], at: insert)
        }
        return skeleton
    }

    private func flowText(_ index: Int) -> String? {
        guard index >= 0, index < flows.count, let text = try? file.fullText() else { return nil }
        let (start, end) = flows[index]
        if start < 0 || end > text.count || start > end { return nil }
        return encoding.decode(text[start ..< end])
    }

    /// Rewrites `kindle:` URIs to book paths relative to `fromDir` ("text" or "styles").
    private func rewriteLinks(_ s: String, fromDir: String) -> String {
        let up = fromDir.isEmpty ? "" : "../"
        var out = Kf8Publication.kindlePos.replace(s) { m in
            guard let fid = Int64(m.group(1), radix: 32) else { return m.value }
            let off = Int64(m.group(2), radix: 32) ?? 0
            guard let target = posHref(fid, off) else { return "#" }
            if fromDir == "text" { return target.hasPrefix("text/") ? String(target.dropFirst(5)) : target }
            return up + target
        }
        out = Kf8Publication.kindleResource.replace(out) { m in
            guard let id = Int(m.group(2), radix: 32) else { return m.value }
            let mime = m.group(3)
            if m.group(1) == "embed" { return up + resourcePath(id) }
            return up + (mime == "image/svg+xml" ? "images/flow\(padded(id, 4)).svg" : "styles/flow\(padded(id, 4)).css")
        }
        return out
    }

    /// Book path (with fragment) for a `kindle:pos:fid:…:off:…` link.
    private func posHref(_ fid: Int64, _ off: Int64) -> String? {
        guard let section = sections.first(where: { s in s.frags.contains { $0.index == fid } }),
              let frag = section.frags.first(where: { $0.index == fid }) else { return nil }
        let path = partPath(section.number)
        guard let text = try? file.fullText() else { return path }
        let start = section.skel.offset + section.skel.length + frag.offset
        let from = start + Int(off)
        let until = min(text.count, start + frag.length)
        if from < 0 || from >= until { return path }
        let tail = encoding.decode(text[from ..< min(until, from + 4096)])
        guard let m = Kf8Publication.anchorAttr.find(tail) else { return path }
        let attr = m.group(1), value = m.group(2)
        return attr.lowercased() == "aid" ? "\(path)#aid-\(value)" : "\(path)#\(value)"
    }

    /// KF8 position links often point at `aid` attributes; give those elements a matching id.
    private func addAidIds(_ html: String) -> String {
        Kf8Publication.startTag.replace(html) { m in
            let tag = m.value
            if !tag.contains("aid=") || Kf8Publication.idAttr.containsMatch(tag) { return tag }
            guard let aid = Kf8Publication.aidAttr.find(tag)?.group(2) else { return tag }
            let close = tag.hasSuffix("/>") ? tag.count - 2 : tag.count - 1
            let idx = tag.index(tag.startIndex, offsetBy: close)
            return String(tag[..<idx]) + " id=\"aid-\(aid)\"" + String(tag[idx...])
        }
    }

    private func readNcx() throws -> [TocEntry] {
        let h = file.headers
        if h.ncxIndex == nullIndex { return [] }
        let data = try MobiIndex.read(file.start + Int(h.ncxIndex), { try self.file.record($0) }, h.encoding)
        struct Item { let index: Int; let label: String; let level: Int64?; let fid: Int64?; let off: Int64?; let parent: Int64? }
        let items = data.entries.enumerated().map { (i, e) in
            Item(index: i, label: (e.tag(3).flatMap { data.cncx[Int($0)] } ?? "").trimmed, level: e.tag(4),
                 fid: e.tag(6, 0), off: e.tag(6, 1), parent: e.tag(21))
        }
        func build(_ item: Item, _ depth: Int) -> TocEntry {
            let children = depth > 16 ? [] : items.filter { $0.parent == Int64(item.index) }.map { build($0, depth + 1) }
            let href = item.fid.flatMap { posHref($0, item.off ?? 0) }
            return TocEntry(title: item.label.isEmpty ? "…" : item.label, href: href, children: children)
        }
        return items.filter { $0.level == 0 || $0.parent == nil }.map { build($0, 0) }
    }

    private static let partPathRx = Rx(#"text/part(\d{4})\.xhtml"#)
    private static let flowPathRx = Rx(#"(styles|images)/flow(\d{4})\.(?:css|svg)"#)
    private static let kindlePos = Rx(#"kindle:pos:fid:(\w+):off:(\w+)"#)
    private static let kindleResource = Rx(#"kindle:(flow|embed):(\w+)(?:\?mime=([\w/+.-]+))?"#)
    private static let anchorAttr = Rx(#"\s(id|name|aid)\s*=\s*['"]([^'"]*)['"]"#, ignoreCase: true)
    private static let startTag = Rx(#"<[A-Za-z][^<>]*>"#)
    private static let idAttr = Rx(#"\sid\s*="#, ignoreCase: true)
    private static let aidAttr = Rx(#"\said\s*=\s*(['"])([^'"]*)\1"#)
}

/// MOBI 6: one HTML stream split at page breaks; `filepos` links and `recindex` images.
final class Mobi6Publication: MobiPublicationBase, Publication {
    var format: BookFormat { .mobi }

    var writingModeHint: WritingModeHint {
        (headers.exthString(525) ?? "").lowercased().contains("vertical") ? .vertical : .horizontal
    }

    private let raw: [UInt8]
    /// One character per byte, so regular expression offsets are byte offsets.
    private let iso: String
    private let sections: [(Int, Int)]
    private let fileposList: [Int]
    private let cache = DocumentCache()
    private let ncxItems: [NcxItem]
    private let lazyLock = NSLock()
    private var tocCache: [TocEntry]?

    /// Table of contents entries from the NCX index (tag 1: text position, 3: label, 4: level, 21: parent).
    private struct NcxItem { let index: Int; let label: String; let pos: Int?; let level: Int64?; let parent: Int64? }

    init(_ file: MobiFile, _ source: RandomAccessSource) throws {
        let rawBytes = try file.fullText()
        let isoText = latin1(rawBytes)
        raw = rawBytes
        iso = isoText
        let ncx = (try? Mobi6Publication.readNcxItems(file)) ?? []
        ncxItems = ncx
        let isoNS = isoText as NSString
        let breaks = Mobi6Publication.pagebreak.findAll(isoText).map { $0.range.location }
        var bounds = [0]
        for b in breaks + [rawBytes.count] where bounds.last != b && !bounds.contains(b) { bounds.append(b) }
        // Sections without text or images (typically after the last page break) would show as blank pages.
        var secs = [(Int, Int)]()
        for k in 0 ..< max(0, bounds.count - 1) {
            let a = bounds[k], b = bounds[k + 1]
            if b > a && Mobi6Publication.hasContent(isoNS, a, b) { secs.append((a, b)) }
        }
        sections = secs.isEmpty ? [(0, rawBytes.count)] : secs
        // Positions that need an anchor: link targets in the text and the NCX entries.
        var positions = Set<Int>()
        for m in Mobi6Publication.fileposInTag.findAll(isoText) { if let p = Int(m.group(1)) { positions.insert(p) } }
        for item in ncx { if let p = item.pos { positions.insert(p) } }
        let count = rawBytes.count
        fileposList = positions.filter { $0 >= 0 && $0 < count }.sorted()
        super.init(file: file, source: source)
    }

    var spine: [SpineItem] { sections.indices.map { SpineItem(href: sectionPath($0), mediaType: "text/html") } }

    var resourcePaths: [String] { spine.map { $0.href } }

    /// The NCX index when the book has one (Calibre and KindleGen write it), else the guide's table of contents.
    var toc: [TocEntry] {
        lazyLock.lock()
        if let t = tocCache { lazyLock.unlock(); return t }
        lazyLock.unlock()
        var t = ncxToc()
        if t.isEmpty { t = readToc() }
        lazyLock.lock()
        tocCache = t
        lazyLock.unlock()
        return t
    }

    func open(_ href: String) throws -> [UInt8]? {
        let path = href.before("#")
        if let m = Mobi6Publication.sectionPathRx.matchEntire(path), let i = Int(m.group(1)) {
            if i < 0 || i >= sections.count { return nil }
            return cache.get(path) { Array(sectionHtml(i).utf8) }
        }
        return try openResource(path)
    }

    private func sectionPath(_ i: Int) -> String { "text/section\(padded(i, 4)).html" }

    private func sectionOf(_ pos: Int) -> Int {
        sections.firstIndex { $0.1 > pos } ?? (sections.count - 1)
    }

    private func sectionHtml(_ i: Int) -> String {
        let (start, end) = sections[i]
        var out = [UInt8]()
        out.reserveCapacity(end - start + 256)
        var prev = start
        for pos in fileposList where pos >= start && pos < end {
            out.append(contentsOf: raw[prev ..< pos])
            out.append(contentsOf: Array("<a id=\"filepos\(pos)\"></a>".utf8))
            prev = pos
        }
        out.append(contentsOf: raw[prev ..< end])
        var html = encoding.decode(out)
        html = Mobi6Publication.pagebreak.replace(html, with: "")
        // The text is re-encoded as UTF-8, so any declared charset is wrong now.
        html = Mobi6Publication.metaCharset.replace(html, with: "")
        html = Mobi6Publication.blockTag.replace(html) { Mobi6Publication.mobiBlockStyle($0.value) }
        html = Mobi6Publication.aTag.replace(html) { m in
            let tag = m.value
            guard let pos = Mobi6Publication.fileposAttr.find(tag).flatMap({ Int($0.group(1)) }) else { return tag }
            let target = sectionPath(sectionOf(pos))
            let href = "\(target.hasPrefix("text/") ? String(target.dropFirst(5)) : target)#filepos\(pos)"
            return Mobi6Publication.fileposAttr.replace(tag, with: " href=\"\(href)\"")
        }
        html = Mobi6Publication.imgTag.replace(html) { m in
            let tag = m.value
            guard let id = Mobi6Publication.recindexAttr.find(tag).flatMap({ Int($0.group(1)) }) else { return tag }
            return Mobi6Publication.recindexAttr.replace(tag, with: " src=\"../\(resourcePath(id))\"")
        }
        return html
    }

    private static func readNcxItems(_ file: MobiFile) throws -> [NcxItem] {
        let h = file.headers
        if h.ncxIndex == nullIndex { return [] }
        let data = try MobiIndex.read(file.start + Int(h.ncxIndex), { try file.record($0) }, h.encoding)
        return data.entries.enumerated().map { (i, e) in
            NcxItem(index: i, label: (e.tag(3).flatMap { data.cncx[Int($0)] } ?? "").trimmed,
                    pos: e.tag(1).map { Int($0) }, level: e.tag(4), parent: e.tag(21))
        }
    }

    private func ncxToc() -> [TocEntry] {
        let items = ncxItems
        func build(_ item: NcxItem, _ depth: Int) -> TocEntry {
            let children = depth > 16 ? [] : items.filter { $0.parent == Int64(item.index) }.map { build($0, depth + 1) }
            var href: String? = nil
            if let p = item.pos, p >= 0, p < raw.count { href = "\(sectionPath(sectionOf(p)))#filepos\(p)" }
            return TocEntry(title: item.label.isEmpty ? "…" : item.label, href: href, children: children)
        }
        return items.filter { $0.level == 0 || $0.parent == nil }.map { build($0, 0) }
    }

    private func readToc() -> [TocEntry] {
        // The guide is in the <head> at the start of the text.
        let first = latin1(raw.prefix(Mobi6Publication.guideSearchBytes))
        guard let reference = Mobi6Publication.referenceTag.findAll(first).first(where: { Mobi6Publication.tocType.containsMatch($0.value) }),
              let pos = Mobi6Publication.fileposAttr.find(reference.value).flatMap({ Int($0.group(1)) }) else { return [] }
        let i = sectionOf(pos)
        let doc = Markup.parse(sectionHtml(i), mode: .html)
        return doc.allElements.compactMap { a -> TocEntry? in
            guard a.localName == "a", a.hasAttr("href") else { return nil }
            let href = a.attr("href")
            if !href.hasPrefix("section") { return nil }
            let title = a.text.trimmed
            if title.isEmpty { return nil }
            return TocEntry(title: title, href: "text/\(href)")
        }
    }

    private static let pagebreak = Rx(#"<\s*(?:mbp:)?pagebreak[^>]*>"#, ignoreCase: true)
    private static let fileposInTag = Rx(#"<[^<>]+filepos=['"]?(\d+)[^<>]*>"#, ignoreCase: true)
    private static let fileposAttr = Rx(#"\sfilepos\s*=\s*['"]?0*(\d+)['"]?"#, ignoreCase: true)
    private static let recindexAttr = Rx(#"\srecindex\s*=\s*['"]?0*(\d+)['"]?"#, ignoreCase: true)
    private static let aTag = Rx(#"<a\b[^<>]*>"#, ignoreCase: true)
    private static let imgTag = Rx(#"<img\b[^<>]*>"#, ignoreCase: true)
    private static let referenceTag = Rx(#"<reference\b[^<>]*>"#, ignoreCase: true)
    private static let tocType = Rx(#"type\s*=\s*['"]?[^'">]*\btoc\b"#, ignoreCase: true)
    private static let sectionPathRx = Rx(#"text/section(\d{4})\.html"#)
    private static let guideSearchBytes = 128 * 1024
    private static let anyTag = Rx(#"<[^<>]*>"#)

    /// `iso` has one char per byte; non-ASCII bytes count as text.
    private static func hasContent(_ iso: NSString, _ start: Int, _ end: Int) -> Bool {
        let chunk = iso.substring(with: NSRange(location: start, length: end - start))
        if imgTag.containsMatch(chunk) { return true }
        return anyTag.replace(chunk, with: "").unicodeScalars.contains { !isKotlinWhitespace($0) && $0 != "\u{00A0}" }
    }

    private static let metaCharset = Rx(#"<meta\b[^<>]*charset[^<>]*>"#, ignoreCase: true)
    private static let blockTag = Rx(#"<(?:p|div)\b[^<>]*>"#, ignoreCase: true)
    private static let widthAttr = Rx(#"\swidth\s*=\s*['"]?(-?\d+(?:\.\d+)?(?:em|pt|px|%))['"]?"#, ignoreCase: true)
    private static let heightAttr = Rx(#"\sheight\s*=\s*['"]?(\d+(?:\.\d+)?(?:em|pt|px|%))['"]?"#, ignoreCase: true)
    private static let styleAttr = Rx(#"\sstyle\s*=\s*(['"])(.*?)\1"#, ignoreCase: true)
    private static let zeroLength = Rx(#"0+(?:\.0+)?\D*"#)

    /// MOBI 6 paragraph attributes: `width` is the first-line indent (negative: hanging indent) and `height` the
    /// space before the block. Values without a unit are left alone. Logical properties keep the meaning in
    /// vertical text; the -webkit- forms are for old web views.
    static func mobiBlockStyle(_ tag: String) -> String {
        let width = widthAttr.find(tag)?.group(1)
        let height = heightAttr.find(tag)?.group(1)
        if width == nil && height == nil { return tag }
        var css = ""
        if let width {
            css += "text-indent: \(width);"
            if width.hasPrefix("-") {
                let w = String(width.dropFirst())
                css += " -webkit-margin-start: \(w); margin-inline-start: \(w);"
            }
        }
        if let height, !zeroLength.matches(height) {
            css += " -webkit-margin-before: \(height); margin-block-start: \(height);"
        }
        var out = widthAttr.replace(tag, with: "")
        out = heightAttr.replace(out, with: "")
        let style = css.trimmed
        if let existing = styleAttr.find(out) {
            let ns = out as NSString
            let replacement = " style=\"\(style) \(existing.group(2).replacingOccurrences(of: "\"", with: "'"))\""
            return ns.replacingCharacters(in: existing.range, with: replacement)
        }
        let close = out.hasSuffix("/>") ? out.count - 2 : out.count - 1
        let idx = out.index(out.startIndex, offsetBy: close)
        return String(out[..<idx]) + " style=\"\(style)\"" + String(out[idx...])
    }
}

/// MOBI locale codes (subset of the full table; enough for a language hint).
func mobiLanguage(_ language: Int, _ region: Int) -> String? {
    if language == 4 {
        let list = ["zh", "zh-TW", "zh-CN", "zh-HK", "zh-SG"]
        let i = region >> 2
        return i < list.count ? list[i] : "zh"
    }
    let table: [Int: String] = [
        1: "ar", 2: "bg", 3: "ca", 5: "cs", 6: "da", 7: "de", 8: "el", 9: "en", 10: "es",
        11: "fi", 12: "fr", 13: "he", 14: "hu", 15: "is", 16: "it", 17: "ja", 18: "ko",
        19: "nl", 20: "no", 21: "pl", 22: "pt", 24: "ro", 25: "ru", 26: "hr", 27: "sk",
        29: "sv", 30: "th", 31: "tr", 33: "id", 34: "uk", 41: "fa", 42: "vi", 57: "hi",
    ]
    return table[language]
}
