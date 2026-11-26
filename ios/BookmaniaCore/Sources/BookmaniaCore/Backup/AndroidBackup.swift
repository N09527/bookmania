import Foundation

// Android's backup file (.tachibk): a gzip-compressed protobuf message, written by kotlinx.serialization from the
// classes in eu.kanade.tachiyomi.data.backup.models (Backup.kt, BackupManga.kt, ...). Field numbers and defaults are
// the same as there; kotlinx leaves default values out, so a missing field takes the Kotlin default (note that
// `favorite` defaults to true). Fields this version does not use (tracking, scanlators, custom info, ...) are skipped
// when reading and not written.

public struct BackupChapterRecord: Equatable, Sendable {
    public var url: String                  // 1
    public var name: String                 // 2
    public var scanlator: String?           // 3
    public var read = false                 // 4
    public var bookmark = false             // 5
    public var lastPageRead = 0             // 6
    public var dateFetch: Int64 = 0         // 7
    public var dateUpload: Int64 = 0        // 8
    public var chapterNumber: Float = 0     // 9
    public var sourceOrder = 0              // 10
    public var pagesLeft = 0                // 800
    /// Bookmania: the exact position of a text book (EbookLocator JSON).
    public var ebookPosition: String?       // 20101

    public init(url: String, name: String) {
        self.url = url
        self.name = name
    }
}

public struct BackupHistoryRecord: Equatable, Sendable {
    public var url: String                  // 1
    public var lastRead: Int64              // 2
    public var readDuration: Int64 = 0      // 3

    public init(url: String, lastRead: Int64, readDuration: Int64 = 0) {
        self.url = url
        self.lastRead = lastRead
        self.readDuration = readDuration
    }
}

public struct BackupMangaRecord: Equatable, Sendable {
    public var source: Int64                // 1
    public var url: String                  // 2
    public var title = ""                   // 3
    public var artist: String?              // 4
    public var author: String?              // 5
    public var description: String?         // 6
    public var genre: [String] = []         // 7
    public var status = 0                   // 8
    public var thumbnailUrl: String?        // 9
    public var dateAdded: Int64 = 0         // 13
    public var viewer = 0                   // 14
    public var chapters: [BackupChapterRecord] = []   // 16
    /// The `order` of each category the manga is in (matched to the backup's categories by order, then by name).
    public var categories: [Int] = []       // 17
    public var favorite = true              // 100
    public var chapterFlags = 0             // 101
    public var viewerFlags: Int?            // 103
    public var history: [BackupHistoryRecord] = []    // 104

    public init(source: Int64, url: String) {
        self.source = source
        self.url = url
    }
}

public struct BackupCategoryRecord: Equatable, Sendable {
    public var name: String                 // 1
    public var order = 0                    // 2
    public var flags = 0                    // 100

    public init(name: String, order: Int = 0, flags: Int = 0) {
        self.name = name
        self.order = order
        self.flags = flags
    }
}

/// An app preference (BackupPreference with its PreferenceValue subclass).
public enum BackupPreferenceValue: Equatable, Sendable {
    case int(Int), long(Int64), float(Float), string(String), bool(Bool), stringSet([String])

    static let prefix = "eu.kanade.tachiyomi.data.backup.models."

    var typeName: String {
        switch self {
        case .int: return BackupPreferenceValue.prefix + "IntPreferenceValue"
        case .long: return BackupPreferenceValue.prefix + "LongPreferenceValue"
        case .float: return BackupPreferenceValue.prefix + "FloatPreferenceValue"
        case .string: return BackupPreferenceValue.prefix + "StringPreferenceValue"
        case .bool: return BackupPreferenceValue.prefix + "BooleanPreferenceValue"
        case .stringSet: return BackupPreferenceValue.prefix + "StringSetPreferenceValue"
        }
    }

    /// The value as the iOS preferences keep it (text).
    public var text: String {
        switch self {
        case let .int(v): return String(v)
        case let .long(v): return String(v)
        case let .float(v): return String(v)
        case let .string(v): return v
        case let .bool(v): return v ? "true" : "false"
        case let .stringSet(v): return v.sorted().joined(separator: ",")
        }
    }
}

public struct BackupPreferenceRecord: Equatable, Sendable {
    public var key: String
    public var value: BackupPreferenceValue

