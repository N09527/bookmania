import Foundation

/// The merge of sync-format.md, as Android's SyncMerge (Kotlin): every register takes the newest of its versions
/// (the larger t, then the larger d), the history takes the largest of each field. `annotate` turns a device's
/// snapshot into registers using the baseline of the last sync; `changes` lists what the device has to write.
public enum SyncMerge {
    public static func newer(_ t1: Int64, _ d1: String, _ t2: Int64, _ d2: String) -> Bool {
        t1 > t2 || (t1 == t2 && d1 > d2)
    }

    private static func pick<E: Equatable>(_ a: E?, _ b: E?, _ time: (E) -> (Int64, String)) -> E? {
        guard let a else { return b }
        guard let b else { return a }
        let (ta, da) = time(a), (tb, db) = time(b)
        return newer(ta, da, tb, db) || a == b ? a : b
    }

    private static func pick(_ a: Sync.WorkEntry?, _ b: Sync.WorkEntry?) -> Sync.WorkEntry? { pick(a, b) { ($0.t, $0.d) } }
    private static func pick(_ a: Sync.CategoryEntry?, _ b: Sync.CategoryEntry?) -> Sync.CategoryEntry? { pick(a, b) { ($0.t, $0.d) } }
    private static func pick(_ a: Sync.SettingEntry?, _ b: Sync.SettingEntry?) -> Sync.SettingEntry? { pick(a, b) { ($0.t, $0.d) } }
    private static func pick(_ a: Sync.ProgressPart?, _ b: Sync.ProgressPart?) -> Sync.ProgressPart? { pick(a, b) { ($0.t, $0.d) } }
    private static func pick(_ a: Sync.BookmarkPart?, _ b: Sync.BookmarkPart?) -> Sync.BookmarkPart? { pick(a, b) { ($0.t, $0.d) } }
    private static func pick(_ a: Sync.PositionPart?, _ b: Sync.PositionPart?) -> Sync.PositionPart? { pick(a, b) { ($0.t, $0.d) } }

    private static func maxHistory(_ a: Sync.HistoryPart?, _ b: Sync.HistoryPart?) -> Sync.HistoryPart? {
        let h = Sync.HistoryPart(lastRead: max(a?.lastRead ?? 0, b?.lastRead ?? 0), duration: max(a?.duration ?? 0, b?.duration ?? 0))
        return h.lastRead == 0 && h.duration == 0 ? nil : h
    }

    private static func entry(_ v: Sync.WorkValue, _ t: Int64, _ d: String) -> Sync.WorkEntry {
        Sync.WorkEntry(favorite: v.favorite, added: v.added, categories: v.categories.sorted(), chapterFlags: v.chapterFlags, viewerFlags: v.viewerFlags, t: t, d: d)
    }

    private static func entry(_ v: Sync.CategoryValue, _ t: Int64, _ d: String) -> Sync.CategoryEntry {
        Sync.CategoryEntry(order: v.order, flags: v.flags, deleted: false, t: t, d: d)
    }

    private static func entry(_ v: Sync.SettingValue, _ t: Int64, _ d: String) -> Sync.SettingEntry {
        Sync.SettingEntry(type: v.type, value: v.value, t: t, d: d)
    }

    /// The `updatedAt` a position records, or 0.
    public static func locatorTime(_ locator: String?) -> Int64 {
        guard let locator, let data = locator.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let number = object["updatedAt"] as? NSNumber else { return 0 }
        return number.int64Value
    }

    // MARK: Library

    /// This device's library as registers (sync-format.md section 4).
    public static func annotate(_ snapshot: Sync.LibrarySnapshot, _ baseline: Sync.Baseline, now: Int64, device: String) -> Sync.LibraryState {
        let applied = baseline.applied
        var works = baseline.library.works
        for (key, raw) in snapshot.works {
            let local = raw.normalized()
            let base = works[key]
            if applied.contains("w:\(key)") {
                if base == nil || base!.value != local {
                    // Added again since the last sync: that time; otherwise the change is only known now.
                    let t = local.favorite && local.added > (base?.t ?? 0) ? local.added : now
                    works[key] = entry(local, t, device)
                }
            } else if !local.isDefault {
                works[key] = pick(entry(local, local.favorite ? local.added : 0, device), base)
            }
        }
        var categories = baseline.library.categories
        for (name, local) in snapshot.categories {
            let base = categories[name]
            if applied.contains("c:\(name)") {
                if base == nil || base!.deleted || base!.value != local { categories[name] = entry(local, now, device) }
            } else {
                categories[name] = pick(entry(local, 0, device), base)
            }
        }
        var settings = baseline.library.settings
        for (key, local) in snapshot.settings {
            let base = settings[key]
            if applied.contains("s:\(key)") {
                if base == nil || base!.setting != local { settings[key] = entry(local, now, device) }
            } else {
                settings[key] = pick(entry(local, 0, device), base)
            }
        }
        for id in applied {
            if id.hasPrefix("c:") {
                let name = String(id.dropFirst(2))
                if snapshot.categories[name] == nil, let base = categories[name], !base.deleted {
                    categories[name] = Sync.CategoryEntry(deleted: true, t: now, d: device)
                }
            } else if id.hasPrefix("s:") {
                let key = String(id.dropFirst(2))
                if snapshot.settings[key] == nil, let base = settings[key], base.value != nil {
                    settings[key] = Sync.SettingEntry(type: base.type, value: nil, t: now, d: device)
                }
            }
        }
        return Sync.LibraryState(works: works, categories: categories, settings: settings)
    }

