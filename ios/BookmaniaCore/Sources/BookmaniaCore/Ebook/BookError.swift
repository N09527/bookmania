import Foundation

/// Problems with a book file that the reader explains to the user (Kotlin: BookException and its subclasses).
public enum BookError: Error, Equatable, Sendable {
    /// The book uses DRM. It is never decrypted; the reader only explains that it cannot be opened.
    case drmProtected(scheme: String)
    /// The file is damaged or is not what its extension says.
    case corrupt(String)
    /// Not even the container can be read: neither a ZIP (EPUB) nor a MOBI file, or a ZIP whose directory is
    /// missing because the file was cut short. Another reader cannot open such a file either. Also "corrupt".
    case unreadable(String)
    /// A known format that this reader does not handle (for example KFX).
    case unsupported(String)

    /// True for `.corrupt` and `.unreadable` (Kotlin: `is CorruptBookException`).
    public var isCorrupt: Bool {
        switch self {
        case .corrupt, .unreadable: return true
        default: return false
        }
    }

    public var isUnreadable: Bool {
        if case .unreadable = self { return true }
        return false
    }

    public var drmScheme: String? {
        if case let .drmProtected(scheme) = self { return scheme }
        return nil
    }
}
