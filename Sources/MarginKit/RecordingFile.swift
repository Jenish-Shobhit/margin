import Foundation

/// A screen recording's temp file (spec §14.4), held open from when the writer creates it until it's in place. The
/// writer writes on whatever happens to its folder meanwhile (renamed, moved, put in the Trash, deleted), so the file is
/// found by this descriptor rather than by its old path, and while it's open its contents can still be copied out after
/// it was deleted.
public final class RecordingFile: Sendable {
    private let fd: Int32

    /// Opens the file at `url` for reading; nil if it can't be.
    public init?(_ url: URL) {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        self.fd = fd
    }

    deinit { close(fd) }

    /// Where the file is now, or nil once it's been deleted (no name left: its data lasts while it's open).
    public var currentURL: URL? {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_nlink > 0 else { return nil }
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &path) == 0 else { return nil }
        return URL(fileURLWithPath: path.withUnsafeBufferPointer { String(cString: $0.baseAddress!) })
    }

    /// Its size in bytes, as written so far.
    public var size: Int64? {
        var info = stat()
        return fstat(fd, &info) == 0 ? Int64(info.st_size) : nil
    }

    /// Bytes free for a recording on its volume, wherever it is now (`RecordingFiles.usableBytes`). Off the main thread.
    public var freeBytes: Int64? {
        var fs = statfs()
        return fstatfs(fd, &fs) == 0 ? RecordingFiles.usableBytes(fs) : nil
    }

    /// Copies its contents into a new file at `url`, never replacing one, from the descriptor (so also once it's been
    /// deleted). A copy that fails is removed. Blocking.
    public func copy(to url: URL) throws {
        let out = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o644)
        guard out >= 0 else { throw Self.posixError(errno) }
        var failure: Int32 = 0
        let chunk = 1 << 20
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: chunk, alignment: 16)
        var offset: off_t = 0
        copying: while true {
            let n = pread(fd, buffer, chunk, offset)
            if n < 0 {
                if errno == EINTR { continue }
                failure = errno
                break
            }
            if n == 0 { break }
            var written = 0
            while written < n {
                let w = write(out, buffer + written, n - written)
                if w < 0 {
                    if errno == EINTR { continue }
                    failure = errno
                    break copying
                }
                written += w
            }
            offset += off_t(n)
        }
        buffer.deallocate()
        if failure == 0, fsync(out) != 0 { failure = errno }
        close(out)
        guard failure == 0 else {
            unlink(url.path)
            throw Self.posixError(failure)
        }
    }

    private static func posixError(_ code: Int32) -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }
}
