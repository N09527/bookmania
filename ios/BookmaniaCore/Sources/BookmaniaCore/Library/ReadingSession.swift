import Foundation

/// Milliseconds since 1970, the unit of the library's dates (as on Android).
public func nowMillis() -> Int64 { Int64((Date().timeIntervalSince1970 * 1000).rounded()) }

/// Saves the reading progress of one open text book (port of Android's ReadingSession.kt):
///
/// - the exact position goes with the chapter; `lastPageRead` / `pagesLeft` get the estimated page numbers
///   (ReadingProgress) so the chapter list and the history show "page X of Y";
/// - reaching the last page marks the chapter read;
/// - the reading time goes to the history when the reader is left or the app goes to the background;
/// - in incognito mode nothing is saved (there are no trackers on iOS, which Android would still update).
public final class ReadingSession: @unchecked Sendable {
    public let chapterId: String
    private let store: LibraryStore
    private let incognito: () -> Bool
    private let now: () -> Int64
    private let lock = NSLock()
    private var _progress: ReadingProgress?
    private var readStart: Int64?

    public init(store: LibraryStore, chapterId: String, incognito: @escaping () -> Bool, now: @escaping () -> Int64 = nowMillis) {
        self.store = store
        self.chapterId = chapterId
        self.incognito = incognito
        self.now = now
    }

    /// Whole-book progress, once the documents' character counts are known.
    public var progress: ReadingProgress? {
        get { lock.lock(); defer { lock.unlock() }; return _progress }
        set { lock.lock(); _progress = newValue; lock.unlock() }
    }

    /// The position to restore, or nil to start at the beginning. As in the manga reader, which opens a read chapter
    /// at its first page: a book left on its last page or marked read starts from the beginning, and so does one whose
    /// progress was cleared in the chapter list ("mark as unread" sets `lastPageRead` to 0).
    ///
    /// When the user switched the book from the image reader (`switchedFromImages`), the page numbers and the read
    /// state are the image reader's, so the text position is taken back unless it was on the last page.
    public func positionToRestore(switchedFromImages: Bool = false) -> EbookLocator? {
        let chapter = store.chapter(chapterId)
        guard let saved = chapter.position else { return nil }
        if switchedFromImages { return saved.atEnd ? nil : saved }
        let cleared = (saved.chapterPage ?? 0) > 0 && chapter.lastPageRead == 0
        return saved.atEnd || chapter.read || cleared ? nil : saved
    }

    /// Without a saved position (e.g. a backup made without one) but with a page in the chapter list: that page's
    /// fraction of the book. A read chapter starts from the beginning.
    public func estimatedFraction() -> Double? {
        let chapter = store.chapter(chapterId)
        let read = chapter.lastPageRead, left = chapter.pagesLeft
        if chapter.read || read <= 0 || left <= 1 { return nil }
        return Double(read) / Double(read + left)
    }

    /// Saves `locator`: the first page shown, `page` of the `pages` pages of document `spine` in the current layout.
    /// Returns whether the chapter was finished just now.
    @discardableResult
    public func save(_ locator: EbookLocator, spine: Int, page: Int, pages: Int) -> Bool {
        if incognito() { return false }
        let estimate = progress?.pages(spine, page: page, pages: pages, atEnd: locator.atEnd)
        var finished = false
        store.updateChapter(chapterId) { c in
            var saved = locator
            saved.chapterPage = estimate?.0
            c.position = saved
            if locator.atEnd && !c.read {
                c.read = true
                finished = true
            }
            if let e = estimate {
                c.lastPageRead = e.0
                c.pagesLeft = e.1 - e.0
            }
        }
        return finished
    }

    /// Starts timing a reading session (the reader is shown).
    public func startTimer() {
        lock.lock()
        readStart = now()
        lock.unlock()
    }

    /// Stops the timer: (start, end) of the time read since `startTimer`, or nil when it was not running.
    public func stopTimer() -> (Int64, Int64)? {
        lock.lock()
        defer { lock.unlock() }
        guard let start = readStart else { return nil }
        readStart = nil
        return (start, now())
    }

    /// Adds a reading time from `stopTimer` to the chapter's history (not in incognito mode).
    public func saveReadingTime(_ start: Int64, _ end: Int64) {
        if incognito() { return }
        store.updateChapter(chapterId) { c in
            c.lastRead = end
            c.readDuration += max(0, end - start)
        }
    }

    /// Stops the timer and saves the time read.
    public func flushTimer() {
        guard let span = stopTimer() else { return }
        saveReadingTime(span.0, span.1)
    }
}
