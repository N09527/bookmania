import BookmaniaCore
import Foundation
import Network
import UIKit

/// The WebDAV sync's own settings on this device. They are not synced and not in backups (the sync and BackupMapper
/// take only the keys they know). The password is in the keychain (SyncKeychain).
enum SyncSettingsKeys {
    static let enabled = "bookmania_sync_enabled"
    static let url = "bookmania_sync_url"
    static let user = "bookmania_sync_user"
    static let files = "bookmania_sync_files"
    static let filesWiFiOnly = "bookmania_sync_files_wifi_only"
    static let deviceId = "bookmania_sync_device_id"
    static let lastSync = "bookmania_sync_last"
    static let lastError = "bookmania_sync_last_error"
    static let conflicts = "bookmania_sync_conflicts"
    static let fileProblems = "bookmania_sync_file_problems"
}

extension Notification.Name {
    /// Book files arrived in the local folder (the library scans it again); posted on the main thread.
    static let syncDownloadedFiles = Notification.Name("bookmania.syncDownloadedFiles")
}

/// The WebDAV sync on iOS (docs/extensions-and-sync, sync-format.md section 5), as on Android (SyncManager):
/// - the library and the settings when the app becomes active, and shortly after they change here;
/// - a work's progress before a reader opens it (waiting at most 5 seconds) and after the reader is left or the app
///   goes to the background with a reader open;
/// - the book files of the local source works in the library, after a library sync (only on Wi-Fi unless the user
///   allows any network).
/// One sync runs at a time: the engine is not made for concurrent use.
@MainActor
final class SyncService: ObservableObject {
    static let shared = SyncService()

    @Published private(set) var isSyncing = false
    /// The outcome of the last syncs, for the settings screen.
    @Published private(set) var lastSync: Date?
    @Published private(set) var lastError: String?
    @Published private(set) var conflicts: [String] = []
    @Published private(set) var fileProblems: [String] = []

    static let pullTimeout: UInt64 = 5_000_000_000
    static let debounce: UInt64 = 15_000_000_000

    private let env = AppEnvironment.shared
    private let defaults = UserDefaults.standard
    private var engines: Engines?
    private var chain: Task<Void, Never>?
    private var running = 0
    private var scheduledLibrarySync: Task<Void, Never>?
    /// Library and settings notifications until then come from the sync's own writes.
    private var applyingUntil = Date.distantPast
    private var syncedSettings: [String: String] = [:]
    private var observers: [NSObjectProtocol] = []
    private var started = false
    private let pathMonitor = NWPathMonitor()
    private var onExpensiveNetwork = false
    /// The work of the reader that is open, sent when the app goes to the background.
    private(set) var readingWork: String?

    private struct Engines {
        let key: String
        let library: SyncEngine
        let files: SyncEngine
        let adapter: LibrarySyncAdapter
    }

    private init() {
        let last = defaults.double(forKey: SyncSettingsKeys.lastSync)
        lastSync = last > 0 ? Date(timeIntervalSince1970: last) : nil
        lastError = defaults.string(forKey: SyncSettingsKeys.lastError)
        conflicts = defaults.stringArray(forKey: SyncSettingsKeys.conflicts) ?? []
        fileProblems = defaults.stringArray(forKey: SyncSettingsKeys.fileProblems) ?? []
    }

    // MARK: Settings

    var serverURL: String { defaults.string(forKey: SyncSettingsKeys.url) ?? "" }
    var user: String { defaults.string(forKey: SyncSettingsKeys.user) ?? "" }
    var isEnabled: Bool { defaults.bool(forKey: SyncSettingsKeys.enabled) }
    var syncsFiles: Bool { defaults.object(forKey: SyncSettingsKeys.files) as? Bool ?? true }
    var filesOnWiFiOnly: Bool { defaults.object(forKey: SyncSettingsKeys.filesWiFiOnly) as? Bool ?? true }
    var isConfigured: Bool { isEnabled && !serverURL.isEmpty }

    /// Saves the server and account. Another server or account starts the sync over on this device.
    func saveAccount(url: String, user: String, password: String) -> Bool {
        let url = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if url != serverURL || user != self.user { reset() }
        defaults.set(url, forKey: SyncSettingsKeys.url)
        defaults.set(user, forKey: SyncSettingsKeys.user)
        let saved = SyncKeychain.setPassword(password)
        engines = nil
        if isConfigured { requestLibrarySync() }
        return saved
    }

    func setEnabled(_ on: Bool) {
        defaults.set(on, forKey: SyncSettingsKeys.enabled)
        if on { requestLibrarySync() }
    }

    func setSyncsFiles(_ on: Bool) { defaults.set(on, forKey: SyncSettingsKeys.files) }

    func setFilesOnWiFiOnly(_ on: Bool) {
        defaults.set(on, forKey: SyncSettingsKeys.filesWiFiOnly)
        engines = nil
    }

