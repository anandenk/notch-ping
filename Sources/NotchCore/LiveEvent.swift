import Foundation

public enum EventAction: String, Codable, Sendable {
    case started, finished, needsInput, running, toolCompleted, ended, failed
}

/// Deliberately excludes transcript paths, prompts, output text, and tool arguments.
public struct LiveEvent: Codable, Equatable, Sendable {
    public let version: Int
    public let source: Source
    public let sessionID: String
    public let project: String
    public let branch: String?
    public let action: EventAction
    public let timestamp: Double
    public let originApp: OriginApp?
    public let cmuxWorkspace: String?
    public let cmuxSurface: String?
    public let hostProcess: HostProcess?

    private enum CodingKeys: String, CodingKey {
        case version, source, sessionID, project, branch, action, timestamp, cmuxWorkspace, cmuxSurface, originApp, hostProcess
    }

    public init(source: Source, sessionID: String, project: String, action: EventAction,
                timestamp: Double = Date().timeIntervalSince1970, cmuxWorkspace: String? = nil,
                cmuxSurface: String? = nil, originApp: OriginApp? = nil, hostProcess: HostProcess? = nil,
                branch: String? = nil) {
        version = 1
        self.source = source
        self.sessionID = sessionID
        self.project = project
        self.branch = branch
        self.action = action
        self.timestamp = timestamp
        self.cmuxWorkspace = cmuxWorkspace
        self.cmuxSurface = cmuxSurface
        self.originApp = originApp
        self.hostProcess = hostProcess
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        source = try container.decode(Source.self, forKey: .source)
        sessionID = try container.decode(String.self, forKey: .sessionID)
        project = try container.decode(String.self, forKey: .project)
        branch = try container.decodeIfPresent(String.self, forKey: .branch)
        action = try container.decode(EventAction.self, forKey: .action)
        timestamp = try container.decodeIfPresent(Double.self, forKey: .timestamp) ?? Date().timeIntervalSince1970
        originApp = try container.decodeIfPresent(OriginApp.self, forKey: .originApp)
        cmuxWorkspace = try container.decodeIfPresent(String.self, forKey: .cmuxWorkspace)
        cmuxSurface = try container.decodeIfPresent(String.self, forKey: .cmuxSurface)
        hostProcess = try container.decodeIfPresent(HostProcess.self, forKey: .hostProcess)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(source, forKey: .source)
        try container.encode(sessionID, forKey: .sessionID)
        try container.encode(project, forKey: .project)
        try container.encodeIfPresent(branch, forKey: .branch)
        try container.encode(action, forKey: .action)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encodeIfPresent(originApp, forKey: .originApp)
        try container.encodeIfPresent(cmuxWorkspace, forKey: .cmuxWorkspace)
        try container.encodeIfPresent(cmuxSurface, forKey: .cmuxSurface)
        try container.encodeIfPresent(hostProcess, forKey: .hostProcess)
    }

    public var valid: Bool {
        version == 1 && !sessionID.isEmpty && sessionID.utf8.count <= 256
            && !project.isEmpty && project.utf8.count <= 256
            && (branch.map { !$0.isEmpty && $0.utf8.count <= 64 } ?? true)
            && timestamp.isFinite
    }
}

