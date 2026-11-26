import Foundation

/// A font the user imported (TTF / OTF).
public struct ImportedFont: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let fileExtension: String
    public let vertical: Bool

    enum CodingKeys: String, CodingKey {
        case id, name, vertical
        case fileExtension = "extension"
    }
}

/// Imported fonts live in the app's private files (`<directory>/<id>.<ttf|otf>`); the list is app state, stored
/// as on Android under `__APP_STATE_ebook_fonts` (not in backups, like the files themselves).
public final class FontStore: @unchecked Sendable {
    private let directory: URL
    private let store: PreferenceStore
    private static let listKey = "__APP_STATE_ebook_fonts"
    private static let maxBytes = 64 << 20

    public init(directory: URL, store: PreferenceStore) {
        self.directory = directory
        self.store = store
    }

    public struct Pending: Sendable {
        public let bytes: [UInt8]
        public let info: FontInfo
        public let name: String
    }

    public func list() -> [ImportedFont] {
        guard let text = store.string(FontStore.listKey), !text.isEmpty,
              let fonts = try? JSONDecoder().decode([ImportedFont].self, from: Data(text.utf8)) else { return [] }
        return fonts.filter { FontStore.isId($0.id) && fileOf($0).map { FileManager.default.fileExists(atPath: $0.path) } == true }
    }

    public func find(_ id: String) -> ImportedFont? { list().first { $0.id == id } }

    /// The font file for `id`, or nil; ids are validated so no other file can be reached.
    public func file(_ id: String) -> URL? { find(id).flatMap(fileOf) }

    private func fileOf(_ font: ImportedFont) -> URL? {
        guard FontStore.isId(font.id), ["ttf", "otf"].contains(font.fileExtension) else { return nil }
        return directory.appendingPathComponent("\(font.id).\(font.fileExtension)")
    }

    /// Reads and checks a font chosen by the user; nothing is saved yet.
    public func read(_ url: URL) throws -> Pending {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        if size > FontStore.maxBytes { throw InvalidFontError(message: "Font larger than \(FontStore.maxBytes >> 20) MB") }
        guard let data = try? Data(contentsOf: url) else { throw InvalidFontError(message: "Cannot read the file") }
        if data.count > FontStore.maxBytes { throw InvalidFontError(message: "Font larger than \(FontStore.maxBytes >> 20) MB") }
        let bytes = [UInt8](data)
        let info = try FontInspector.inspect(bytes)
        let fallback = url.deletingPathExtension().lastPathComponent
        return Pending(bytes: bytes, info: info, name: info.familyName ?? (fallback.isEmpty ? "Font" : fallback))
    }

    @discardableResult
    public func save(_ pending: Pending) throws -> ImportedFont {
        let font = ImportedFont(
            id: UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
            name: pending.name,
            fileExtension: pending.info.format.fileExtension,
            vertical: pending.info.supportsVertical
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let target = fileOf(font) else { throw InvalidFontError(message: "Bad font id") }
        try Data(pending.bytes).write(to: target, options: .atomic)
        write(list() + [font])
        return font
    }

    public func delete(_ id: String) {
        guard let font = find(id) else { return }
        if let file = fileOf(font) { try? FileManager.default.removeItem(at: file) }
        write(list().filter { $0.id != id })
    }

    private func write(_ fonts: [ImportedFont]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(fonts), let text = String(data: data, encoding: .utf8) {
            store.set(FontStore.listKey, text)
        }
    }

    static func isId(_ id: String) -> Bool {
        id.count == 32 && id.allSatisfy { ("0" ... "9").contains($0) || ("a" ... "f").contains($0) }
    }
}