    static func merge(_ states: [Sync.LibraryState]) -> Sync.LibraryState {
        var m = Sync.LibraryState()
        for s in states {
            for (k, v) in s.works { m.works[k] = pick(m.works[k], v) }
            for (k, v) in s.categories { m.categories[k] = pick(m.categories[k], v) }
            for (k, v) in s.settings { m.settings[k] = pick(m.settings[k], v) }
        }
        return m
    }

    /// Merges this device's registers with the other devices'. An entry that only this device has, from its first
    /// sync (t = 0), becomes a change made `now` (sync-format.md section 4).
    public static func merge(_ local: Sync.LibraryState, _ remotes: [Sync.LibraryState], now: Int64, device: String) -> Sync.LibraryState {
        var m = merge([local] + remotes)
        for (k, e) in m.works where e.t == 0 && e.d == device && !remotes.contains(where: { $0.works[k] != nil }) {
            var p = e
            p.t = now
            m.works[k] = p
        }
        for (k, e) in m.categories where e.t == 0 && e.d == device && !remotes.contains(where: { $0.categories[k] != nil }) {
            var p = e
            p.t = now
            m.categories[k] = p
        }
        for (k, e) in m.settings where e.t == 0 && e.d == device && !remotes.contains(where: { $0.settings[k] != nil }) {
            var p = e
            p.t = now
            m.settings[k] = p
        }
        return m
    }

    /// What the device has to write to take `merged`, and the entries it already has ("w:", "c:", "s:" ids).
    public static func changes(_ merged: Sync.LibraryState, _ snapshot: Sync.LibrarySnapshot) -> (Sync.LibraryChanges, Set<String>) {
        var equal = Set<String>()
        var changes = Sync.LibraryChanges()
        for (key, e) in merged.works {
            let local = snapshot.works[key]?.normalized()
            if local == e.value {
                equal.insert("w:\(key)")
            } else if local == nil && e.value.isDefault {
                continue
            } else {
                changes.works[key] = e.value
            }
        }
        var deleted: [String] = []
        for (name, e) in merged.categories {
            let local = snapshot.categories[name]
            if e.deleted {
                if local != nil { deleted.append(name) }
            } else if local == e.value {
                equal.insert("c:\(name)")
            } else {
                changes.categories[name] = e.value
            }
        }
        changes.deletedCategories = deleted.sorted()
        for (key, e) in merged.settings {
            let local = snapshot.settings[key]
            if local == e.setting {
                equal.insert("s:\(key)")
            } else if e.value == nil && local == nil {
                continue
            } else {
                changes.settings[key] = e.setting
            }
        }
        return (changes, equal)
    }

    // MARK: Progress of one work

