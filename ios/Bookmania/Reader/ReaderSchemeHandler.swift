import BookmaniaCore
import Foundation
import WebKit

/// Serves `bookmania://reader/` to the reader's web view (EbookRequestHandler.kt on Android): the shell from the app
/// bundle, the open book's resources (documents sanitized, with a strict CSP), and imported fonts by id. Anything
/// else is refused. Book resources are read on a background queue; the answer goes back to WebKit on the main
/// thread, and never to a task WebKit has already stopped.
@MainActor
final class ReaderSchemeHandler: NSObject, WKURLSchemeHandler {
    var publication: Publication?
    /// Looks up an imported font file by its id.
    var fontFile: ((String) -> URL?)?

    private var stopped = Set<ObjectIdentifier>()
    private let queue = DispatchQueue(label: "bookmania.reader.resources", qos: .userInitiated, attributes: .concurrent)

    struct Loaded {
        var status: Int
        var type: String
        var data: Data
        var headers: [String: String] = [:]
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let key = ObjectIdentifier(urlSchemeTask as AnyObject)
        stopped.remove(key)
        guard let url = urlSchemeTask.request.url, let route = ReaderURLs.route(url) else {
            respond(urlSchemeTask, key, Loaded(status: 403, type: "text/plain", data: Data()))
            return
        }
        let publication = self.publication
        let fontFile = self.fontFile
        queue.async { [weak self] in
            let loaded = ReaderSchemeHandler.load(route, publication: publication, fontFile: fontFile)
            Task { @MainActor in
                self?.respond(urlSchemeTask, key, loaded)
            }
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        stopped.insert(ObjectIdentifier(urlSchemeTask as AnyObject))
    }

    private func respond(_ task: WKURLSchemeTask, _ key: ObjectIdentifier, _ loaded: Loaded) {
        if stopped.contains(key) {
            stopped.remove(key)
            return
        }
        guard let url = task.request.url else { return }
        var fields = loaded.headers
        fields["Content-Type"] = loaded.type
        fields["Content-Length"] = String(loaded.data.count)
        fields["Cache-Control"] = "no-store"
        guard let response = HTTPURLResponse(url: url, statusCode: loaded.status, httpVersion: "HTTP/1.1", headerFields: fields) else { return }
        task.didReceive(response)
        task.didReceive(loaded.data)
        task.didFinish()
    }

    nonisolated static func load(_ route: ReaderURLs.Route, publication: Publication?, fontFile: ((String) -> URL?)?) -> Loaded {
        switch route {
        case let .shell(name):
            let base = (name as NSString).deletingPathExtension
            let ext = (name as NSString).pathExtension
            guard let url = Bundle.main.url(forResource: base, withExtension: ext, subdirectory: "ebook"),
                  let data = try? Data(contentsOf: url) else {
                return Loaded(status: 404, type: "text/plain", data: Data())
            }
            var headers = [String: String]()
            if name.hasSuffix(".html") { headers["Content-Security-Policy"] = ReaderURLs.shellCSP }
            let type = (mediaTypeFromName(name) ?? "application/octet-stream") + "; charset=utf-8"
            return Loaded(status: 200, type: type, data: data, headers: headers)

        case let .book(path):
            guard let publication else { return Loaded(status: 404, type: "text/plain", data: Data()) }
            do {
                let type = publication.mediaType(path) ?? mediaTypeFromName(path) ?? "application/octet-stream"
                guard let bytes = try publication.open(path) else { return Loaded(status: 404, type: "text/plain", data: Data()) }
                if type == "application/xhtml+xml" || type == "text/html" {
                    let result = XhtmlSanitizer.sanitize(bytes, isHtml: type == "text/html")
                    return Loaded(status: 200, type: result.mediaType + "; charset=utf-8", data: Data(result.text.utf8),
                                  headers: ["Content-Security-Policy": ReaderURLs.bookCSP])
                }
                let textual = type.hasPrefix("text/") || type == "image/svg+xml"
                return Loaded(status: 200, type: textual ? type + "; charset=utf-8" : type, data: Data(bytes))
            } catch {
                return Loaded(status: 500, type: "text/plain", data: Data())
            }

        case let .font(id):
            guard let file = fontFile?(id), let data = try? Data(contentsOf: file) else {
                return Loaded(status: 404, type: "text/plain", data: Data())
            }
            return Loaded(status: 200, type: file.pathExtension.lowercased() == "otf" ? "font/otf" : "font/ttf", data: data)
        }
    }
}
