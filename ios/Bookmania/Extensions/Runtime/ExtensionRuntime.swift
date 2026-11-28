import Foundation

/// The embedded Java VM running the extension host of the Oneechan runtime (docs/extensions-and-sync/design.md, E-1),
/// through the native shim (bm_jvm.c). The VM, its java.home and the host's jar are in the app only when it is built
/// with the package of .github/workflows/ios-jvm.yml; `isIncluded` says whether this build has them.
///
/// The VM starts once and stays until the app ends. Requests are JSON-RPC (`{"id", "method", "params"}`); each
/// reply comes back through the shim's `complete` callback.
final class ExtensionRuntime: @unchecked Sendable {
    static let shared = ExtensionRuntime()

    enum RuntimeError: LocalizedError {
        case notIncluded
        case startFailed(String)
        case notRunning
        case badReply

        var errorDescription: String? {
            switch self {
            case .notIncluded: return NSLocalizedString("extension_runtime_not_included", comment: "")
            case let .startFailed(message): return message
            case .notRunning: return NSLocalizedString("extension_runtime_not_running", comment: "")
            case .badReply: return NSLocalizedString("extension_runtime_bad_reply", comment: "")
            }
        }
    }

    /// Where the runtime is in the app bundle (copied there by the build, see project.yml) and the host's folders.
    struct Paths {
        let javaHome: URL
        let hostJar: URL
        let options: URL
        let data: URL
        let cache: URL
        let temporary: URL

        static var app: Paths {
            let bundle = Bundle.main.bundleURL.appendingPathComponent("ExtensionRuntime", isDirectory: true)
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            return Paths(
                javaHome: bundle.appendingPathComponent("jre", isDirectory: true),
                hostJar: bundle.appendingPathComponent("host/oneechan-host.jar"),
                options: bundle.appendingPathComponent("jre/lib/oneechan-jvm.options"),
                data: support.appendingPathComponent("Bookmania/extensions", isDirectory: true),
                cache: caches.appendingPathComponent("extensions", isDirectory: true),
                temporary: FileManager.default.temporaryDirectory.appendingPathComponent("extensions", isDirectory: true)
            )
        }
    }

    private let lock = NSLock()
    private var started = false
    private var nextRequest: Int64 = 1
    private var waiting: [Int64: CheckedContinuation<Data, Error>] = [:]
    /// Events of the host (JSON), for whoever listens (the extension screens, later stages).
    var onEvent: ((Data) -> Void)?

    /// Whether this build of the app contains the VM, and its files are in the bundle.
    var isIncluded: Bool {
        let paths = Paths.app
        return bm_jvm_included() != 0 && FileManager.default.fileExists(atPath: paths.hostJar.path)
            && FileManager.default.fileExists(atPath: paths.options.path)
    }

    var isRunning: Bool { lock.withLock { started } }

