import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct SyncError: Error, Equatable, Sendable, CustomStringConvertible {
    public enum Kind: String, Sendable {
        /// The address is not https or not a URL.
        case config
        /// 401 or 403: the account or its permissions.
        case auth
        /// Another HTTP status.
        case http
        /// No connection, a timeout, a TLS error.
        case network
        /// A response that is not what WebDAV or the sync format says.
        case format
    }

    public let kind: Kind
    public let message: String
    public var status = 0

    public init(_ kind: Kind, _ message: String, status: Int = 0) {
        self.kind = kind
        self.message = message
        self.status = status
    }

    public var description: String { message }
}

public enum HTTPBody: Sendable {
    case data(Data, contentType: String)
    /// A file sent as it is read, not loaded into memory.
    case file(URL, contentType: String)
}

public struct HTTPRequest: Sendable {
    public var method: String
    public var url: String
    public var headers: [String: String]
    public var body: HTTPBody?

    public init(method: String, url: String, headers: [String: String] = [:], body: HTTPBody? = nil) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }
}

/// `headers` have lower-case names.
public struct HTTPResponse: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }
}

/// How requests are sent: URLSession in the app, a fake server in tests.
public protocol HTTPTransport: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
    /// The body of a 2xx response saved to a temporary file (the caller moves or deletes it); nil for other statuses.
    func download(_ request: HTTPRequest) async throws -> (HTTPResponse, URL?)
}

public final class URLSessionTransport: HTTPTransport, @unchecked Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) { self.session = session }

    private func urlRequest(_ r: HTTPRequest) throws -> URLRequest {
        guard let url = URL(string: r.url) else { throw SyncError(.config, "not a URL: \(r.url)") }
        var request = URLRequest(url: url)
        request.httpMethod = r.method
        request.timeoutInterval = 60
        for (k, v) in r.headers { request.setValue(v, forHTTPHeaderField: k) }
        switch r.body {
        case let .data(data, contentType):
            request.httpBody = data
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        case let .file(_, contentType):
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        case nil:
            break
        }
        return request
    }

    private static func response(_ response: URLResponse?, _ body: Data) throws -> HTTPResponse {
        guard let http = response as? HTTPURLResponse else { throw SyncError(.network, "no HTTP response") }
        var headers: [String: String] = [:]
        for (k, v) in http.allHeaderFields {
            if let k = k as? String { headers[k.lowercased()] = "\(v)" }
        }
        return HTTPResponse(status: http.statusCode, headers: headers, body: body)
    }

    private static func networkError(_ error: Error) -> SyncError {
        SyncError(.network, (error as NSError).localizedDescription)
    }

    public func send(_ r: HTTPRequest) async throws -> HTTPResponse {
        let request = try urlRequest(r)
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<HTTPResponse, Error>) in
            let handler: @Sendable (Data?, URLResponse?, Error?) -> Void = { data, response, error in
                if let error { return c.resume(throwing: Self.networkError(error)) }
                c.resume(with: Result { try Self.response(response, data ?? Data()) })
            }
            let task: URLSessionTask
            if case let .file(url, _) = r.body {
                task = session.uploadTask(with: request, fromFile: url, completionHandler: handler)
            } else {
                task = session.dataTask(with: request, completionHandler: handler)
            }
            task.resume()
        }
    }

    public func download(_ r: HTTPRequest) async throws -> (HTTPResponse, URL?) {
        let request = try urlRequest(r)
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<(HTTPResponse, URL?), Error>) in
            let task = session.downloadTask(with: request) { location, response, error in
                if let error { return c.resume(throwing: Self.networkError(error)) }
                do {
                    let http = try Self.response(response, Data())
                    guard (200 ..< 300).contains(http.status), let location else { return c.resume(returning: (http, nil)) }
                    // The system deletes `location` when this returns: keep the file.
                    let kept = FileManager.default.temporaryDirectory.appendingPathComponent("sync-\(UUID().uuidString)")
                    try FileManager.default.moveItem(at: location, to: kept)
                    c.resume(returning: (http, kept))
                } catch {
                    c.resume(throwing: error)
                }
            }
            task.resume()
        }
    }
}