public enum HookAdapter {
    /// Normalize only documented lifecycle events. Never open transcript_path.
    public static func event(source: Source, payload: Data, timestamp: Double,
                             eventOverride: String? = nil, cmuxWorkspace: String? = nil,
                             cmuxSurface: String? = nil) -> LiveEvent? {
        guard let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { return nil }
        let sessionID: String
        if let id = json["session_id"] as? String, !id.isEmpty {
            sessionID = id
        } else if let id = json["conversationId"] as? String, !id.isEmpty {
            sessionID = id
        } else if let id = json["conversation_id"] as? String, !id.isEmpty {
            sessionID = id
        } else {
            return nil
        }
        let name: String
        if let override = eventOverride, !override.isEmpty {
            name = override
        } else if let n = json["hook_event_name"] as? String, !n.isEmpty {
            name = n
        } else if let n = json["hookEventName"] as? String, !n.isEmpty {
            name = n
        } else {
            return nil
        }
        // Ignore subagent, swarm-worker, battle-fork, and background child envelopes so only main agents appear.
        if isSubagentOrWorkerPayload(json, source: source, sessionID: sessionID, eventName: name) {
            return nil
        }

        let action: EventAction
        switch name {
        case "Stop", "turn-completion":
            let rawReason = json["terminationReason"] as? String ?? json["termination_reason"] as? String ?? ""
            let reason = rawReason.trimmingCharacters(in: .whitespacesAndNewlines)
            let error = (json["error"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let isErrorBool = json["is_error"] as? Bool ?? json["isError"] as? Bool ?? false
            let isErrorReason = reason.caseInsensitiveCompare("error") == .orderedSame
                || reason.caseInsensitiveCompare("failed") == .orderedSame
                || reason.caseInsensitiveCompare("aborted") == .orderedSame
                || reason.uppercased() == "ERROR"
            let fullyIdle = json["fullyIdle"] as? Bool ?? json["fully_idle"] as? Bool ?? true
            if isErrorReason || isErrorBool || (!error.isEmpty && reason != "NO_TOOL_CALL") {
                action = .failed
            } else if reason.caseInsensitiveCompare("user_canceled") == .orderedSame {
                action = .ended
            } else if !fullyIdle {
                action = .running
            } else {
                action = .finished
            }
        case "PermissionRequest", "Elicitation":
            action = .needsInput
        case "UserPromptSubmit", "PreInvocation":
            action = .running
        case "PostToolUse", "ElicitationResult":
            action = .toolCompleted
        case "SessionStart":
            // Idle startup: newly launched session is waiting for user prompt, not working.
            // Distinct from .ended so async SessionStart never wipes out a concurrent first prompt.
            action = .started
        case "SessionEnd", "Interrupt":
            action = .ended
        case "StopFailure":
            action = .failed
        case "PreToolUse":
            if source == .agy {
                let tool = (json["toolCall"] as? [String: Any])?["name"] as? String
                    ?? json["tool_name"] as? String
                    ?? ""
                guard ["ask_question", "ask_user_question", "request_user_input"].contains(tool) else { return nil }
                action = .needsInput
            } else {
                guard let tool = json["tool_name"] as? String,
                      ["AskUserQuestion", "ExitPlanMode", "request_user_input"].contains(tool) else { return nil }
                action = .needsInput
            }
        case "Notification":
            guard source == .claude, let type = json["notification_type"] as? String,
                  ["permission_prompt", "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input"].contains(type) else { return nil }
            action = .needsInput
        default: return nil
        }
        let workspaceList = (json["workspacePaths"] as? [String]) ?? (json["workspace_paths"] as? [String]) ?? []
        let homePath = (FileManager.default.homeDirectoryForCurrentUser.path as NSString).standardizingPath
        let specificWorkspace = workspaceList.first { path in
            let normalized = (path as NSString).standardizingPath
            return !normalized.isEmpty && normalized != "/" && normalized != homePath
        }
        let cwd: String
        if let c = json["cwd"] as? String, !c.isEmpty {
            let normalizedCwd = (c as NSString).standardizingPath
            if normalizedCwd == homePath, let specificWorkspace {
                cwd = specificWorkspace
            } else {
                cwd = c
            }
        } else if let specificWorkspace {
            cwd = specificWorkspace
        } else if let first = workspaceList.first, !first.isEmpty {
            cwd = first
        } else {
            cwd = ""
        }
        // Ignore root filesystem executions (e.g. internal daemon checks at /)
        if cwd == "/" { return nil }
        let repoInfo = cwd.isEmpty ? nil : GitContext.repository(forDirectory: cwd)
        let rawProject = repoInfo?.rootName ?? (cwd as NSString).lastPathComponent
        if rawProject == "/" { return nil }
        let project = clean(rawProject, fallback: "Session")
        if project == "/" { return nil }
        let event = LiveEvent(source: source, sessionID: sessionID, project: project,
                              action: action, timestamp: timestamp, cmuxWorkspace: cmuxWorkspace,
                              cmuxSurface: cmuxSurface, branch: repoInfo?.branch)
        return event.valid ? event : nil
    }

    private static func isSubagentOrWorkerPayload(_ json: [String: Any], source: Source,
                                                  sessionID: String, eventName: String) -> Bool {
        let scopes: [[String: Any]] = if let common = json["common"] as? [String: Any] {
            [json, common]
        } else {
            [json]
        }
        let childIDKeys = [
            "agent_id", "agentId",
            "parent_agent_id", "parentAgentId",
            "parent_session_id", "parentSessionId",
            "caller_session_id", "callerSessionId",
            "parent_thread_id", "parentThreadId",
            "parent_conversation_id", "parentConversationId",
            "subagent_kind", "subagentKind"
        ]
        for scope in scopes {
            for key in childIDKeys {
                if let value = scope[key] as? String, !value.isEmpty { return true }
            }
            if let rootID = (scope["rootConversationId"] as? String) ?? (scope["root_conversation_id"] as? String),
               !rootID.isEmpty, rootID != sessionID {
                return true
            }
            if (scope["isBattleMode"] as? Bool) == true || (scope["is_battle_mode"] as? Bool) == true {
                return true
            }
            for contextKey in ["callerContext", "caller_context", "threadSource", "thread_source"] {
                if let ctx = (scope[contextKey] as? String)?.lowercased(), !ctx.isEmpty,
                   ctx.contains("subagent") || ctx.contains("swarm") || ctx.contains("worker") || ctx.contains("thread_spawn") {
                    return true
                }
            }
            // Antigravity swarm workers, monitors, and narrators run without human USER_INPUT steps,
            // emitting an explicit empty lastUserInput string on execution hooks.
            if source == .agy, eventName != "SessionStart" {
                let rawInput = (scope["lastUserInput"] as? String) ?? (scope["last_user_input"] as? String)
                if let rawInput, rawInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return true
                }
            }
        }
        return false
    }

    private static func clean(_ string: String, fallback: String) -> String {
        let value = GitContext.sanitizeLabel(string, maxCount: 64)
        return value.isEmpty ? fallback : value
    }
}

/// Bounds local bookkeeping and rejects late delivery from older hook processes.
public struct LiveAttention: Sendable {
    public private(set) var queue = AttentionQueue()
    private var latest: [SessionKey: Double] = [:]
    private var lastAction: [SessionKey: EventAction] = [:]
    private var ignoredChildSessions: Set<SessionKey> = []

