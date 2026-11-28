import Foundation
@testable import BookmaniaCore

/// A WebDAV server in memory (as Android's InMemoryWebDav): MKCOL fails with 405 on an existing resource and 409
/// without a parent, PUT needs the parent collection, PROPFIND lists one level. Options make it answer like
/// different servers do.
final class InMemoryWebDAV: HTTPTransport, @unchecked Sendable {
    let base: String
    private let user: String
    private let password: String
    private let prefix: String
    private let fullURLHrefs: Bool
    private let encodeHrefs: Bool
    private let lock = NSLock()

    /// Decoded paths below `base`, without a final slash; "" is the base itself.
    var collections: Set<String> = [""]
    var files: [String: Data] = [:]
    var requests: [String] = []
    var offline = false

    init(base: String = "https://dav.example/remote/", user: String = "reader", password: String = "secret", prefix: String = "d", fullURLHrefs: Bool = false, encodeHrefs: Bool = true) {
        self.base = base
        self.user = user
        self.password = password
        self.prefix = prefix
        self.fullURLHrefs = fullURLHrefs
        self.encodeHrefs = encodeHrefs
    }

    func text(_ path: String) -> String? { files[path].map { String(decoding: $0, as: UTF8.self) } }

    func addCollections(_ paths: [String]) { paths.forEach { collections.insert($0) } }

    private func body(_ b: HTTPBody?) -> Data {
        switch b {
        case let .data(d, _): return d
        case let .file(url, _): return (try? Data(contentsOf: url)) ?? Data()
        case nil: return Data()
        }
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        lock.lock()
        defer { lock.unlock() }
        if offline { throw SyncError(.network, "offline") }
        precondition(request.url.hasPrefix(base), "outside the base: \(request.url)")
        var path = WebDAVClient.decodePath(String(request.url.dropFirst(base.count)))
        while path.hasSuffix("/") { path.removeLast() }
        requests.append("\(request.method) \(path)")
        let expected = "Basic " + Data("\(user):\(password)".utf8).base64EncodedString()
        if request.headers["Authorization"] != expected { return HTTPResponse(status: 401) }
        let parent = path.contains("/") ? String(path[..<path.lastIndex(of: "/")!]) : ""
        switch request.method {
        case "MKCOL":
            if collections.contains(path) || files[path] != nil { return HTTPResponse(status: 405) }
            if !collections.contains(parent) { return HTTPResponse(status: 409) }
            collections.insert(path)
            return HTTPResponse(status: 201)
        case "PUT":
            if collections.contains(path) { return HTTPResponse(status: 405) }
            if !collections.contains(parent) { return HTTPResponse(status: 409) }
            let existed = files[path] != nil
            files[path] = body(request.body)
            return HTTPResponse(status: existed ? 204 : 201)
        case "GET":
            guard let data = files[path] else { return HTTPResponse(status: 404) }
            return HTTPResponse(status: 200, body: data)
        case "PROPFIND":
            if collections.contains(path) { return multistatus(path, children(path)) }
            if files[path] != nil { return multistatus(path, [], selfIsFile: true) }
            return HTTPResponse(status: 404)
        default:
            return HTTPResponse(status: 405)
        }
    }