/// An entry of a collection listing.
public struct DAVEntry: Equatable, Sendable {
    public var name: String
    public var collection: Bool
    public var etag: String?
    public var length: Int64?

    public init(name: String, collection: Bool, etag: String? = nil, length: Int64? = nil) {
        self.name = name
        self.collection = collection
        self.etag = etag
        self.length = length
    }
}

/// The few WebDAV requests the sync needs (sync-format.md section 6), on paths given as unencoded segments below
/// the base address.
public struct WebDAVClient: Sendable {
    public static let dav = "DAV:"

    public let base: String
    private let auth: String
    private let transport: HTTPTransport

    public init(baseURL: String, user: String, password: String, transport: HTTPTransport, requireHTTPS: Bool = true) throws {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let scheme = trimmed.range(of: "://").map { trimmed[..<$0.lowerBound].lowercased() } ?? ""
        if scheme != "https" && (requireHTTPS || scheme != "http") {
            throw SyncError(.config, "the server address must start with https://")
        }
        let host = trimmed.components(separatedBy: "://").dropFirst().first?.split(separator: "/", omittingEmptySubsequences: false).first ?? ""
        if host.isEmpty { throw SyncError(.config, "the server address has no host") }
        base = trimmed.hasSuffix("/") ? trimmed : trimmed + "/"
        auth = "Basic " + Data("\(user):\(password)".utf8).base64EncodedString()
        self.transport = transport
    }

    public func url(_ path: [String], collection: Bool = false) -> String {
        let p = path.map(Self.encodeSegment).joined(separator: "/")
        return base + p + (collection && !p.isEmpty ? "/" : "")
    }

    private func checked(_ method: String, _ path: [String], _ response: HTTPResponse) throws -> HTTPResponse {
        if response.status == 401 || response.status == 403 {
            throw SyncError(.auth, "\(method) \(path.joined(separator: "/")): \(response.status)", status: response.status)
        }
        return response
    }

    private func fail(_ method: String, _ path: [String], _ response: HTTPResponse) -> SyncError {
        SyncError(.http, "\(method) \(path.joined(separator: "/")): \(response.status)", status: response.status)
    }

    private func send(_ method: String, _ path: [String], collection: Bool, headers: [String: String] = [:], body: HTTPBody? = nil) async throws -> HTTPResponse {
        var h = headers
        h["Authorization"] = auth
        let r = try await transport.send(HTTPRequest(method: method, url: url(path, collection: collection), headers: h, body: body))
        return try checked(method, path, r)
    }

    /// Creates the collection; one that exists already is fine (405).
    public func mkcol(_ path: [String]) async throws {
        let r = try await send("MKCOL", path, collection: true)
        if !(200 ..< 300).contains(r.status) && r.status != 405 { throw fail("MKCOL", path, r) }
    }

    /// Creates every collection of `path`, from the top.
    public func ensureCollections(_ path: [String]) async throws {
        for n in 1 ... max(path.count, 1) where n <= path.count { try await mkcol(Array(path[0 ..< n])) }
    }

    /// The entries of a collection (Depth 1), without the collection itself; empty when it does not exist.
    public func list(_ path: [String]) async throws -> [DAVEntry] {
        let body = HTTPBody.data(Data(Self.propfind.utf8), contentType: "application/xml; charset=utf-8")
        let r = try await send("PROPFIND", path, collection: true, headers: ["Depth": "1"], body: body)
        if r.status == 404 { return [] }
        if r.status != 207 { throw fail("PROPFIND", path, r) }
        return try Self.parseMultistatus(String(decoding: r.body, as: UTF8.self), requested: url(path, collection: true))
    }

    /// The file, or nil when it does not exist.
    public func get(_ path: [String]) async throws -> Data? {
        let r = try await send("GET", path, collection: false)
        if r.status == 404 { return nil }
        if !(200 ..< 300).contains(r.status) { throw fail("GET", path, r) }
        return r.body
    }

    /// The file saved to a temporary file, or nil when it does not exist.
    public func download(_ path: [String]) async throws -> URL? {
        let (r0, file) = try await transport.download(HTTPRequest(method: "GET", url: url(path), headers: ["Authorization": auth]))
        let r = try checked("GET", path, r0)
        if r.status == 404 { return nil }
        if !(200 ..< 300).contains(r.status) { throw fail("GET", path, r) }
        guard let file else { throw SyncError(.network, "GET \(path.joined(separator: "/")): no file") }
        return file
    }