    public init() {}

    private mutating func pruneIfNeeded() {
        if latest.count > 512, let oldest = latest.min(by: { $0.value < $1.value })?.key {
            latest.removeValue(forKey: oldest)
            lastAction.removeValue(forKey: oldest)
            ignoredChildSessions.remove(oldest)
            queue.acknowledge(oldest)
        }
        if ignoredChildSessions.count > 512, let any = ignoredChildSessions.first {
            ignoredChildSessions.remove(any)
        }
    }

    @discardableResult
    public mutating func receive(_ event: LiveEvent) -> Bool {
        guard event.valid else { return false }
        let key = SessionKey(source: event.source, sessionID: event.sessionID)
        if ignoredChildSessions.contains(key) { return false }

        // A single-session terminal CLI (e.g. agy or claude TUI) has one active main conversation at a time.
        // Any concurrent secondary conversation spawned inside that same active CLI process (such as a forked
        // swarm worker) is a child worker and is suppressed along with its later completion events.
        if let host = event.hostProcess, host.singleSessionCLI,
           !queue.sessions.contains(where: { $0.id == key }),
           queue.sessions.contains(where: {
               $0.id != key && $0.hostProcess == host && ($0.state == .working || $0.state == .needsInput)
           }) {
            ignoredChildSessions.insert(key)
            pruneIfNeeded()
            return false
        }

        if event.action == .started {
            if let existing = queue.sessions.first(where: { $0.id == key }),
               existing.state == .working || existing.state == .needsInput {
                // Async SessionStart arrived alongside an active turn: enrich metadata without clearing state.
                latest[key] = max(latest[key, default: -.infinity], event.timestamp)
                pruneIfNeeded()
                queue.receive(PendingSession(source: event.source, sessionID: event.sessionID,
                                             project: existing.project, state: existing.state,
                                             cmuxWorkspace: event.cmuxWorkspace,
                                             cmuxSurface: event.cmuxSurface,
                                             originApp: event.originApp,
                                             hostProcess: event.hostProcess,
                                             branch: event.branch,
                                             stateSince: existing.stateSince))
                return true
            }
            guard event.timestamp >= latest[key, default: -.infinity] else { return false }
            latest[key] = event.timestamp
            lastAction[key] = .started
            pruneIfNeeded()
            queue.acknowledge(key)
            return true
        }

        guard event.timestamp >= latest[key, default: -.infinity] else { return false }

        if event.action == .toolCompleted,
           let prior = lastAction[key],
           prior == .finished || prior == .failed || prior == .ended {
            // Reject late async PostToolUse arriving after Stop, StopFailure, Interrupt, or SessionEnd.
            return false
        }

        latest[key] = event.timestamp
        lastAction[key] = event.action
        pruneIfNeeded()

        switch event.action {
        case .ended:
            queue.acknowledge(key)
        case .running, .toolCompleted, .finished, .needsInput, .failed:
            let state: AttentionState = switch event.action {
            case .running, .toolCompleted: .working
            case .finished: .finished
            case .needsInput: .needsInput
            case .failed: .failed
            case .started, .ended: .finished
            }
            queue.receive(PendingSession(source: event.source, sessionID: event.sessionID,
                                         project: event.project, state: state,
                                         cmuxWorkspace: event.cmuxWorkspace,
                                         cmuxSurface: event.cmuxSurface,
                                         originApp: event.originApp,
                                         hostProcess: event.hostProcess,
                                         branch: event.branch,
                                         stateSince: event.timestamp))
        case .started:
            break
        }
        return true
    }

    public mutating func acknowledge(_ key: SessionKey) { queue.acknowledge(key) }
    public mutating func clear() {
        queue.clear()
        ignoredChildSessions.removeAll()
    }
    public mutating func clearFinished() { queue.clearFinished() }
    public mutating func clearTerminal() { queue.clearTerminal() }
}