    func download(_ request: HTTPRequest) async throws -> (HTTPResponse, URL?) {
        let r = try await send(request)
        guard (200 ..< 300).contains(r.status) else { return (r, nil) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dav-\(UUID().uuidString)")
        try r.body.write(to: url)
        return (HTTPResponse(status: r.status), url)
    }

    private func children(_ path: String) -> [(String, Bool)] {
        let start = path.isEmpty ? "" : path + "/"
        let dirs = collections.filter { $0.hasPrefix(start) && $0 != path && !$0.dropFirst(start.count).contains("/") }.sorted().map { ($0, true) }
        let fs = files.keys.filter { $0.hasPrefix(start) && !$0.dropFirst(start.count).contains("/") }.sorted().map { ($0, false) }
        return dirs + fs
    }

    private func href(_ path: String, collection: Bool) -> String {
        let afterScheme = base.components(separatedBy: "://")[1]
        let host = String(afterScheme.prefix { $0 != "/" })
        let basePath = String(afterScheme.dropFirst(host.count))
        let encoded = encodeHrefs ? path.split(separator: "/", omittingEmptySubsequences: false).map { WebDAVClient.encodeSegment(String($0)) }.joined(separator: "/") : path
        let p = basePath + encoded + (collection && !path.isEmpty ? "/" : "")
        return fullURLHrefs ? base.components(separatedBy: "://")[0] + "://" + host + p : p
    }

    private func multistatus(_ path: String, _ children: [(String, Bool)], selfIsFile: Bool = false) -> HTTPResponse {
        let p = prefix.isEmpty ? "" : prefix + ":"
        let ns = prefix.isEmpty ? "xmlns=\"DAV:\"" : "xmlns:\(prefix)=\"DAV:\""
        var s = "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<\(p)multistatus \(ns)>"
        func entry(_ path: String, _ collection: Bool) {
            s += "<\(p)response><\(p)href>\(href(path, collection: collection))</\(p)href><\(p)propstat><\(p)prop>"
            if collection {
                s += "<\(p)resourcetype><\(p)collection/></\(p)resourcetype>"
            } else {
                s += "<\(p)resourcetype/><\(p)getcontentlength>\(files[path]?.count ?? 0)</\(p)getcontentlength>"
            }
            s += "</\(p)prop><\(p)status>HTTP/1.1 200 OK</\(p)status></\(p)propstat></\(p)response>"
        }
        entry(path, !selfIsFile)
        for (child, collection) in children { entry(child, collection) }
        s += "</\(p)multistatus>"
        return HTTPResponse(status: 207, headers: ["content-type": "application/xml"], body: Data(s.utf8))
    }
}

/// A device's data in memory, as an adapter would read and write a real library (as Android's FakeDevice).
final class FakeDevice: SyncAdapter, SyncFileAccess {
    let id: String
    var works: [String: Sync.WorkValue] = [:]
    var categories: [String: Sync.CategoryValue] = [:]
    var settings: [String: Sync.SettingValue] = [:]
    /// Work → chapter → value; a chapter missing here is a book file this device does not have.
    var chapters: [String: [String: Sync.ChapterValue]] = [:]
    var canCreate: (String) -> Bool = { SyncIds.localFolder($0) != nil }
    var baseline = Sync.Baseline()
    var workBaselines: [String: Sync.WorkBaseline] = [:]
    var files: [String: Data] = [:]
    private let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("fake-device-\(UUID().uuidString)")

    init(_ id: String) { self.id = id }

    func chapter(_ work: String, _ key: String) -> Sync.ChapterValue? { chapters[work]?[key] }
    func setChapter(_ work: String, _ key: String, _ value: Sync.ChapterValue) { chapters[work, default: [:]][key] = value }

    func librarySnapshot() -> Sync.LibrarySnapshot { Sync.LibrarySnapshot(works: works, categories: categories, settings: settings) }

    func applyLibrary(_ changes: Sync.LibraryChanges) -> Set<String> {
        var ids = Set<String>()
        for (k, v) in changes.works where works[k] != nil || canCreate(k) {
            works[k] = v
            ids.insert("w:\(k)")
        }
        for (k, v) in changes.categories {
            categories[k] = v
            ids.insert("c:\(k)")
        }
        for k in changes.deletedCategories { categories[k] = nil }
        for (k, v) in changes.settings {
            settings[k] = v.value == nil ? nil : v
            ids.insert("s:\(k)")
        }
        return ids
    }

    func progressSnapshot(_ work: String) -> Sync.ProgressSnapshot { Sync.ProgressSnapshot(chapters: chapters[work] ?? [:]) }

    func applyProgress(_ work: String, _ changes: Sync.ProgressChanges) -> Set<String> {
        var ids = Set<String>()
        guard var map = chapters[work] else { return ids }
        for (key, c) in changes.chapters {
            guard var v = map[key] else { continue }
            if let p = c.progress {
                v.read = p.read
                v.page = p.page
                v.left = p.left
                ids.insert("\(key)|progress")
            }
            if let b = c.bookmark {
                v.bookmark = b
                ids.insert("\(key)|bookmark")
            }
            if let p = c.position {
                v.locator = p.locator
                ids.insert("\(key)|position")
            }
            if let h = c.history {
                v.lastRead = h.lastRead
                v.duration = h.duration
            }
            map[key] = v
        }
        chapters[work] = map
        return ids
    }

    func loadBaseline() -> Sync.Baseline { baseline }
    func saveBaseline(_ baseline: Sync.Baseline) { self.baseline = baseline }
    func loadWorkBaseline(_ work: String) -> Sync.WorkBaseline { workBaselines[work] ?? Sync.WorkBaseline() }
    func saveWorkBaseline(_ work: String, _ baseline: Sync.WorkBaseline) { workBaselines[work] = baseline }

    func list(works: Set<String>) -> [Sync.FileItem] {
        files.map { k, v in
            let work = String(k.prefix { $0 != "/" })
            return Sync.FileItem(work: work, path: String(k.dropFirst(work.count + 1)), size: Int64(v.count))
        }
        .filter { works.contains($0.work) }
    }

    func fileURL(work: String, path: String) -> URL {
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let url = scratch.appendingPathComponent(UUID().uuidString)
        try? files["\(work)/\(path)"]?.write(to: url)
        return url
    }

    func save(work: String, path: String, from temporary: URL) throws {
        files["\(work)/\(path)"] = try Data(contentsOf: temporary)
        try FileManager.default.removeItem(at: temporary)
    }
}
