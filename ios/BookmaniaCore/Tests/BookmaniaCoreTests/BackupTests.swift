import Foundation
import Testing
@testable import BookmaniaCore

@Suite struct BackupTests {
    private func work(_ id: String, _ files: [String]) -> LocalWork {
        LocalWork(id: id, folder: URL(fileURLWithPath: "/local/\(id)"), title: id,
                  chapters: files.map { LocalChapter(id: "\(id)/\($0)", file: URL(fileURLWithPath: "/local/\(id)/\($0)"), kind: .epub,
                                                     fileTitle: $0.beforeLast(".", missing: $0), modified: Date(timeIntervalSince1970: 1000)) })
    }

    @Test func protobufBasics() throws {
        var w = ProtoWriter()
        w.int(1, -1)
        w.int(2, Int64(1) << 40)
        w.bool(3, true)
        w.float(4, 2.5)
        w.string(5, "直排")
        w.message(6) { $0.int(1, 7) }
        let fields = try ProtoReader.fields(w.bytes[...])
        #expect(fields.map(\.number) == [1, 2, 3, 4, 5, 6])
        #expect(fields[0].int32 == -1 && fields[0].int64 == -1)
        #expect(fields[1].int64 == 1 << 40)
        #expect(fields[2].bool)
        #expect(fields[3].float == 2.5)
        #expect(fields[4].string == "直排")
        #expect(try ProtoReader.fields(fields[5].payload).first?.int32 == 7)
        // -1 as int32 takes ten bytes (protobuf), and a packed list is read too.
        var negative = ProtoWriter()
        negative.int(1, -1)
        #expect(negative.bytes.count == 11)
        let packed: [UInt8] = [0x8A, 0x01, 0x03, 0x01, 0x02, 0x03] // field 17, wire type 2, [1, 2, 3]
        #expect(try ProtoReader.fields(packed[...]).first?.ints == [1, 2, 3])
        #expect(throws: ProtoError.self) { try ProtoReader.fields([0x0A, 0x05, 0x01][...]) }
    }

    @Test func gzipRoundTrip() throws {
        let big = (0 ..< 200_000).map { UInt8($0 % 251) }
        for data in [[UInt8](), Array("hello".utf8), big] {
            let gz = Gzip.compress(data)
            #expect(Gzip.isGzip(gz))
            #expect(try Inflate.gzip(gz, maxOutput: 1 << 20) == data)
        }
        #expect(Gzip.crc32(Array("123456789".utf8)) == 0xCBF4_3926) // the standard check value
    }

    @Test func backupRoundTripAndAndroidDefaults() throws {
        var m = BackupMangaRecord(source: 0, url: "直排測試書")
        m.title = "直排測試書"
        m.genre = ["小說", "推理"]
        m.categories = [0, 2]
        m.favorite = false
        m.viewerFlags = 2
        var c = BackupChapterRecord(url: "直排測試書/a.epub", name: "a")
        c.read = true
        c.lastPageRead = 12
        c.pagesLeft = 3
        c.chapterNumber = 1.5
        c.ebookPosition = EbookLocator(spine: 1, href: "x.xhtml", progression: 0.5, updatedAt: 9).toJSON()
        m.chapters = [c]
        m.history = [BackupHistoryRecord(url: "直排測試書/a.epub", lastRead: 1_700_000_000_000, readDuration: 60_000)]
        var b = AndroidBackup()
        b.mangas = [m]
        b.categories = [BackupCategoryRecord(name: "小說", order: 0), BackupCategoryRecord(name: "漫畫", order: 2, flags: 5)]
        b.sources = [(name: "Local source", id: 0)]
        b.preferences = [
            BackupPreferenceRecord(key: "pref_ebook_fontSize", value: .string("22")),
            BackupPreferenceRecord(key: "pref_ebook_gutter_shadow", value: .bool(false)),
            BackupPreferenceRecord(key: "pref_reader_theme_key", value: .int(4)),
            BackupPreferenceRecord(key: "collapsed", value: .stringSet(["1", "3"])),
            BackupPreferenceRecord(key: "f", value: .float(1.25)),
            BackupPreferenceRecord(key: "l", value: .long(1 << 40)),
        ]
        let read = try AndroidBackup.read(b.write())
        #expect(read == b)
        // A manga written by Android without field 100 is in the library (the Kotlin default is true).
        var w = ProtoWriter()
        w.message(1) { mw in
            mw.int(1, 0)
            mw.string(2, "w")
        }
        #expect(try AndroidBackup.read(w.bytes).mangas.first?.favorite == true)
        // Unknown fields (tracking, a newer field) are skipped.
        var unknown = ProtoWriter()
        unknown.message(1) { mw in
            mw.int(1, 0)
            mw.string(2, "w")
            mw.message(18) { $0.int(1, 3) }
            mw.int(999, 1)
        }
        #expect(try AndroidBackup.read(unknown.bytes).mangas.first?.url == "w")
    }

