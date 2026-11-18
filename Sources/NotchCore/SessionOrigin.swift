import CryptoKit
import Darwin
import Foundation

/// App identity only; never a transcript, working-directory heuristic, or pane target.
public enum OriginApp: String, Codable, CaseIterable, Sendable {
    case cmux, terminal, iterm, warp, codex, claude, antigravity

    public var name: String {
        switch self {
        case .cmux: "cmux"
        case .terminal: "Terminal"
        case .iterm: "iTerm"
        case .warp: "Warp"
        case .codex: "Codex Desktop"
        case .claude: "Claude Desktop"
        case .antigravity: "Antigravity"
        }
    }
    public var bundleID: String {
        switch self {
        case .cmux: "com.cmuxterm.app"
        case .terminal: "com.apple.Terminal"
        case .iterm: "com.googlecode.iterm2"
        case .warp: "dev.warp.Warp-Stable"
        case .codex: "com.openai.codex"
        case .claude: "com.anthropic.claudefordesktop"
        case .antigravity: "com.google.antigravity"
        }
    }
}

/// Single-session or host agent process identity, guarded by kernel start time against PID reuse.
public struct HostProcess: Codable, Equatable, Sendable {
    public let pid: Int32
    public let startTime: Int64
    public let singleSessionCLI: Bool

    private enum CodingKeys: String, CodingKey {
        case pid, startTime, singleSessionCLI
    }

    public init(pid: Int32, startTime: Int64, singleSessionCLI: Bool = false) {
        self.pid = pid
        self.startTime = startTime
        self.singleSessionCLI = singleSessionCLI
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pid = try container.decode(Int32.self, forKey: .pid)
        startTime = try container.decode(Int64.self, forKey: .startTime)
        singleSessionCLI = try container.decodeIfPresent(Bool.self, forKey: .singleSessionCLI) ?? false
    }
}

public enum ProcessLiveness {
    public static func isAlive(_ host: HostProcess) -> Bool {
        guard host.pid > 1 else { return false }
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, host.pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return false }
        guard info.kp_proc.p_stat != SZOMB else { return false }
        return Int64(info.kp_proc.p_un.__p_starttime.tv_sec) == host.startTime
    }
}

public enum OriginDetector {
    public struct Ancestor: Equatable, Sendable {
        public let pid: Int32
        public let startTime: Int64
        public let path: String

        public init(pid: Int32, startTime: Int64, path: String) {
            self.pid = pid
            self.startTime = startTime
            self.path = path
        }
    }

    /// Stop at a shared daemon: its own parent/environment isn't session provenance.
    public static func app(ancestorPaths: [String]) -> OriginApp? {
        for path in ancestorPaths {
            if path.contains("/app-server-daemon/") { return nil }
            for (component, app): (String, OriginApp) in [
                ("/cmux.app/", .cmux), ("/Terminal.app/", .terminal),
                ("/iTerm.app/", .iterm), ("/Warp.app/", .warp),
                ("/Codex.app/", .codex), ("/ChatGPT.app/", .codex),
                ("/Claude.app/", .claude), ("/Antigravity.app/", .antigravity)
            ] where path.contains(component) { return app }
        }
        return nil
    }

    /// Identify the direct agent process that invoked the hook (skipping shell wrappers).
    public static func hostProcess(ancestors: [Ancestor]) -> HostProcess? {
        let shells: Set<String> = ["sh", "bash", "zsh", "dash", "env"]
        let multiSessionHost = ancestors.contains {
            $0.path.contains("/Antigravity.app/")
                || $0.path.contains("/Claude.app/")
                || $0.path.contains("/ChatGPT.app/")
                || $0.path.contains("/Codex.app/")
                || $0.path.contains("/app-server-daemon/")
        }
        for ancestor in ancestors {
            let name = (ancestor.path as NSString).lastPathComponent
            if shells.contains(name) { continue }
            let isCLI = !multiSessionHost && (
                ancestor.path.hasSuffix("/agy")
                    || ancestor.path.contains("/claude/")
                    || ancestor.path.hasSuffix("/claude")
            )
            if isCLI
                || ancestor.path.hasSuffix("/codex")
                || ancestor.path.contains("/Antigravity.app/")
                || ancestor.path.contains("/Claude.app/")
                || ancestor.path.contains("/ChatGPT.app/")
                || ancestor.path.contains("/Codex.app/") {
                return HostProcess(pid: ancestor.pid, startTime: ancestor.startTime, singleSessionCLI: isCLI)
            }
            break
        }
        return nil
    }

