import Foundation
#if canImport(Glibc)
import Glibc
private func sysOpen(_ path: UnsafePointer<CChar>) -> Int32 { Glibc.open(path, O_RDONLY) }
private func sysClose(_ fd: Int32) { _ = Glibc.close(fd) }
#elseif canImport(Darwin)
import Darwin
private func sysOpen(_ path: UnsafePointer<CChar>) -> Int32 { Darwin.open(path, O_RDONLY) }
private func sysClose(_ fd: Int32) { _ = Darwin.close(fd) }
#endif

/// Random access to the bytes of a book file. Positional reads must be safe to call from several threads at
/// once: the reader's web view asks for resources on background threads.
public protocol RandomAccessSource: AnyObject {
    var size: Int64 { get }
    /// Exactly `count` bytes starting at `position`.
    func read(at position: Int64, count: Int) throws -> [UInt8]
    func close()
}

func checkRange(_ position: Int64, _ count: Int, _ size: Int64) throws {
    if position < 0 || count < 0 || position > size - Int64(count) {
        throw BookError.corrupt("Read of \(count) bytes at \(position) is outside a file of \(size) bytes")
    }
}

/// A file opened read-only; `pread` does not move a shared file position, so reads can run concurrently.
public final class FileSource: RandomAccessSource {
    private let fd: Int32
    public let size: Int64
    private let lock = NSLock()
    private var closed = false

    public init(path: String) throws {
        let fd = path.withCString { sysOpen($0) }
        guard fd >= 0 else { throw BookError.unreadable("Cannot open the file") }
        var st = stat()
        guard fstat(fd, &st) == 0 else {
            sysClose(fd)
            throw BookError.unreadable("Cannot read the file size")
        }
        self.fd = fd
        self.size = Int64(st.st_size)
    }

    public convenience init(url: URL) throws { try self.init(path: url.path) }

    public func read(at position: Int64, count: Int) throws -> [UInt8] {
        try checkRange(position, count, size)
        var out = [UInt8](repeating: 0, count: count)
        var done = 0
        try out.withUnsafeMutableBytes { buf in
            while done < count {
                let n = pread(fd, buf.baseAddress! + done, count - done, off_t(position + Int64(done)))
                if n < 0 { throw BookError.corrupt("Read error") }
                if n == 0 { throw BookError.corrupt("Unexpected end of file at \(position + Int64(done))") }
                done += n
            }
        }
        return out
    }

    public func close() {
        lock.lock()
        defer { lock.unlock() }
        if !closed {
            closed = true
            sysClose(fd)
        }
    }

    deinit { close() }
}

public final class DataSource: RandomAccessSource {
    private let data: [UInt8]
    public var size: Int64 { Int64(data.count) }

    public init(_ data: [UInt8]) { self.data = data }
    public convenience init(_ data: Data) { self.init([UInt8](data)) }

    public func read(at position: Int64, count: Int) throws -> [UInt8] {
        try checkRange(position, count, size)
        let start = Int(position)
        return Array(data[start ..< start + count])
    }

    public func close() {}
}