    @Test func creatingABackup() {
        let works = [work("甲", ["1.epub", "2.epub"]), work("乙", ["1.epub"]), work("丙", ["1.epub"])]
        var state = LibraryState()
        state.categories = [LibraryCategory(id: 7, name: "小說", order: 3)]
        var fav = WorkState()
        fav.favorite = true
        fav.categoryIds = [7]
        fav.dateAdded = 5
        state.works["甲"] = fav
        var read = ChapterState()
        read.read = true
        read.lastRead = 100
        read.readDuration = 9
        read.position = EbookLocator(spine: 0, href: "a.xhtml", updatedAt: 3)
        state.chapters["甲/2.epub"] = read
        var other = ChapterState()
        other.lastPageRead = 4
        state.chapters["乙/1.epub"] = other // read, not in the library: backed up too
        var opened = ChapterState()
        opened.lastRead = 50
        state.chapters["丙/1.epub"] = opened // only opened (no page, not read), not in the library: left out, as on Android
        let b = BackupMapper.backup(works: works, state: state, preferences: [
            "pref_ebook_fontSize": "22", "pref_ebook_gutter_shadow": "false", "pref_reader_theme_key": "4", "unrelated_key": "x",
            "pref_ebook_override_0123": "{}",
        ])
        #expect(b.mangas.map(\.url) == ["甲", "乙"])
        let m = b.mangas[0]
        #expect(m.favorite && m.dateAdded == 5 && m.categories == [3])
        // Android's order: the highest chapter first (source order 0).
        #expect(m.chapters.map(\.url) == ["甲/2.epub", "甲/1.epub"] && m.chapters.map(\.sourceOrder) == [0, 1])
        #expect(m.chapters[0].read && EbookLocator.fromJSON(m.chapters[0].ebookPosition)?.updatedAt == 3)
        #expect(m.history == [BackupHistoryRecord(url: "甲/2.epub", lastRead: 100, readDuration: 9)])
        #expect(!b.mangas[1].favorite)
        #expect(b.categories == [BackupCategoryRecord(name: "小說", order: 3)])
        #expect(b.preferences.map(\.key) == ["pref_ebook_fontSize", "pref_ebook_gutter_shadow", "pref_ebook_override_0123", "pref_reader_theme_key"])
        #expect(b.preferences.first { $0.key == "pref_ebook_gutter_shadow" }?.value == .bool(false))
        #expect(b.preferences.first { $0.key == "pref_reader_theme_key" }?.value == .int(4))
    }

    @Test func restoringMergesAsAndroidDoes() {
        var state = LibraryState()
        state.categories = [LibraryCategory(id: 1, name: "漫畫", order: 0)]
        state.nextCategoryId = 2
        var readHere = ChapterState()
        readHere.read = true
        readHere.lastPageRead = 9
        state.chapters["w/a.epub"] = readHere
        var pageHere = ChapterState()
        pageHere.lastPageRead = 5
        pageHere.bookmark = true
        pageHere.position = EbookLocator(spine: 0, href: "x", updatedAt: 500)
        state.chapters["w/b.epub"] = pageHere

        var b = AndroidBackup()
        b.categories = [BackupCategoryRecord(name: "小說", order: 0), BackupCategoryRecord(name: "漫畫", order: 1)]
        var m = BackupMangaRecord(source: 0, url: "w")
        m.categories = [0, 1]
        m.dateAdded = 77
        var a = BackupChapterRecord(url: "w/a.epub", name: "a") // unread in the backup
        a.lastPageRead = 2
        var bb = BackupChapterRecord(url: "w/b.epub", name: "b")
        bb.lastPageRead = 0
        bb.ebookPosition = EbookLocator(spine: 0, href: "x", updatedAt: 100).toJSON() // older than the one here
        var c = BackupChapterRecord(url: "w/c.epub", name: "c")
        c.read = true
        c.ebookPosition = EbookLocator(spine: 2, href: "z", updatedAt: 50).toJSON()
        m.chapters = [a, bb, c]
        m.history = [BackupHistoryRecord(url: "w/c.epub", lastRead: 300, readDuration: 40)]
        b.mangas = [m, BackupMangaRecord(source: 123, url: "/online/1")]
        b.preferences = [BackupPreferenceRecord(key: "pref_ebook_fontSize", value: .string("24")),
                         BackupPreferenceRecord(key: "some_android_only_key", value: .bool(true))]
        let prefs = MemoryPreferenceStore()
        let result = BackupMapper.restore(b, into: &state, preferences: prefs)
        #expect(result == BackupMapper.RestoreResult(works: 1, skipped: 1, positions: 1, preferences: 1))
        #expect(state.categories.map(\.name) == ["漫畫", "小說"])
        let w = state.works["w"]!
        #expect(w.favorite && w.dateAdded == 77 && Set(w.categoryIds) == [1, 2])
        #expect(state.chapters["w/a.epub"]!.read && state.chapters["w/a.epub"]!.lastPageRead == 9) // read here stays read
        #expect(state.chapters["w/b.epub"]!.lastPageRead == 5 && state.chapters["w/b.epub"]!.bookmark) // page here kept
        #expect(state.chapters["w/b.epub"]!.position?.updatedAt == 500) // the newer position here is kept
        #expect(state.chapters["w/c.epub"]!.read && state.chapters["w/c.epub"]!.position?.href == "z")
        #expect(state.chapters["w/c.epub"]!.lastRead == 300 && state.chapters["w/c.epub"]!.readDuration == 40)
        #expect(prefs.values == ["pref_ebook_fontSize": "24"])
        #expect(BackupMapper.fileName(date: Date(timeIntervalSince1970: 0)).hasSuffix(".tachibk"))
    }

