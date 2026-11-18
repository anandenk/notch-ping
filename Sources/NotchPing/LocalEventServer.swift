import Darwin
import Foundation
import NotchCore

/// Event-driven, per-user Unix datagram listener. No polling or transcript access.
final class LocalEventServer: @unchecked Sendable {
    private let fd: Int32
    private let source: DispatchSourceRead
    private let onEvent: @Sendable (LiveEvent) -> Void

    init(onEvent: @escaping @Sendable (LiveEvent) -> Void) throws {
        let manager = FileManager.default
        let directory = LocalSocket.directory
        try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_uid == getuid(),
              info.st_mode & S_IFMT == S_IFDIR else { throw LocalSocket.SocketError.unsafeDirectory }
        guard chmod(directory.path, 0o700) == 0 else { throw LocalSocket.SocketError.system(errno) }
        var address = try LocalSocket.address(LocalSocket.path)
        let descriptor = socket(AF_UNIX, SOCK_DGRAM, 0)
        guard descriptor >= 0 else { throw LocalSocket.SocketError.system(errno) }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { target -> Bool in
                let previousMask = umask(0o177)
                defer { _ = umask(previousMask) }
                if bind(descriptor, target, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0 { return true }
                guard errno == EADDRINUSE else { return false }
                var existing = stat()
                guard lstat(LocalSocket.path, &existing) == 0, existing.st_uid == getuid(),
                      existing.st_mode & S_IFMT == S_IFSOCK else { return false }
                let probe = socket(AF_UNIX, SOCK_DGRAM, 0)
                guard probe >= 0 else { return false }
                let connected = connect(probe, target, socklen_t(MemoryLayout<sockaddr_un>.size))
                let error = errno
                close(probe)
                guard connected != 0, error == ECONNREFUSED else { return false }
                guard unlink(LocalSocket.path) == 0 else { return false }
                return bind(descriptor, target, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
        guard bound else { let error = errno; close(descriptor); throw LocalSocket.SocketError.system(error) }
        guard chmod(LocalSocket.path, 0o600) == 0 else {
            let error = errno
            unlink(LocalSocket.path)
            close(descriptor)
            throw LocalSocket.SocketError.system(error)
        }
        fd = descriptor
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        self.onEvent = onEvent
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: DispatchQueue(label: "local.notch-ping.events"))
        source.setEventHandler { [weak self] in self?.drain() }
        source.setCancelHandler { close(descriptor) }
        source.resume()
    }

    private func drain() {
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let length = recv(fd, &buffer, buffer.count, MSG_DONTWAIT)
            guard length > 0 else { break }
            guard let event = try? JSONDecoder().decode(LiveEvent.self, from: Data(buffer.prefix(length))),
                  event.valid else { continue }
            onEvent(event)
        }
    }

    func stop() { source.cancel(); unlink(LocalSocket.path) }
}