    public func put(_ path: [String], _ body: HTTPBody) async throws {
        let r = try await send("PUT", path, collection: false, body: body)
        if !(200 ..< 300).contains(r.status) { throw fail("PUT", path, r) }
    }

    public func putJSON(_ path: [String], _ json: String) async throws {
        try await put(path, .data(Data(json.utf8), contentType: "application/json; charset=utf-8"))
    }

    // MARK: Encoding and listings

    private static let propfind = """
    <?xml version="1.0" encoding="utf-8"?>
    <d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/><d:getetag/><d:getcontentlength/></d:prop></d:propfind>
    """

    private static let unreserved = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~".utf8)
    private static let hex = Array("0123456789ABCDEF".utf8)

    /// RFC 3986 percent-encoding of one path segment (UTF-8; only unreserved characters stay).
    public static func encodeSegment(_ segment: String) -> String {
        var out: [UInt8] = []
        for b in segment.utf8 {
            if unreserved.contains(b) {
                out.append(b)
            } else {
                out.append(UInt8(ascii: "%"))
                out.append(hex[Int(b >> 4)])
                out.append(hex[Int(b & 0xF)])
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// Percent-decoding (UTF-8); a malformed escape is kept as it is.
    public static func decodePath(_ text: String) -> String {
        guard text.contains("%") else { return text }
        let bytes = Array(text.utf8)
        var out: [UInt8] = []
        var i = 0
        func value(_ c: UInt8) -> UInt8? {
            switch c {
            case 48 ... 57: return c - 48
            case 65 ... 70: return c - 55
            case 97 ... 102: return c - 87
            default: return nil
            }
        }
        while i < bytes.count {
            if bytes[i] == UInt8(ascii: "%"), i + 2 < bytes.count, let h = value(bytes[i + 1]), let l = value(bytes[i + 2]) {
                out.append(h << 4 | l)
                i += 3
            } else {
                out.append(bytes[i])
                i += 1
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// The path part of an href (a full URL or an absolute path), decoded, without a final slash.
    private static func hrefPath(_ href: String) -> String {
        var h = href.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = h.range(of: "://") {
            let rest = h[r.upperBound...]
            h = rest.firstIndex(of: "/").map { String(rest[$0...]) } ?? "/"
        }
        if let q = h.firstIndex(of: "?") { h = String(h[..<q]) }
        var p = decodePath(h)
        while p.hasSuffix("/") { p.removeLast() }
        return p
    }

    /// The entries of a 207 response to PROPFIND `requested`, without the requested collection itself.
    public static func parseMultistatus(_ xml: String, requested: String) throws -> [DAVEntry] {
        let root: XMLNode
        do {
            root = try MiniXML.parse(xml)
        } catch let e as XMLFormatError {
            throw SyncError(.format, "PROPFIND: \(e.message)")
        }
        guard root.namespace == dav, root.name == "multistatus" else { throw SyncError(.format, "PROPFIND: not a multistatus") }
        let me = hrefPath(requested)
        var entries: [DAVEntry] = []
        for response in root.all(dav, "response") {
            guard let href = response.child(dav, "href")?.text else { continue }
            let path = hrefPath(href)
            if path == me || path.isEmpty { continue }
            let name = path.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? path
            var entry = DAVEntry(name: name, collection: false)
            for propstat in response.all(dav, "propstat") {
                guard let status = propstat.child(dav, "status")?.text, status.contains(" 200"),
                      let prop = propstat.child(dav, "prop") else { continue }
                if prop.child(dav, "resourcetype")?.child(dav, "collection") != nil { entry.collection = true }
                if let etag = prop.child(dav, "getetag")?.text.trimmingCharacters(in: .whitespacesAndNewlines), !etag.isEmpty { entry.etag = etag }
                if let length = prop.child(dav, "getcontentlength")?.text.trimmingCharacters(in: .whitespacesAndNewlines), let n = Int64(length) { entry.length = n }
            }
            entries.append(entry)
        }
        return entries
    }
}