    /// The fixtures were written by the other side (Android's IosBackupInteropTest checks ios-backup.tachibk).
    @Test func aBackupWrittenByAndroid() throws {
        let backup = try AndroidBackup.read(try Fixtures.bytes("backup/android-backup.tachibk"))
        #expect(backup.mangas.map(\.url) == ["直排測試書 EPUB", "漫畫測試", "/manga/1"])
        let m = backup.mangas[0]
        #expect(m.favorite) // Android leaves the field out: true is its default
        #expect(m.title == "直排測試書" && m.author == "Bookmania 測試" && m.genre == ["小說"] && m.status == 2)
        #expect(m.dateAdded == 1_700_000_000_000 && m.categories == [1] && m.chapterFlags == 0x1001 && m.viewerFlags == 2)
        #expect(m.chapters.count == 2)
        let v = m.chapters[0]
        #expect(v.url == "直排測試書 EPUB/zh-vertical.epub" && v.name == "zh-vertical" && !v.read && v.bookmark)
        #expect(v.lastPageRead == 12 && v.pagesLeft == 30 && v.dateFetch == 1_700_000_000_500 && v.dateUpload == 1_600_000_000_000)
        #expect(v.chapterNumber == 1)
        #expect(EbookLocator.fromJSON(v.ebookPosition) == EbookLocator(
            spine: 1, href: "OEBPS/text/ch02.xhtml", location: [55, 0], text: "【第１３段】長一點的段落",
            progression: 0.29, total: 0.43, chapterPage: 12, updatedAt: 1_700_000_000_000))
        #expect(m.chapters[1].read && m.chapters[1].sourceOrder == 1)
        #expect(m.history == [BackupHistoryRecord(url: "直排測試書 EPUB/zh-vertical.epub", lastRead: 1_700_000_100_000, readDuration: 120_000)])
        #expect(!backup.mangas[1].favorite && backup.mangas[1].viewerFlags == 1 && backup.mangas[1].chapters.first?.lastPageRead == 5)
        #expect(backup.mangas[2].source == 2_499_283_573_021_220_255)
        #expect(backup.categories == [BackupCategoryRecord(name: "漫畫", order: 0), BackupCategoryRecord(name: "小說", order: 1)])
        #expect(backup.sources.map(\.id) == [0, 2_499_283_573_021_220_255])
        #expect(backup.preferences == [
            BackupPreferenceRecord(key: "pref_ebook_fontSize", value: .string("24")),
            BackupPreferenceRecord(key: "pref_ebook_gutter_shadow", value: .bool(false)),
            BackupPreferenceRecord(key: "pref_reader_theme_key", value: .int(4)),
        ])
        // Restored here: the two local works; the online one is skipped.
        var state = LibraryState()
        let prefs = MemoryPreferenceStore()
        let result = BackupMapper.restore(backup, into: &state, preferences: prefs)
        #expect(result == BackupMapper.RestoreResult(works: 2, skipped: 1, positions: 1, preferences: 3))
        let novel = state.categories.first { $0.name == "小說" }?.id
        #expect(state.works["直排測試書 EPUB"]?.categoryIds == [novel].compactMap { $0 })
        #expect(state.chapters["直排測試書 EPUB/zh-vertical.epub"]?.position?.chapterPage == 12)
        #expect(prefs.values["pref_ebook_gutter_shadow"] == "false" && prefs.values["pref_reader_theme_key"] == "4")
    }

    @Test func theIOSFixtureReadsBack() throws {
        let backup = try AndroidBackup.read(try Fixtures.bytes("backup/ios-backup.tachibk"))
        #expect(backup.mangas.map(\.url) == ["直排測試書 EPUB", "漫畫測試"])
        #expect(backup.preferences.map(\.key) == ["pref_ebook_fontSize", "pref_ebook_gutter_shadow", "pref_ebook_page_turn", "pref_reader_theme_key"])
    }
}
