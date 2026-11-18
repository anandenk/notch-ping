import Darwin
import Foundation

/// Reads only local .git/HEAD metadata to surface branch or worktree identity.
/// Uses O_NOFOLLOW | O_NONBLOCK descriptor checks so untrusted repositories cannot
/// block on FIFOs, traverse symlinks, or leak arbitrary non-git file contents.
public enum GitContext {
    public struct RepositoryInfo: Equatable, Sendable {
        public let rootName: String
        public let branch: String

        public init(rootName: String, branch: String) {
            self.rootName = rootName
            self.branch = branch
        }
    }

    public static func repository(
        forDirectory directoryPath: String,
        stopAt boundaryPath: String? = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> RepositoryInfo? {
        let manager = FileManager.default
        let boundary = boundaryPath.map { ($0 as NSString).standardizingPath }
        var current = (directoryPath as NSString).standardizingPath
        guard !current.isEmpty, current != "/" else { return nil }

        for _ in 0..<10 {
            let dotGit = (current as NSString).appendingPathComponent(".git")
            if let resolved = resolveHead(dotGitPath: dotGit, repoRoot: current) {
                let rootName = sanitizeLabel((current as NSString).lastPathComponent, maxCount: 64)
                guard !rootName.isEmpty else { return nil }
                return RepositoryInfo(rootName: rootName, branch: resolved)
            }
            if let boundary, current == boundary { break }
            let parent = (current as NSString).deletingLastPathComponent
            if parent.isEmpty || parent == "/" || parent == current { break }
            var isDir: ObjCBool = false
            if !manager.fileExists(atPath: parent, isDirectory: &isDir) || !isDir.boolValue { break }
            current = parent
        }
        return nil
    }

    public static func branch(
        forDirectory directoryPath: String,
        stopAt boundaryPath: String? = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> String? {
        repository(forDirectory: directoryPath, stopAt: boundaryPath)?.branch
    }

    /// Safely read a small regular file without following symlinks or blocking on special files.
    private static func readBoundedRegularFile(at path: String, maxBytes: Int = 4096) -> String? {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size >= 0,
              info.st_size <= maxBytes else { return nil }
        let targetCount = Int(info.st_size)
        if targetCount == 0 { return "" }
        var buffer = [UInt8](repeating: 0, count: targetCount)
        let bytesRead = read(fd, &buffer, targetCount)
        guard bytesRead >= 0 else { return nil }
        return String(bytes: buffer.prefix(bytesRead), encoding: .utf8)
    }

    private static func isDirectoryNoFollow(_ path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFDIR
    }

    private static func isValidHexCommitID(_ value: String) -> Bool {
        guard value.count == 40 || value.count == 64 else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 0x30 && scalar.value <= 0x39)
                || (scalar.value >= 0x41 && scalar.value <= 0x46)
                || (scalar.value >= 0x61 && scalar.value <= 0x66)
        }
    }

    public static func sanitizeLabel(_ raw: String, maxCount: Int = 48) -> String {
        let filtered = raw.unicodeScalars.filter { scalar in
            if CharacterSet.controlCharacters.contains(scalar) || CharacterSet.illegalCharacters.contains(scalar) {
                return false
            }
            let v = scalar.value
            // Strip Unicode bidi overrides and zero-width formatting characters to prevent UI spoofing.
            if (0x200B...0x200F).contains(v) || (0x202A...0x202E).contains(v)
                || (0x2066...0x2069).contains(v) || v == 0xFEFF {
                return false
            }
            return true
        }
        return String(String.UnicodeScalarView(filtered).prefix(maxCount))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func resolveHead(dotGitPath: String, repoRoot: String) -> String? {
        var dotGitStat = stat()
        guard lstat(dotGitPath, &dotGitStat) == 0 else { return nil }
        let fileType = dotGitStat.st_mode & S_IFMT

        let gitDirPath: String
        var worktreeName: String?
        if fileType == S_IFDIR {
            gitDirPath = dotGitPath
        } else if fileType == S_IFREG, let pointerText = readBoundedRegularFile(at: dotGitPath) {
            guard let line = pointerText.split(whereSeparator: \.isNewline).first,
                  line.hasPrefix("gitdir:") else { return nil }
            let rawTarget = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
            guard !rawTarget.isEmpty else { return nil }
            if (rawTarget as NSString).isAbsolutePath {
                gitDirPath = (rawTarget as NSString).standardizingPath
            } else {
                gitDirPath = ((repoRoot as NSString).appendingPathComponent(rawTarget) as NSString).standardizingPath
            }
            guard isDirectoryNoFollow(gitDirPath) else { return nil }
            // Verify target is an actual git directory (contains commondir, gitdir, or refs/objects)
            let hasGitMarker = readBoundedRegularFile(at: (gitDirPath as NSString).appendingPathComponent("commondir")) != nil
                || readBoundedRegularFile(at: (gitDirPath as NSString).appendingPathComponent("gitdir")) != nil
                || isDirectoryNoFollow((gitDirPath as NSString).appendingPathComponent("refs"))
            guard hasGitMarker else { return nil }
            let parentDir = (gitDirPath as NSString).deletingLastPathComponent
            if (parentDir as NSString).lastPathComponent == "worktrees" {
                worktreeName = (gitDirPath as NSString).lastPathComponent
            }
        } else {
            return nil
        }

        let headPath = (gitDirPath as NSString).appendingPathComponent("HEAD")
        guard let headText = readBoundedRegularFile(at: headPath) else { return nil }
        let trimmed = headText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let rawLabel: String
        if trimmed.hasPrefix("ref: refs/heads/") {
            rawLabel = String(trimmed.dropFirst("ref: refs/heads/".count))
        } else if trimmed.hasPrefix("ref: ") {
            rawLabel = (String(trimmed.dropFirst("ref: ".count)) as NSString).lastPathComponent
        } else if isValidHexCommitID(trimmed) {
            if let worktreeName, !worktreeName.isEmpty {
                rawLabel = worktreeName
            } else {
                rawLabel = String(trimmed.prefix(7))
            }
        } else {
            return nil
        }

        let cleaned = sanitizeLabel(rawLabel, maxCount: 48)
        return cleaned.isEmpty ? nil : cleaned
    }
}

public enum RelativeAge {
    public static func format(since timestamp: Double, now: Double = Date().timeIntervalSince1970) -> String {
        guard timestamp.isFinite, now.isFinite else { return "just now" }
        let elapsed = max(0, now - timestamp)
        if elapsed < 15 { return "just now" }
        if elapsed < 60 { return "\(Int(elapsed))s" }
        if elapsed < 3600 { return "\(Int(elapsed / 60))m" }
        if elapsed < 86400 { return "\(Int(elapsed / 3600))h" }
        return "\(Int(elapsed / 86400))d"
    }
}