    /// Tries an account before it is saved: nil when it works, else what went wrong.
    func test(url: String, user: String, password: String) async -> String? {
        do {
            let dav = try WebDAVClient(baseURL: url.trimmingCharacters(in: .whitespacesAndNewlines), user: user, password: password,
                                       transport: URLSessionTransport())
            try await dav.ensureCollections(["Bookmania", "sync-v1"])
            _ = try await dav.list(["Bookmania", "sync-v1"])
            return nil
        } catch let e as SyncError {
            return e.message
        } catch {
            return error.localizedDescription
        }
    }

    /// Forgets the last syncs (another server or account): their baselines do not apply to it.
    private func reset() {
        engines?.adapter.reset()
        if engines == nil { makeAdapter().reset() }
        engines = nil
        lastSync = nil
        lastError = nil
        conflicts = []
        fileProblems = []
        for key in [SyncSettingsKeys.lastSync, SyncSettingsKeys.lastError, SyncSettingsKeys.conflicts, SyncSettingsKeys.fileProblems] {
            defaults.removeObject(forKey: key)
        }
    }

    private var deviceId: String {
        if let id = defaults.string(forKey: SyncSettingsKeys.deviceId), !id.isEmpty { return id }
        let id = SyncIds.newDeviceID()
        defaults.set(id, forKey: SyncSettingsKeys.deviceId)
        return id
    }

    private func makeAdapter() -> LibrarySyncAdapter {
        let preferences = env.preferences
        return LibrarySyncAdapter(store: env.library, preferences: preferences, allPreferences: { preferences.all() },
                                  localRoot: AppPaths.local,
                                  directory: AppPaths.support.appendingPathComponent("sync", isDirectory: true))
    }

    private func currentEngines() throws -> Engines {
        let password = SyncKeychain.password() ?? ""
        let key = [serverURL, user, password, filesOnWiFiOnly ? "wifi" : "any"].joined(separator: "\n")
        if let engines, engines.key == key { return engines }
        let info = Bundle.main.infoDictionary
        let device = Sync.DeviceInfo(id: deviceId, name: UIDevice.current.name, platform: "ios",
                                     app: info?["CFBundleShortVersionString"] as? String ?? "?")
        let adapter = makeAdapter()
        let dav = try WebDAVClient(baseURL: serverURL, user: user, password: password, transport: URLSessionTransport())
        let fileDav = try WebDAVClient(baseURL: serverURL, user: user, password: password,
                                       transport: URLSessionTransport(session: URLSessionTransport.makeSession(expensive: !filesOnWiFiOnly)))
        let made = Engines(key: key, library: SyncEngine(dav: dav, device: device, adapter: adapter),
                           files: SyncEngine(dav: fileDav, device: device, adapter: adapter), adapter: adapter)
        engines = made
        return made
    }

    // MARK: Running

    /// Runs `op` after the syncs before it, off the main thread, and records its outcome.
    private func run<T: Sendable>(applying: Bool = true, _ op: @escaping @Sendable (Engines) async throws -> T) async -> T? {
        guard isConfigured else { return nil }
        let engines: Engines
        do {
            engines = try currentEngines()
        } catch {
            record(error)
            return nil
        }
        let previous = chain
        running += 1
        isSyncing = true
        if applying { applyingUntil = .distantFuture }
        let task = Task.detached { () -> Result<T, Error> in
            await previous?.value
            do { return .success(try await op(engines)) } catch { return .failure(error) }
        }
        chain = Task { _ = await task.value }
        let result = await task.value
        running -= 1
        isSyncing = running > 0
        if applying && running == 0 { applyingUntil = Date().addingTimeInterval(3) }
        switch result {
        case let .success(value):
            lastSync = Date()
            lastError = nil
            defaults.set(lastSync!.timeIntervalSince1970, forKey: SyncSettingsKeys.lastSync)
            defaults.removeObject(forKey: SyncSettingsKeys.lastError)
            return value
        case let .failure(error):
            record(error)
            return nil
        }
    }

    private func record(_ error: Error) {
        let message = (error as? SyncError)?.message ?? error.localizedDescription
        lastError = message
        defaults.set(message, forKey: SyncSettingsKeys.lastError)
    }

    // MARK: Triggers