    public init(key: String, value: BackupPreferenceValue) {
        self.key = key
        self.value = value
    }
}

public struct AndroidBackup: Equatable, Sendable {
    public var mangas: [BackupMangaRecord] = []              // 1
    public var categories: [BackupCategoryRecord] = []       // 2
    /// (name, id) of the sources the mangas come from.
    public var sources: [(name: String, id: Int64)] = []     // 101
    public var preferences: [BackupPreferenceRecord] = []    // 104

    public init() {}

    public static func == (a: AndroidBackup, b: AndroidBackup) -> Bool {
        a.mangas == b.mangas && a.categories == b.categories && a.preferences == b.preferences
            && a.sources.map(\.name) == b.sources.map(\.name) && a.sources.map(\.id) == b.sources.map(\.id)
    }

    // MARK: Reading

    /// Reads a backup file: gzip-compressed (as Android writes them) or plain protobuf.
    public static func read(_ file: [UInt8]) throws -> AndroidBackup {
        let bytes = Gzip.isGzip(file) ? try Inflate.gzip(file, maxOutput: 512 << 20) : file
        return try decode(bytes[...])
    }

    static func decode(_ bytes: ArraySlice<UInt8>) throws -> AndroidBackup {
        var backup = AndroidBackup()
        for f in try ProtoReader.fields(bytes) {
            switch f.number {
            case 1: backup.mangas.append(try decodeManga(f.payload))
            case 2: backup.categories.append(try decodeCategory(f.payload))
            case 101:
                var name = "", id: Int64 = 0
                for s in try ProtoReader.fields(f.payload) {
                    if s.number == 1 { name = s.string } else if s.number == 2 { id = s.int64 }
                }
                backup.sources.append((name, id))
            case 104: if let p = try decodePreference(f.payload) { backup.preferences.append(p) }
            default: break
            }
        }
        return backup
    }

    static func decodeManga(_ bytes: ArraySlice<UInt8>) throws -> BackupMangaRecord {
        var m = BackupMangaRecord(source: 0, url: "")
        for f in try ProtoReader.fields(bytes) {
            switch f.number {
            case 1: m.source = f.int64
            case 2: m.url = f.string
            case 3: m.title = f.string
            case 4: m.artist = f.string
            case 5: m.author = f.string
            case 6: m.description = f.string
            case 7: m.genre.append(f.string)
            case 8: m.status = f.int32
            case 9: m.thumbnailUrl = f.string
            case 13: m.dateAdded = f.int64
            case 14: m.viewer = f.int32
            case 16: m.chapters.append(try decodeChapter(f.payload))
            case 17: m.categories.append(contentsOf: f.ints.map { Int(Int32(truncatingIfNeeded: $0)) })
            case 100: m.favorite = f.bool
            case 101: m.chapterFlags = f.int32
            case 103: m.viewerFlags = f.int32
            case 104: m.history.append(try decodeHistory(f.payload))
            default: break
            }
        }
        return m
    }

    static func decodeChapter(_ bytes: ArraySlice<UInt8>) throws -> BackupChapterRecord {
        var c = BackupChapterRecord(url: "", name: "")
        for f in try ProtoReader.fields(bytes) {
            switch f.number {
            case 1: c.url = f.string
            case 2: c.name = f.string
            case 3: c.scanlator = f.string
            case 4: c.read = f.bool
            case 5: c.bookmark = f.bool
            case 6: c.lastPageRead = f.int32
            case 7: c.dateFetch = f.int64
            case 8: c.dateUpload = f.int64
            case 9: c.chapterNumber = f.float
            case 10: c.sourceOrder = f.int32
            case 800: c.pagesLeft = f.int32
            case 20101: c.ebookPosition = f.string
            default: break
            }
        }
        return c
    }

    static func decodeHistory(_ bytes: ArraySlice<UInt8>) throws -> BackupHistoryRecord {
        var h = BackupHistoryRecord(url: "", lastRead: 0)
        for f in try ProtoReader.fields(bytes) {
            switch f.number {
            case 1: h.url = f.string
            case 2: h.lastRead = f.int64
            case 3: h.readDuration = f.int64
            default: break
            }
        }
        return h
    }