    /// The options of the VM: the common ones, then the runtime's own list (jre/lib/oneechan-jvm.options, one per line,
    /// `#` comments) with ${dataDir}, ${cacheDir}, ${tmpDir} and ${javaHome} filled in.
    static func options(_ paths: Paths, maxHeapMB: Int = 512) throws -> [String] {
        var options = [
            "-Djava.class.path=\(paths.hostJar.path)",
            "-Djava.io.tmpdir=\(paths.temporary.path)",
            "-Duser.home=\(paths.data.path)",
            "-Xmx\(maxHeapMB)m",
            "-Djava.awt.headless=true",
            "-Dfile.encoding=UTF-8",
            "-Djava.home=\(paths.javaHome.path)",
        ]
        let text = try String(contentsOf: paths.options, encoding: .utf8)
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            options.append(line
                .replacingOccurrences(of: "${dataDir}", with: paths.data.path)
                .replacingOccurrences(of: "${cacheDir}", with: paths.cache.path)
                .replacingOccurrences(of: "${tmpDir}", with: paths.temporary.path)
                .replacingOccurrences(of: "${javaHome}", with: paths.javaHome.path))
        }
        return options
    }

    /// Starts the VM and the host (once; later calls return at once). Runs on a background thread: starting takes a
    /// while in an interpreter.
    func start() async throws {
        guard isIncluded else { throw RuntimeError.notIncluded }
        if isRunning { return }
        let paths = Paths.app
        for folder in [paths.data, paths.cache, paths.temporary] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let options = try Self.options(paths)
        let config = try JSONSerialization.data(withJSONObject: [
            "dataDir": paths.data.path, "cacheDir": paths.cache.path, "tmpDir": paths.temporary.path,
        ])
        let context = Unmanaged.passUnretained(self).toOpaque()
        let callbacks = bm_jvm_callbacks(
            context: context,
            complete: { context, requestId, bytes, length in
                guard let context, let bytes else { return }
                Unmanaged<ExtensionRuntime>.fromOpaque(context).takeUnretainedValue()
                    .completed(requestId, Data(bytes: bytes, count: length))
            },
            emit: { context, bytes, length in
                guard let context, let bytes else { return }
                Unmanaged<ExtensionRuntime>.fromOpaque(context).takeUnretainedValue().onEvent?(Data(bytes: bytes, count: length))
            },
            fetch: { context, id, meta, metaLength, _, _, _ in
                guard let context, let meta else { return }
                Unmanaged<ExtensionRuntime>.fromOpaque(context).takeUnretainedValue()
                    .fetchRequested(id, Data(bytes: meta, count: metaLength))
            },
            fetch_cancel: { _, _ in }
        )
        try await Task.detached(priority: .userInitiated) {
            var cOptions = options.map { strdup($0) }
            defer { cOptions.forEach { free($0) } }
            let errorCapacity = 1024
            var error = [CChar](repeating: 0, count: errorCapacity)
            let result: Int32 = cOptions.withUnsafeMutableBufferPointer { buffer in
                buffer.baseAddress!.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: buffer.count) { pointer in
                    config.withUnsafeBytes { raw in
                        bm_jvm_start(pointer, Int32(buffer.count), raw.bindMemory(to: UInt8.self).baseAddress, raw.count,
                                     callbacks, &error, errorCapacity)
                    }
                }
            }
            if result != 0 {
                throw RuntimeError.startFailed(error.withUnsafeBufferPointer { String(cString: $0.baseAddress!) })
            }
        }.value
        lock.withLock { started = true }
    }

    /// Sends a request to the host and returns its reply (the whole JSON-RPC response).
    func call(_ method: String, params: [String: Any] = [:]) async throws -> Data {
        guard isRunning else { throw RuntimeError.notRunning }
        let id: Int64 = lock.withLock {
            let id = nextRequest
            nextRequest += 1
            return id
        }
        let request = try JSONSerialization.data(withJSONObject: ["id": String(id), "method": method, "params": params])
        return try await withCheckedThrowingContinuation { continuation in
            lock.withLock { waiting[id] = continuation }
            let queued = request.withUnsafeBytes { raw in
                bm_jvm_call(id, raw.bindMemory(to: UInt8.self).baseAddress, raw.count)
            }
            if queued != 0 {
                let pending = lock.withLock { waiting.removeValue(forKey: id) }
                pending?.resume(throwing: RuntimeError.notRunning)
            }
        }
    }

    private func completed(_ requestId: Int64, _ reply: Data) {
        let continuation = lock.withLock { waiting.removeValue(forKey: requestId) }
        continuation?.resume(returning: reply)
    }

    /// An extension's HTTP request. The app's network stack comes in a later stage (E-2): until then every request is
    /// answered with an error, so that nothing waits for it.
    private func fetchRequested(_ id: Int64, _ meta: Data) {
        let requestId = (try? JSONSerialization.jsonObject(with: meta) as? [String: Any])?["id"] as? String ?? String(id)
        let answer: [String: Any] = [
            "id": requestId, "code": 0, "message": "", "headers": [],
            "error": ["code": "UNSUPPORTED", "message": "Extension network requests are not available yet.", "retryable": false],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: answer) else { return }
        _ = data.withUnsafeBytes { raw in
            bm_jvm_fetch_result(id, raw.bindMemory(to: UInt8.self).baseAddress, raw.count, nil, 0, 0)
        }
    }
}