    /// Uses sysctl KERN_PROC_PID so setuid ancestors like /usr/bin/login (used by
    /// Terminal.app and iTerm2) do not fail parent traversal with EPERM.
    public static func processInfo(pid: pid_t) -> (ppid: pid_t, startTime: Int64)? {
        guard pid > 1 else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return (info.kp_eproc.e_ppid, Int64(info.kp_proc.p_un.__p_starttime.tv_sec))
    }

    public static func inspectCurrentProcess() -> (app: OriginApp?, host: HostProcess?) {
        var ancestors: [Ancestor] = []
        var pid = getppid()
        var visited: Set<pid_t> = []
        for _ in 0..<32 {
            guard pid > 1, visited.insert(pid).inserted else { break }
            var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else {
                // Incomplete ancestry is not evidence for an app farther up.
                break
            }
            let pathString = String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            guard let info = processInfo(pid: pid) else { break }
            ancestors.append(Ancestor(pid: pid, startTime: info.startTime, path: pathString))
            pid = info.ppid
        }
        return (app(ancestorPaths: ancestors.map(\.path)), hostProcess(ancestors: ancestors))
    }

    public static func currentApp() -> OriginApp? {
        inspectCurrentProcess().app
    }
}

/// Small private, expiring records owned by Notch Ping. No agent state is read.
public struct OriginStore: Sendable {
    public let directory: URL
    public let lifetime: TimeInterval
    public init(directory: URL = LocalSocket.directory.appendingPathComponent("origins"),
                lifetime: TimeInterval = 30 * 24 * 60 * 60) {
        self.directory = directory
        self.lifetime = lifetime
    }
    private struct Record: Codable {
        let app: OriginApp
        let timestamp: Double
    }
    private func url(_ key: SessionKey) -> URL {
        let hash = SHA256.hash(data: Data("\(key.source.rawValue):\(key.sessionID)".utf8))
            .map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(hash + ".json")
    }
    public func app(for key: SessionKey, now: Double = Date().timeIntervalSince1970) -> OriginApp? {
        let file = url(key)
        guard (try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false,
              let values = try? file.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey]),
              values.isSymbolicLink != true, (values.fileSize ?? 4097) <= 4096,
              let data = try? Data(contentsOf: file),
              let record = try? JSONDecoder().decode(Record.self, from: data),
              record.timestamp.isFinite, record.timestamp <= now,
              now - record.timestamp < lifetime else { return nil }
        return record.app
    }
    public func remember(_ app: OriginApp, for key: SessionKey,
                         now: Double = Date().timeIntervalSince1970) throws {
        if self.app(for: key, now: now + min(86400, lifetime / 2)) == app { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        var dirStat = stat()
        guard lstat(directory.path, &dirStat) == 0,
              dirStat.st_uid == getuid(),
              (dirStat.st_mode & S_IFMT) == S_IFDIR else { throw LocalSocket.SocketError.unsafeDirectory }
        _ = chmod(directory.path, 0o700)
        let destination = url(key)
        var existingStat = stat()
        if lstat(destination.path, &existingStat) == 0, (existingStat.st_mode & S_IFMT) == S_IFLNK {
            throw LocalSocket.SocketError.unsafeDirectory
        }
        let data = try JSONEncoder().encode(Record(app: app, timestamp: now))
        let tempURL = directory.appendingPathComponent(".tmp-\(UUID().uuidString)")
        let fd = open(tempURL.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw LocalSocket.SocketError.system(errno) }
        do {
            try data.withUnsafeBytes { rawBuffer in
                guard let base = rawBuffer.baseAddress else { return }
                var written = 0
                while written < rawBuffer.count {
                    let rc = write(fd, base.advanced(by: written), rawBuffer.count - written)
                    if rc < 0 { throw LocalSocket.SocketError.system(errno) }
                    written += rc
                }
            }
            close(fd)
            guard rename(tempURL.path, destination.path) == 0 else {
                throw LocalSocket.SocketError.system(errno)
            }
        } catch {
            close(fd)
            unlink(tempURL.path)
            throw error
        }
        // Keep storage bounded and discard expired records, without a background timer.
        let files = try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey])
            .filter { $0.pathExtension == "json" }
            .sorted {
                ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
            }
        for (index, file) in files.enumerated() {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? 0
            if index >= 512 || now - modified >= lifetime { try? FileManager.default.removeItem(at: file) }
        }
    }
}
