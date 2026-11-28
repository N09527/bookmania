import Foundation

extension Sync {
    public struct DeviceInfo: Sendable {
        public var id: String
        public var name: String
        public var platform: String
        public var app: String

        public init(id: String, name: String, platform: String, app: String) {
            self.id = id
            self.name = name
            self.platform = platform
            self.app = app
        }
    }
}

/// What a platform gives the engine: its data as snapshots, the writing of changes, and the baselines.
public protocol SyncAdapter: AnyObject {
    func librarySnapshot() -> Sync.LibrarySnapshot
    /// Writes `changes`; returns the ids ("w:", "c:", "s:") of the entries written.
    func applyLibrary(_ changes: Sync.LibraryChanges) -> Set<String>
    func progressSnapshot(_ work: String) -> Sync.ProgressSnapshot
    /// Writes the changes of a work's chapters; returns the parts written ("<chapter>|progress", "|bookmark", "|position").
    func applyProgress(_ work: String, _ changes: Sync.ProgressChanges) -> Set<String>
    func loadBaseline() -> Sync.Baseline
    func saveBaseline(_ baseline: Sync.Baseline)
    func loadWorkBaseline(_ work: String) -> Sync.WorkBaseline
    func saveWorkBaseline(_ work: String, _ baseline: Sync.WorkBaseline)
}

/// The local source's files, for the book file sync.
public protocol SyncFileAccess: AnyObject {
    /// The files in the folders of `works` and in their subfolders (one level), without hidden files; `t` is unused.
    func list(works: Set<String>) -> [Sync.FileItem]
    func fileURL(work: String, path: String) -> URL
    /// Moves a downloaded file (already checked) into place, creating its folder; it must not exist yet.
    func save(work: String, path: String, from temporary: URL) throws
}

/// The flows of sync-format.md section 5 (as Android's SyncEngine). One engine per account; calls must not run at
/// the same time.
public final class SyncEngine {
    public struct WorkResult: Sendable {
        public var work: String
        public var changes: Sync.ProgressChanges
        public var uploaded: Bool
    }

    public struct LibraryResult: Sendable {
        public var changes: Sync.LibraryChanges
        public var works: [WorkResult]
        /// Devices whose files have a newer format, left out.
        public var newerFormat: [String]
    }

    public struct FilesResult: Sendable {
        public var uploaded: [Sync.FileItem] = []
        public var downloaded: [Sync.FileItem] = []
        /// Same path, different size: nothing done.
        public var conflicts: [Sync.FileItem] = []
        /// Names that fail the checks of SyncNames.
        public var rejected: [Sync.FileItem] = []
        public var failed: [(Sync.FileItem, String)] = []
    }

    private let dav: WebDAVClient
    private let device: Sync.DeviceInfo
    private let adapter: SyncAdapter
    private let clock: () -> Int64

    private let root = ["Bookmania", "sync-v1"]
    private var devicesDir: [String] { root + ["devices"] }
    private var ownDir: [String] { devicesDir + [device.id] }
    private var filesDir: [String] { root + ["files"] }
    private var madeCollections = Set<[String]>()
    private var deviceList: [String]?

    public init(dav: WebDAVClient, device: Sync.DeviceInfo, adapter: SyncAdapter, clock: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.dav = dav
        self.device = device
        self.adapter = adapter
        self.clock = clock
    }

    private func ensure(_ path: [String]) async throws {
        for n in 0 ..< path.count {
            let p = Array(path[0 ... n])
            if madeCollections.contains(p) { continue }
            try await dav.mkcol(p)
            madeCollections.insert(p)
        }
    }

    private func ensureFolders() async throws {
        try await ensure(ownDir + ["progress"])
        try await ensure(filesDir)
    }

    /// The other devices' ids: listed again with `refresh`, else the last listing (if there is one).
    public func otherDevices(refresh: Bool = true) async throws -> [String] {
        if !refresh, let cached = deviceList { return cached }
        let list = try await dav.list(devicesDir)
            .filter { $0.collection && $0.name != device.id && SyncNames.validSegment($0.name) }
            .map(\.name)
            .sorted()
        deviceList = list
        return list
    }

    // MARK: Library

