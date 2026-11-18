import Darwin
import Foundation

public enum LocalSocket {
    public static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/NotchPing", isDirectory: true)
    }
    public static var path: String { directory.appendingPathComponent("events.sock").path }

    public static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw SocketError.pathTooLong }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.copyBytes(from: bytes)
        }
        return address
    }

    /// A datagram is atomic. The relay never starts an app, daemon, or network listener.
    @discardableResult
    public static func send(_ data: Data, to path: String = LocalSocket.path) -> Bool {
        guard data.count <= 8192, var address = try? address(path) else { return false }
        var info = stat()
        guard lstat(path, &info) == 0,
              info.st_uid == getuid(),
              (info.st_mode & S_IFMT) == S_IFSOCK else { return false }
        let fd = socket(AF_UNIX, SOCK_DGRAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { target in
                data.withUnsafeBytes { bytes in
                    sendto(fd, bytes.baseAddress, bytes.count, MSG_DONTWAIT, target,
                           socklen_t(MemoryLayout<sockaddr_un>.size)) == data.count
                }
            }
        }
    }

    public enum SocketError: Error { case pathTooLong, unsafeDirectory, alreadyRunning, system(Int32) }
}