    static func decodeCategory(_ bytes: ArraySlice<UInt8>) throws -> BackupCategoryRecord {
        var c = BackupCategoryRecord(name: "")
        for f in try ProtoReader.fields(bytes) {
            switch f.number {
            case 1: c.name = f.string
            case 2: c.order = f.int32
            case 100: c.flags = f.int32
            default: break
            }
        }
        return c
    }

    /// A preference with a value type this version knows (polymorphic: 1 = class name, 2 = the value object).
    static func decodePreference(_ bytes: ArraySlice<UInt8>) throws -> BackupPreferenceRecord? {
        var key = ""
        var type = ""
        var valueFields: [ProtoField] = []
        for f in try ProtoReader.fields(bytes) {
            if f.number == 1 { key = f.string }
            if f.number == 2 {
                for v in try ProtoReader.fields(f.payload) {
                    if v.number == 1 { type = v.string }
                    if v.number == 2 { valueFields = try ProtoReader.fields(v.payload) }
                }
            }
        }
        let inner = valueFields.filter { $0.number == 1 }
        let value: BackupPreferenceValue
        switch type.afterLast(".", missing: type) {
        case "IntPreferenceValue": value = .int(inner.first?.int32 ?? 0)
        case "LongPreferenceValue": value = .long(inner.first?.int64 ?? 0)
        case "FloatPreferenceValue": value = .float(inner.first?.float ?? 0)
        case "StringPreferenceValue": value = .string(inner.first?.string ?? "")
        case "BooleanPreferenceValue": value = .bool(inner.first?.bool ?? false)
        case "StringSetPreferenceValue": value = .stringSet(inner.map(\.string))
        default: return nil
        }
        return BackupPreferenceRecord(key: key, value: value)
    }

    // MARK: Writing

    /// The backup as Android reads it (gzip-compressed protobuf).
    public func write() -> [UInt8] { Gzip.compress(encode()) }

    func encode() -> [UInt8] {
        var w = ProtoWriter()
        for m in mangas { w.message(1) { AndroidBackup.encodeManga(m, &$0) } }
        for c in categories {
            w.message(2) { cw in
                cw.string(1, c.name)
                cw.int(2, c.order)
                cw.int(100, c.flags)
            }
        }
        for s in sources {
            w.message(101) { sw in
                sw.string(1, s.name)
                sw.int(2, s.id)
            }
        }
        for p in preferences {
            w.message(104) { pw in
                pw.string(1, p.key)
                pw.message(2) { poly in
                    poly.string(1, p.value.typeName)
                    poly.message(2) { v in
                        switch p.value {
                        case let .int(x): v.int(1, x)
                        case let .long(x): v.int(1, x)
                        case let .float(x): v.float(1, x)
                        case let .string(x): v.string(1, x)
                        case let .bool(x): v.bool(1, x)
                        case let .stringSet(x): for s in x { v.string(1, s) }
                        }
                    }
                }
            }
        }
        return w.bytes
    }

    static func encodeManga(_ m: BackupMangaRecord, _ w: inout ProtoWriter) {
        w.int(1, m.source)
        w.string(2, m.url)
        w.string(3, m.title)
        if let v = m.artist { w.string(4, v) }
        if let v = m.author { w.string(5, v) }
        if let v = m.description { w.string(6, v) }
        for g in m.genre { w.string(7, g) }
        w.int(8, m.status)
        if let v = m.thumbnailUrl { w.string(9, v) }
        w.int(13, m.dateAdded)
        w.int(14, m.viewer)
        for c in m.chapters {
            w.message(16) { cw in
                cw.string(1, c.url)
                cw.string(2, c.name)
                if let v = c.scanlator { cw.string(3, v) }
                cw.bool(4, c.read)
                cw.bool(5, c.bookmark)
                cw.int(6, c.lastPageRead)
                cw.int(7, c.dateFetch)
                cw.int(8, c.dateUpload)
                cw.float(9, c.chapterNumber)
                cw.int(10, c.sourceOrder)
                cw.int(800, c.pagesLeft)
                if let v = c.ebookPosition { cw.string(20101, v) }
            }
        }
        for order in m.categories { w.int(17, order) }
        w.bool(100, m.favorite)
        w.int(101, m.chapterFlags)
        if let v = m.viewerFlags { w.int(103, v) }
        for h in m.history {
            w.message(104) { hw in
                hw.string(1, h.url)
                hw.int(2, h.lastRead)
                hw.int(3, h.readDuration)
            }
        }
    }
}
