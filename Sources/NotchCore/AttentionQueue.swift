import Foundation

public enum Source: String, CaseIterable, Codable, Sendable {
    case codex, claude, agy, terminal

    public var name: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude Code"
        case .agy: "Antigravity"
        case .terminal: "Terminal"
        }
    }
}

public enum AttentionState: String, Sendable {
    case working, finished, needsInput, failed

    public var label: String {
        switch self {
        case .working: "Working"
        case .finished: "Finished"
        case .needsInput: "Needs you"
        case .failed: "Command failed"
        }
    }
}

public struct SessionKey: Hashable, Sendable {
    public let source: Source
    public let sessionID: String

    public init(source: Source, sessionID: String) {
        self.source = source
        self.sessionID = sessionID
    }
}

public struct PendingSession: Identifiable, Equatable, Sendable {
    public let id: SessionKey
    public var project: String
    public var branch: String?
    public var state: AttentionState
    public var stateSince: Double
    public var originApp: OriginApp?
    public var cmuxWorkspace: String?
    public var cmuxSurface: String?
    public var hostProcess: HostProcess?

    public init(
        source: Source,
        sessionID: String,
        project: String,
        state: AttentionState,
        cmuxWorkspace: String? = nil,
        cmuxSurface: String? = nil,
        originApp: OriginApp? = nil,
        hostProcess: HostProcess? = nil,
        branch: String? = nil,
        stateSince: Double = Date().timeIntervalSince1970
    ) {
        id = SessionKey(source: source, sessionID: sessionID)
        self.project = project
        self.branch = branch
        self.state = state
        self.stateSince = stateSince
        self.cmuxWorkspace = cmuxWorkspace
        self.cmuxSurface = cmuxSurface
        self.originApp = originApp
        self.hostProcess = hostProcess
    }
}

/// Only sessions awaiting attention. No transcripts, completed-work history, or persistence.
public struct AttentionQueue: Equatable, Sendable {
    public private(set) var sessions: [PendingSession] = []

    public init() {}

    public var sources: [Source] { Source.allCases.filter { count(for: $0) > 0 } }
    public var isEmpty: Bool { sessions.isEmpty }
    public var workingCount: Int { sessions.filter { $0.state == .working }.count }
    public var waitingCount: Int { sessions.filter { $0.state == .needsInput }.count }
    public var finishedCount: Int { sessions.filter { $0.state == .finished }.count }
    public var failedCount: Int { sessions.filter { $0.state == .failed }.count }

    public func count(for source: Source) -> Int {
        sessions.filter { $0.id.source == source }.count
    }

    public func needsInput(for source: Source) -> Bool {
        sessions.contains { $0.id.source == source && $0.state == .needsInput }
    }

    public func hasFailure(for source: Source) -> Bool {
        sessions.contains { $0.id.source == source && $0.state == .failed }
    }

    public mutating func receive(_ session: PendingSession) {
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            let preservedOrigin = session.originApp ?? sessions[index].originApp
            let preservedWorkspace = session.cmuxWorkspace ?? sessions[index].cmuxWorkspace
            let preservedSurface = session.cmuxSurface ?? sessions[index].cmuxSurface
            let preservedHost = session.hostProcess ?? sessions[index].hostProcess
            let preservedBranch = session.branch ?? sessions[index].branch
            let effectiveSince = sessions[index].state == session.state
                ? sessions[index].stateSince
                : session.stateSince
            sessions[index] = session
            sessions[index].originApp = preservedOrigin
            sessions[index].cmuxWorkspace = preservedWorkspace
            sessions[index].cmuxSurface = preservedSurface
            sessions[index].hostProcess = preservedHost
            sessions[index].branch = preservedBranch
            sessions[index].stateSince = effectiveSince
        } else {
            sessions.append(session)
        }
    }

    public mutating func acknowledge(_ key: SessionKey) {
        sessions.removeAll { $0.id == key }
    }

    public mutating func resumed(source: Source, sessionID: String, project: String = "Session",
                                 now: Double = Date().timeIntervalSince1970) {
        let key = SessionKey(source: source, sessionID: sessionID)
        if let index = sessions.firstIndex(where: { $0.id == key }) {
            if sessions[index].state != .working {
                sessions[index].stateSince = now
            }
            sessions[index].state = .working
        } else {
            sessions.append(PendingSession(source: source, sessionID: sessionID, project: project,
                                           state: .working, stateSince: now))
        }
    }

    public mutating func clear() { sessions.removeAll() }

    public mutating func clearFinished() {
        sessions.removeAll { $0.state == .finished }
    }

    /// Clear all terminal sessions (both finished and failed) while strictly protecting working and needsInput sessions.
    public mutating func clearTerminal() {
        sessions.removeAll { $0.state == .finished || $0.state == .failed }
    }
}