    /// Follows the library and the synced settings; call once when the app starts.
    func start() {
        guard !started else { return }
        started = true
        syncedSettings = currentSyncedSettings()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .libraryChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.localChange() }
        })
        observers.append(center.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = self.currentSyncedSettings()
                guard now != self.syncedSettings else { return }
                self.syncedSettings = now
                self.localChange()
            }
        })
        // After the readers' own observers have saved their positions.
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.appEnteredBackground() } }
        })
        observers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.requestLibrarySync() }
        })
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let expensive = path.isExpensive || path.isConstrained
            Task { @MainActor in self?.onExpensiveNetwork = expensive }
        }
        pathMonitor.start(queue: DispatchQueue(label: "io.github.n09527.bookmania.sync.path"))
        requestLibrarySync()
    }

    private func currentSyncedSettings() -> [String: String] {
        env.preferences.all().filter { LibrarySyncAdapter.settingType($0.key) != nil }
    }

    /// The library or a synced setting changed here: a library sync a little later (changes come in bursts).
    private func localChange() {
        guard Date() > applyingUntil else { return }
        requestLibrarySync(after: Self.debounce)
    }

    func requestLibrarySync(after delay: UInt64 = 0) {
        guard isConfigured else { return }
        scheduledLibrarySync?.cancel()
        scheduledLibrarySync = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
                if Task.isCancelled { return }
            }
            await self?.syncLibrary()
        }
    }

    /// The library, the settings and the progress other devices changed (or changed here outside a reader), then the
    /// book files.
    func syncLibrary(files: Bool = true) async {
        let works = Set(env.library.snapshot.works.filter { $0.value.favorite }.keys.map { SyncIds.localWorkKey($0) })
        let done = await withBackgroundTime {
            await self.run { e in try await e.library.syncLibrary(libraryWorks: works) }
        }
        if done != nil, files { await syncFiles() }
    }

    /// The book files of the local source works in the library.
    func syncFiles() async {
        guard isConfigured, syncsFiles, !(filesOnWiFiOnly && onExpensiveNetwork) else { return }
        let folders = Set(env.library.snapshot.works.filter { $0.value.favorite }.keys)
        let result = await withBackgroundTime {
            await self.run(applying: false) { e in try await e.files.syncFiles(e.adapter, libraryWorks: folders) }
        }
        guard let result else { return }
        conflicts = result.conflicts.map { "\($0.work)/\($0.path)" }.sorted()
        fileProblems = (result.failed.map { "\($0.0.work)/\($0.0.path): \($0.1)" } +
            result.rejected.map { "\($0.work)/\($0.path): name not allowed" }).sorted()
        defaults.set(conflicts, forKey: SyncSettingsKeys.conflicts)
        defaults.set(fileProblems, forKey: SyncSettingsKeys.fileProblems)
        if !result.downloaded.isEmpty { NotificationCenter.default.post(name: .syncDownloadedFiles, object: nil) }
    }

    // MARK: Readers

    static func work(of chapter: LocalChapter) -> String {
        SyncIds.localWorkKey(String(chapter.id.split(separator: "/", maxSplits: 1).first ?? ""))
    }

    /// Before a reader opens `chapter`: takes the other devices' progress of its work, waiting at most 5 seconds. On
    /// a timeout the sync goes on and the reader opens with what this device has.
    func pullBeforeReading(_ chapter: LocalChapter) async {
        guard isConfigured else { return }
        let work = Self.work(of: chapter)
        readingWork = work
        let task = Task { _ = await self.run { e in try await e.library.syncWork(work, push: false) } }
        await waitAtMost(Self.pullTimeout, for: task)
    }

    /// After a reader leaves the work of `chapter`: sends its progress (with time to finish in the background).
    func pushAfterReading(_ chapter: LocalChapter) {
        readingWork = nil
        push(Self.work(of: chapter))
    }

    /// The app goes to the background with a reader open: its progress is sent now.
    func appEnteredBackground() {
        if let readingWork { push(readingWork) }
    }

    private func push(_ work: String) {
        guard isConfigured else { return }
        Task {
            _ = await withBackgroundTime {
                await self.run { e in try await e.library.syncWork(work, push: true) }
            }
        }
    }

    /// Runs `body` with time to finish if the app goes to the background meanwhile.
    private func withBackgroundTime<T>(_ body: () async -> T) async -> T {
        let app = UIApplication.shared
        let token = BackgroundToken()
        token.id = app.beginBackgroundTask(withName: "Bookmania sync") {
            app.endBackgroundTask(token.id)
            token.id = .invalid
        }
        let result = await body()
        if token.id != .invalid { app.endBackgroundTask(token.id) }
        return result
    }

    private final class BackgroundToken {
        var id = UIBackgroundTaskIdentifier.invalid
    }

    private final class Once {
        var done = false
    }

    /// Returns when `task` finishes or after `nanoseconds`, whichever comes first; the task goes on either way.
    private func waitAtMost(_ nanoseconds: UInt64, for task: Task<Void, Never>) async {
        let once = Once()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            Task { @MainActor in
                await task.value
                if !once.done {
                    once.done = true
                    continuation.resume()
                }
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: nanoseconds)
                if !once.done {
                    once.done = true
                    continuation.resume()
                }
            }
        }
    }
}