    /// This device's chapters of a work as registers (sync-format.md section 4).
    public static func annotate(_ snapshot: Sync.ProgressSnapshot, _ baseline: Sync.WorkBaseline, now: Int64, device: String) -> Sync.ProgressState {
        let applied = baseline.applied
        var chapters = baseline.chapters
        for (key, local) in snapshot.chapters {
            let base = chapters[key] ?? Sync.ChapterEntry()
            var progress = base.progress
            let lp = local.progress
            if applied.contains("\(key)|progress") {
                if progress == nil || progress!.value != lp {
                    let t = local.lastRead > (progress?.t ?? 0) ? local.lastRead : now
                    progress = Sync.ProgressPart(read: lp.read, page: lp.page, left: lp.left, t: t, d: device)
                }
            } else if !lp.isDefault {
                progress = pick(Sync.ProgressPart(read: lp.read, page: lp.page, left: lp.left, t: local.lastRead, d: device), progress)
            }
            var bookmark = base.bookmark
            if applied.contains("\(key)|bookmark") {
                if bookmark == nil || bookmark!.value != local.bookmark { bookmark = Sync.BookmarkPart(value: local.bookmark, t: now, d: device) }
            } else if local.bookmark {
                bookmark = pick(Sync.BookmarkPart(value: true, t: 0, d: device), bookmark)
            }
            var position = base.position
            if applied.contains("\(key)|position") {
                if position == nil || position!.locator != local.locator {
                    let recorded = locatorTime(local.locator)
                    position = Sync.PositionPart(locator: local.locator, t: recorded > (position?.t ?? 0) ? recorded : now, d: device)
                }
            } else if local.locator != nil {
                position = pick(Sync.PositionPart(locator: local.locator, t: locatorTime(local.locator), d: device), position)
            }
            let history = maxHistory(base.history, Sync.HistoryPart(lastRead: local.lastRead, duration: local.duration))
            let entry = Sync.ChapterEntry(progress: progress, bookmark: bookmark, position: position, history: history)
            if !entry.isEmpty { chapters[key] = entry }
        }
        return Sync.ProgressState(chapters: chapters)
    }

    static func mergeProgress(_ states: [Sync.ProgressState]) -> Sync.ProgressState {
        var chapters: [String: Sync.ChapterEntry] = [:]
        for s in states {
            for (k, v) in s.chapters {
                if let c = chapters[k] {
                    chapters[k] = Sync.ChapterEntry(
                        progress: pick(c.progress, v.progress),
                        bookmark: pick(c.bookmark, v.bookmark),
                        position: pick(c.position, v.position),
                        history: maxHistory(c.history, v.history)
                    )
                } else {
                    chapters[k] = v
                }
            }
        }
        return Sync.ProgressState(chapters: chapters)
    }

    /// Merges this device's chapters with the other devices'; first-sync parts only this device has become changes
    /// made `now`.
    public static func mergeProgress(_ local: Sync.ProgressState, _ remotes: [Sync.ProgressState], now: Int64, device: String) -> Sync.ProgressState {
        var m = mergeProgress([local] + remotes)
        for (k, c) in m.chapters {
            var e = c
            if let p = e.progress, p.t == 0, p.d == device, !remotes.contains(where: { $0.chapters[k]?.progress != nil }) { e.progress?.t = now }
            if let b = e.bookmark, b.t == 0, b.d == device, !remotes.contains(where: { $0.chapters[k]?.bookmark != nil }) { e.bookmark?.t = now }
            if let p = e.position, p.t == 0, p.d == device, !remotes.contains(where: { $0.chapters[k]?.position != nil }) { e.position?.t = now }
            m.chapters[k] = e
        }
        return m
    }

    /// What the device has to write to take `merged`, and the parts it already has ("<key>|progress" and so on).
    public static func changes(_ merged: Sync.ProgressState, _ snapshot: Sync.ProgressSnapshot) -> (Sync.ProgressChanges, Set<String>) {
        var equal = Set<String>()
        var changes: [String: Sync.ChapterChange] = [:]
        for (key, e) in merged.chapters {
            let local = snapshot.chapters[key]
            var change = Sync.ChapterChange()
            if let p = e.progress {
                if local?.progress == p.value {
                    equal.insert("\(key)|progress")
                } else if !(local == nil && p.value.isDefault) {
                    change.progress = p.value
                }
            }
            if let b = e.bookmark {
                if local?.bookmark == b.value {
                    equal.insert("\(key)|bookmark")
                } else if !(local == nil && !b.value) {
                    change.bookmark = b.value
                }
            }
            if let p = e.position {
                if let local, local.locator == p.locator {
                    equal.insert("\(key)|position")
                } else if !(local == nil && p.locator == nil) {
                    change.position = Sync.PositionChange(locator: p.locator)
                }
            }
            if let h = e.history {
                let lastRead = max(h.lastRead, local?.lastRead ?? 0)
                let duration = max(h.duration, local?.duration ?? 0)
                if lastRead != (local?.lastRead ?? 0) || duration != (local?.duration ?? 0) {
                    change.history = Sync.HistoryPart(lastRead: lastRead, duration: duration)
                }
            }
            if change.progress != nil || change.bookmark != nil || change.position != nil || change.history != nil {
                changes[key] = change
            }
        }
        return (Sync.ProgressChanges(chapters: changes), equal)
    }
}