    public func syncLibrary() async throws -> LibraryResult {
        try await ensureFolders()
        var newer: [String] = []
        var remotes: [Sync.LibraryFile] = []
        for id in try await otherDevices(refresh: true) {
            guard var file = Sync.decode(Sync.LibraryFile.self, try await dav.get(devicesDir + [id, "library.json"])) else { continue }
            if file.format > Sync.format {
                newer.append(id)
                continue
            }
            file.device = id
            remotes.append(file)
        }
        var baseline = adapter.loadBaseline()
        let snapshot = adapter.librarySnapshot()
        let now = clock()
        let local = SyncMerge.annotate(snapshot, baseline, now: now, device: device.id)
        let merged = SyncMerge.merge(local, remotes.map(\.state), now: now, device: device.id)
        let (changes, equal) = SyncMerge.changes(merged, snapshot)
        let applied = changes.isEmpty ? [] : adapter.applyLibrary(changes)
        baseline.library = merged
        baseline.applied = equal.union(applied)
        baseline = try await upload(baseline, now: now)
        adapter.saveBaseline(baseline)

        // Progress another device rewrote since it was merged here, and progress this device could not send.
        var pull = Set<String>()
        for r in remotes {
            for (work, written) in r.progress where written > (baseline.seen[r.device]?[work] ?? 0) { pull.insert(work) }
        }
        var works: [WorkResult] = []
        for work in pull.union(baseline.pending).sorted() {
            works.append(try await syncWork(work, push: baseline.pending.contains(work), refreshDevices: false))
        }
        // A progress file listed but missing must not be asked for again and again.
        if !pull.isEmpty {
            var b = adapter.loadBaseline()
            for r in remotes {
                var m = b.seen[r.device] ?? [:]
                for (work, written) in r.progress where pull.contains(work) { m[work] = max(m[work] ?? 0, written) }
                b.seen[r.device] = m
            }
            adapter.saveBaseline(b)
        }
        return LibraryResult(changes: changes, works: works, newerFormat: newer)
    }

    /// Sends library.json and device.json when their content changed.
    private func upload(_ baseline: Sync.Baseline, now: Int64) async throws -> Sync.Baseline {
        var b = baseline
        let lib = b.library
        let content = Sync.encode(Sync.LibraryFile(device: device.id, written: 0, works: lib.works, categories: lib.categories, settings: lib.settings, progress: b.ownProgress))
        if content != b.uploadedLibrary {
            let file = Sync.LibraryFile(device: device.id, written: now, works: lib.works, categories: lib.categories, settings: lib.settings, progress: b.ownProgress)
            try await dav.putJSON(ownDir + ["library.json"], Sync.encode(file))
            b.uploadedLibrary = content
        }
        let deviceContent = Sync.encode(Sync.DeviceFile(device: device.id, name: device.name, platform: device.platform, app: device.app, written: 0))
        if deviceContent != b.uploadedDevice {
            let file = Sync.DeviceFile(device: device.id, name: device.name, platform: device.platform, app: device.app, written: now)
            try await dav.putJSON(ownDir + ["device.json"], Sync.encode(file))
            b.uploadedDevice = deviceContent
        }
        return b
    }

    // MARK: One work

    /// Merges a work's progress with the other devices' and writes the result here. With `push` (leaving the reader),
    /// this device's progress file and library.json are sent too; if that fails, the work is kept as pending.
    public func syncWork(_ work: String, push: Bool, refreshDevices: Bool = true) async throws -> WorkResult {
        do {
            try await ensureFolders()
            let name = SyncIds.progressFileName(work)
            var remotes: [Sync.ProgressFile] = []
            for id in try await otherDevices(refresh: refreshDevices) {
                guard var file = Sync.decode(Sync.ProgressFile.self, try await dav.get(devicesDir + [id, "progress", name])),
                      file.format <= Sync.format, file.work == work else { continue }
                file.device = id
                remotes.append(file)
            }
            let base = adapter.loadWorkBaseline(work)
            let snapshot = adapter.progressSnapshot(work)
            let now = clock()
            let local = SyncMerge.annotate(snapshot, base, now: now, device: device.id)
            let merged = SyncMerge.mergeProgress(local, remotes.map(\.state), now: now, device: device.id)
            let (changes, equal) = SyncMerge.changes(merged, snapshot)
            let applied = changes.isEmpty ? [] : adapter.applyProgress(work, changes)
            var nextBase = Sync.WorkBaseline(chapters: merged.chapters, applied: equal.union(applied), uploaded: base.uploaded)

            var lib = adapter.loadBaseline()
            for r in remotes {
                var m = lib.seen[r.device] ?? [:]
                m[work] = max(m[work] ?? 0, r.written)
                lib.seen[r.device] = m
            }
            var uploaded = false
            if push {
                let content = Sync.encode(Sync.ProgressFile(device: device.id, written: 0, work: work, chapters: merged.chapters))
                if content != base.uploaded && !merged.chapters.isEmpty {
                    let file = Sync.ProgressFile(device: device.id, written: now, work: work, chapters: merged.chapters)
                    try await dav.putJSON(ownDir + ["progress", name], Sync.encode(file))
                    nextBase.uploaded = content
                    lib.ownProgress[work] = now
                    uploaded = true
                }
                lib.pending.remove(work)
                lib = try await upload(lib, now: now)
            }
            adapter.saveWorkBaseline(work, nextBase)
            adapter.saveBaseline(lib)
            return WorkResult(work: work, changes: changes, uploaded: uploaded)
        } catch let e as SyncError {
            if push && e.kind != .auth && e.kind != .config {
                var lib = adapter.loadBaseline()
                if !lib.pending.contains(work) {
                    lib.pending.insert(work)
                    adapter.saveBaseline(lib)
                }
            }
            throw e
        }
    }

