import BookmaniaCore
import UIKit

/// Reading progress (EbookReaderActivity's position code and ReadingSession on Android): where the book opens, the
/// position shown, the read state, the page numbers of the chapter list, and the reading time for the history.
extension TextReaderViewController {

    /// Sets up the reading session once the book is open: where to start, the timer, the character counts.
    func startSession() {
        let prefs = env.readerPreferences
        let session = ReadingSession(store: env.library, chapterId: chapter.id, incognito: { prefs.incognitoMode })
        self.session = session
        restoreTarget = session.positionToRestore(switchedFromImages: switchedFromImages)
        session.startTimer()
        observeLifecycle()
        // Without a saved position but with a page in the chapter list (e.g. a backup made without one), the book
        // starts near that page, located with the character counts: the first document waits for them.
        let estimate = restoreTarget == nil ? session.estimatedFraction() : nil
        waitingForCounts = estimate != nil
        loadCharCounts { [weak self] progress in
            guard let self else { return }
            if let estimate, let progress, self.waitingForCounts {
                let (spine, fraction) = progress.locate(estimate)
                if self.spine.indices.contains(spine) {
                    self.restoreTarget = EbookLocator(spine: spine, href: self.spine[spine].href, progression: fraction)
                }
            }
            if self.waitingForCounts {
                self.waitingForCounts = false
                if self.shellLoaded { self.openInitial() }
            } else {
                // The page estimate in the chapter list can now be written.
                Task { await self.capturePosition() }
            }
        }
    }

    /// Character counts of the book's documents for whole-book progress: cached for this version of the file, else
    /// counted from a separate copy of the book (the open one serves the web view).
    private func loadCharCounts(_ done: @escaping (ReadingProgress?) -> Void) {
        let file = chapter.file
        let id = chapter.id
        let ext = file.pathExtension.lowercased()
        let cache = env.ebookInfo
        let spineCount = spine.count
        Task { [weak self] in
            let counts = await Task.detached(priority: .utility) { () -> [Int]? in
                let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                let size = Int64(values?.fileSize ?? -1)
                let modified = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
                if let cached = cache.counts(id, size: size, modified: modified), cached.count == spineCount { return cached }
                guard let source = try? FileSource(url: file), let publication = try? BookOpener.open(source, extension: ext) else { return nil }
                defer { publication.close() }
                let counts = BookStats.charCounts(publication)
                cache.store(id, size: size, modified: modified, counts: counts)
                return counts.count == spineCount ? counts : nil
            }.value
            guard let self else { return }
            let progress = counts.map { ReadingProgress($0) }
            self.session?.progress = progress
            self.progressSlider.isEnabled = progress != nil
            done(progress)
        }
    }

    /// Reads the position shown now from the shell and saves it shortly after (page turns come in bursts).
    func capturePosition() async {
        guard !busy, let session, messageView.isHidden, spine.indices.contains(spineIndex),
              let text = await eval("JSON.stringify(window.__reader.position())"),
              let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return }
        let index = spineIndex
        let item = spine[index]
        let location = (object["location"] as? [NSNumber]).map { $0.map(\.intValue) }.flatMap { $0.count == 2 ? $0 : nil }
        let chars = (object["chars"] as? NSNumber)?.intValue ?? 0
        let before = (object["before"] as? NSNumber)?.intValue
        let shownPage = (object["page"] as? NSNumber)?.intValue ?? 0
        let docPages = max(1, (object["pages"] as? NSNumber)?.intValue ?? 1)
        let shownColumns = (object["cols"] as? NSNumber)?.intValue ?? 1
        var progression = 0.0
        if location != nil, let before, chars > 0 { progression = min(max(Double(before) / Double(chars), 0), 1) }
        let pageProgression: Double? = location == nil ? min(max(Double(shownPage) / Double(docPages), 0), 1) : nil
        let atEnd = shownPage + shownColumns > docPages - 1 && !linearIndices().contains { $0 > index }
        let total = atEnd ? 1 : session.progress?.total(index, pageProgression ?? progression)
        currentLocator = EbookLocator(
            spine: index, href: item.href, location: location, text: object["text"] as? String ?? "",
            progression: progression, pageProgression: pageProgression, total: total, atEnd: atEnd, updatedAt: nowMillis()
        )
        currentDocPages = docPages
        currentPage = shownPage
        if let total, !progressSlider.isTracking { progressSlider.value = Float(total) }
        scheduleSave()
    }

    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.persistPosition()
        }
    }

    /// Writes the current position, the page numbers and the read state.
    func persistPosition() {
        guard let locator = currentLocator, let session else { return }
        session.save(locator, spine: locator.spine, page: currentPage, pages: currentDocPages)
    }

    /// The reader is left (closed, or another chapter opens): the position and the reading time are saved.
    func leaveSession() {
        saveTask?.cancel()
        persistPosition()
        session?.flushTimer()
    }

    private func observeLifecycle() {
        guard lifecycleObservers.isEmpty else { return }
        let center = NotificationCenter.default
        lifecycleObservers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pageTurner?.end()
                self.saveTask?.cancel()
                self.persistPosition()
                self.session?.flushTimer()
                self.env.library.flush()
            }
        })
        lifecycleObservers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.session?.startTimer()
            }
        })
    }
}