    // MARK: Book files

    /// sync-format.md section 5.3, for the local source works in the library (`libraryWorks`: their folders).
    public func syncFiles(_ access: SyncFileAccess, libraryWorks: Set<String>) async throws -> FilesResult {
        try await ensureFolders()
        var baseline = adapter.loadBaseline()
        var remote: [String: Sync.FileItem] = [:]
        var order: [String] = []
        func key(_ i: Sync.FileItem) -> String { i.work + "\u{0}" + i.path }
        for id in try await otherDevices() {
            guard let f = Sync.decode(Sync.FilesFile.self, try await dav.get(devicesDir + [id, "files.json"])), f.format <= Sync.format else { continue }
            for item in f.files where remote[key(item)] == nil {
                remote[key(item)] = item
                order.append(key(item))
            }
        }
        for item in baseline.uploadedFiles where remote[key(item)] == nil {
            remote[key(item)] = item
            order.append(key(item))
        }
        let localItems = access.list(works: libraryWorks).filter { libraryWorks.contains($0.work) }
        var local: [String: Sync.FileItem] = [:]
        for item in localItems { local[key(item)] = item }

        var result = FilesResult()
        var uploads: [Sync.FileItem] = []
        var downloads: [Sync.FileItem] = []
        for item in localItems.sorted(by: { key($0) < key($1) }) {
            if let r = remote[key(item)] {
                if r.size != item.size { result.conflicts.append(item) }
            } else if SyncNames.valid(item) {
                uploads.append(item)
            } else {
                result.rejected.append(item)
            }
        }
        for k in order {
            guard let item = remote[k], libraryWorks.contains(item.work), local[k] == nil else { continue }
            if SyncNames.valid(item) { downloads.append(item) } else { result.rejected.append(item) }
        }

        for item in uploads {
            do {
                let segments = item.path.split(separator: "/").map(String.init)
                try await ensure(filesDir + [item.work] + segments.dropLast())
                try await dav.put(filesDir + [item.work] + segments, .file(access.fileURL(work: item.work, path: item.path), contentType: "application/octet-stream"))
                var done = item
                done.t = clock()
                baseline.uploadedFiles.append(done)
                adapter.saveBaseline(baseline)
                result.uploaded.append(done)
            } catch let e as SyncError {
                if e.kind == .auth { throw e }
                result.failed.append((item, e.message))
            }
        }
        if !result.uploaded.isEmpty {
            let file = Sync.FilesFile(device: device.id, written: clock(), files: baseline.uploadedFiles)
            try await dav.putJSON(ownDir + ["files.json"], Sync.encode(file))
        }
        for item in downloads {
            do {
                guard let temporary = try await dav.download(filesDir + [item.work] + item.path.split(separator: "/").map(String.init)) else {
                    result.failed.append((item, "not on the server"))
                    continue
                }
                let size = ((try? FileManager.default.attributesOfItem(atPath: temporary.path))?[.size] as? NSNumber)?.int64Value ?? -1
                if size != item.size {
                    try? FileManager.default.removeItem(at: temporary)
                    result.failed.append((item, "size \(size), expected \(item.size)"))
                    continue
                }
                do {
                    try access.save(work: item.work, path: item.path, from: temporary)
                    result.downloaded.append(item)
                } catch {
                    try? FileManager.default.removeItem(at: temporary)
                    result.failed.append((item, "\(error)"))
                }
            } catch let e as SyncError {
                if e.kind == .auth { throw e }
                result.failed.append((item, e.message))
            }
        }
        return result
    }
}
