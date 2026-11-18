import Foundation
import Testing
@testable import NotchCore

private func hook(_ fields: [String: Any], source: Source = .codex) -> LiveEvent? {
    HookAdapter.event(source: source, payload: try! JSONSerialization.data(withJSONObject: fields), timestamp: 10)
}

@Test func hookStripsSensitiveFieldsAndUsesFolderOnly() throws {
    let event = try #require(hook(["session_id": "session", "hook_event_name": "Stop", "cwd": "/private/path/project",
                                  "last_assistant_message": "SECRET", "transcript_path": "/private/log",
                                  "tool_input": ["command": "SECRET"]]))
    #expect(event.project == "project")
    #expect(event.action == .finished)
    let encoded = String(data: try JSONEncoder().encode(event), encoding: .utf8)!
    #expect(!encoded.contains("SECRET"))
    #expect(!encoded.contains("/private"))
}

@Test func inputSignalsAreExplicitAndIdleNotificationsAreIgnored() {
    #expect(hook(["session_id": "a", "hook_event_name": "PermissionRequest"])?.action == .needsInput)
    #expect(hook(["session_id": "a", "hook_event_name": "PreToolUse", "tool_name": "AskUserQuestion"], source: .claude)?.action == .needsInput)
    #expect(hook(["session_id": "a", "hook_event_name": "Notification", "notification_type": "idle_prompt"], source: .claude) == nil)
    #expect(hook(["session_id": "a", "hook_event_name": "PostToolUse"])?.action == .toolCompleted)
}

@Test func subagentEnvelopesAndMalformedEventsAreIgnored() {
    #expect(hook(["session_id": "a", "hook_event_name": "Stop", "agent_id": "child"]) == nil)
    #expect(hook(["session_id": "a", "hook_event_name": "Stop", "parent_thread_id": "root-thread"]) == nil)
    #expect(hook(["session_id": "a", "hook_event_name": "Stop", "subagent_kind": "worker"]) == nil)
    #expect(hook(["session_id": "a", "hook_event_name": "Stop", "thread_source": "thread_spawn"]) == nil)
    #expect(hook(["hook_event_name": "Stop"]) == nil)
    #expect(hook(["session_id": "a", "hook_event_name": "SubagentStop"]) == nil)
    #expect(hook(["conversationId": "a", "agentId": "child"], source: .agy) == nil)
    #expect(hook(["conversationId": "child", "rootConversationId": "root", "hookEventName": "PreInvocation", "cwd": "/tmp/p"], source: .agy) == nil)
    #expect(hook(["conversationId": "root", "rootConversationId": "root", "hookEventName": "PreInvocation", "lastUserInput": "Hello", "cwd": "/tmp/p"], source: .agy)?.action == .running)
    #expect(hook(["conversationId": "battle-arm", "isBattleMode": true, "hookEventName": "PreInvocation", "cwd": "/tmp/p"], source: .agy) == nil)
    // Antigravity swarm workers emit explicit empty lastUserInput on execution hooks
    #expect(hook(["conversationId": "swarm-w1", "hookEventName": "PreInvocation", "lastUserInput": "", "cwd": "/tmp/p"], source: .agy) == nil)
    #expect(hook(["conversationId": "swarm-w1", "hookEventName": "Stop", "lastUserInput": "", "terminationReason": "NO_TOOL_CALL", "cwd": "/tmp/p"], source: .agy) == nil)
    #expect(hook(["session_id": "daemon", "hook_event_name": "Stop", "cwd": "/"]) == nil)
}

@Test func agyEventsNormalizeCorrectly() throws {
    let payload = try JSONSerialization.data(withJSONObject: [
        "conversationId": "agy-sess-1",
        "workspacePaths": ["/Users/user/workspace/notch-ping"],
        "terminationReason": "NO_TOOL_CALL"
    ])
    let event = try #require(HookAdapter.event(source: .agy, payload: payload, timestamp: 10, eventOverride: "Stop"))
    #expect(event.source == .agy)
    #expect(event.sessionID == "agy-sess-1")
    #expect(event.project == "notch-ping")
    #expect(event.action == .finished)

    let preInv = try #require(HookAdapter.event(source: .agy, payload: payload, timestamp: 11, eventOverride: "PreInvocation"))
    #expect(preInv.action == .running)

    let questionPayload = try JSONSerialization.data(withJSONObject: [
        "conversationId": "agy-sess-1",
        "workspacePaths": ["/Users/user/workspace/notch-ping"],
        "toolCall": ["name": "ask_question", "args": [:]]
    ])
    let question = try #require(HookAdapter.event(source: .agy, payload: questionPayload, timestamp: 12, eventOverride: "PreToolUse"))
    #expect(question.action == .needsInput)
}

@Test func lateCompletionCannotOverwriteResumedSession() {
    var live = LiveAttention()
    live.receive(LiveEvent(source: .codex, sessionID: "a", project: "project", action: .finished, timestamp: 10))
    live.receive(LiveEvent(source: .codex, sessionID: "a", project: "project", action: .running, timestamp: 12))
    let accepted = live.receive(LiveEvent(source: .codex, sessionID: "a", project: "project", action: .finished, timestamp: 11))
    #expect(!accepted)
    #expect(live.queue.workingCount == 1)
    #expect(live.queue.sessions.first?.state == .working)
    live.receive(LiveEvent(source: .claude, sessionID: "b", project: "project", action: .needsInput, timestamp: 13))
    #expect(live.queue.waitingCount == 1)
}

@Test func cmuxWorkspacePropagatesToQueue() throws {
    let payload = try JSONSerialization.data(withJSONObject: [
        "session_id": "test-cmux-sess",
        "cwd": "/Users/user/workspace/notch-ping",
        "hook_event_name": "UserPromptSubmit"
    ])
    let event = try #require(HookAdapter.event(source: .codex, payload: payload, timestamp: 20, cmuxWorkspace: "workspace:123", cmuxSurface: "surface:456"))
    #expect(event.cmuxWorkspace == "workspace:123")
    #expect(event.cmuxSurface == "surface:456")

    var live = LiveAttention()
    live.receive(event)
    #expect(live.queue.sessions.first?.cmuxWorkspace == "workspace:123")
    #expect(live.queue.sessions.first?.cmuxSurface == "surface:456")
}

@Test func lifecycleEventsDistinguishIdleFromWorking() throws {
    // 1. Idle startup (SessionStart) does not put session into working state
    let startEvent = try #require(hook(["session_id": "idle-sess", "hook_event_name": "SessionStart", "cwd": "/path/project"]))
    #expect(startEvent.action == .started)
    var live = LiveAttention()
    live.receive(startEvent)
    #expect(live.queue.isEmpty)

    // 2. Prompt start (UserPromptSubmit) enters working state
    let promptEvent = try #require(hook(["session_id": "idle-sess", "hook_event_name": "UserPromptSubmit", "cwd": "/path/project"]))
    #expect(promptEvent.action == .running)
    live.receive(promptEvent)
    #expect(live.queue.workingCount == 1)
    #expect(live.queue.sessions.first?.state == .working)

    // 3. Normal completion (Stop with fullyIdle: true) transitions to finished
    let stopEvent = try #require(hook(["session_id": "idle-sess", "hook_event_name": "Stop", "cwd": "/path/project", "fullyIdle": true, "terminationReason": "NO_TOOL_CALL"]))
    #expect(stopEvent.action == .finished)
    live.receive(stopEvent)
    #expect(live.queue.finishedCount == 1)
    #expect(live.queue.sessions.first?.state == .finished)

    // 4. Resumption back to working
    let resumeEvent = try #require(hook(["session_id": "idle-sess", "hook_event_name": "UserPromptSubmit", "cwd": "/path/project"]))
    live.receive(resumeEvent)
    #expect(live.queue.workingCount == 1)

    // 5. Interruption (Interrupt) clears session
    let interruptEvent = try #require(hook(["session_id": "idle-sess", "hook_event_name": "Interrupt", "cwd": "/path/project"]))
    #expect(interruptEvent.action == .ended)
    live.receive(interruptEvent)
    #expect(live.queue.isEmpty)

    // 6. User cancellation reason in Stop also clears session
    live.receive(promptEvent)
    #expect(live.queue.workingCount == 1)
    let cancelEvent = try #require(hook(["session_id": "idle-sess", "hook_event_name": "Stop", "cwd": "/path/project", "terminationReason": "USER_CANCELED"]))
    #expect(cancelEvent.action == .ended)
    live.receive(cancelEvent)
    #expect(live.queue.isEmpty)

    // 7. Normal session end (SessionEnd) clears session
    live.receive(promptEvent)
    #expect(live.queue.workingCount == 1)
    let endEvent = try #require(hook(["session_id": "idle-sess", "hook_event_name": "SessionEnd", "cwd": "/path/project"]))
    #expect(endEvent.action == .ended)
    live.receive(endEvent)
    #expect(live.queue.isEmpty)
}

@Test func asyncSessionStartAfterFirstPromptDoesNotWipeOutWorkingState() {
    var live = LiveAttention()
    // Reproduces observed Codex race: UserPromptSubmit arrives milliseconds before async SessionStart.
    live.receive(LiveEvent(source: .codex, sessionID: "race-start", project: "notch-ping",
                           action: .running, timestamp: 100.001))
    #expect(live.queue.workingCount == 1)

    live.receive(LiveEvent(source: .codex, sessionID: "race-start", project: "notch-ping",
                           action: .started, timestamp: 100.005, originApp: .cmux))
    #expect(live.queue.workingCount == 1)
    #expect(live.queue.sessions.first?.state == .working)
    #expect(live.queue.sessions.first?.originApp == .cmux)
}

@Test func lateAsyncPostToolUseCannotOverwriteFinishedOrResurrectEndedSession() {
    var live = LiveAttention()
    live.receive(LiveEvent(source: .codex, sessionID: "race-stop", project: "notch-ping",
                           action: .running, timestamp: 10.0))
    live.receive(LiveEvent(source: .codex, sessionID: "race-stop", project: "notch-ping",
                           action: .needsInput, timestamp: 11.0))
    // Genuine PostToolUse after approval transitions Needs you -> Working
    let resumed = live.receive(LiveEvent(source: .codex, sessionID: "race-stop", project: "notch-ping",
                                         action: .toolCompleted, timestamp: 12.0))
    #expect(resumed)
    #expect(live.queue.sessions.first?.state == .working)

    // Turn finishes at t=13.0, then delayed async PostToolUse arrives at t=13.005
    live.receive(LiveEvent(source: .codex, sessionID: "race-stop", project: "notch-ping",
                           action: .finished, timestamp: 13.0))
    let lateAfterStop = live.receive(LiveEvent(source: .codex, sessionID: "race-stop", project: "notch-ping",
                                               action: .toolCompleted, timestamp: 13.005))
    #expect(!lateAfterStop)
    #expect(live.queue.sessions.first?.state == .finished)

    // Turn interrupted at t=20.0, then delayed async PostToolUse arrives at t=20.004
    live.receive(LiveEvent(source: .codex, sessionID: "race-stop", project: "notch-ping",
                           action: .running, timestamp: 19.0))
    live.receive(LiveEvent(source: .codex, sessionID: "race-stop", project: "notch-ping",
                           action: .ended, timestamp: 20.0))
    let lateAfterInterrupt = live.receive(LiveEvent(source: .codex, sessionID: "race-stop", project: "notch-ping",
                                                    action: .toolCompleted, timestamp: 20.004))
    #expect(!lateAfterInterrupt)
    #expect(live.queue.isEmpty)
}

@Test func workspacePathsPreferProjectOverHomeDirectoryCwd() throws {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let payload = try JSONSerialization.data(withJSONObject: [
        "conversationId": "home-launch",
        "cwd": home,
        "workspacePaths": [home, "\(home)/Developer/notch-ping"],
        "terminationReason": "NO_TOOL_CALL"
    ])
    let event = try #require(HookAdapter.event(source: .agy, payload: payload, timestamp: 10, eventOverride: "Stop"))
    #expect(event.project == "notch-ping")
}

@Test func gitBranchResolvesStandardRepoSubdirectoryAndWorktrees() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("git-ctx-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }

    // 1. Standard repo + nested subdirectory
    let repo = root.appendingPathComponent("main-repo")
    let subdir = repo.appendingPathComponent("Sources/Feature")
    let gitDir = repo.appendingPathComponent(".git")
    try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
    try Data("ref: refs/heads/feat/notch-motion\n".utf8).write(to: gitDir.appendingPathComponent("HEAD"))

    #expect(GitContext.branch(forDirectory: subdir.path, stopAt: root.path) == "feat/notch-motion")

    // 2. Linked git worktree with detached HEAD falls back to worktree name
    let wtMeta = gitDir.appendingPathComponent("worktrees/parallel-worker-2")
    try FileManager.default.createDirectory(at: wtMeta, withIntermediateDirectories: true)
    try Data("a1b2c3d4e5f60718293a4b5c6d7e8f9012345678\n".utf8).write(to: wtMeta.appendingPathComponent("HEAD"))
    try Data("../..\n".utf8).write(to: wtMeta.appendingPathComponent("commondir"))

    let worktreeDir = root.appendingPathComponent("wt-checkout")
    try FileManager.default.createDirectory(at: worktreeDir, withIntermediateDirectories: true)
    try Data("gitdir: \(wtMeta.path)\n".utf8).write(to: worktreeDir.appendingPathComponent(".git"))

    #expect(GitContext.branch(forDirectory: worktreeDir.path, stopAt: root.path) == "parallel-worker-2")

    // 3. Untrusted gitdir pointing to arbitrary non-git directory or non-hex HEAD never leaks content
    let decoyDir = root.appendingPathComponent("decoy-secrets")
    try FileManager.default.createDirectory(at: decoyDir, withIntermediateDirectories: true)
    try Data("SECRET_API_TOKEN_VALUE\n".utf8).write(to: decoyDir.appendingPathComponent("HEAD"))
    let untrustedRepo = root.appendingPathComponent("untrusted")
    try FileManager.default.createDirectory(at: untrustedRepo, withIntermediateDirectories: true)
    try Data("gitdir: \(decoyDir.path)\n".utf8).write(to: untrustedRepo.appendingPathComponent(".git"))
    #expect(GitContext.branch(forDirectory: untrustedRepo.path, stopAt: root.path) == nil)

    // 4. Symlinked HEAD is rejected by O_NOFOLLOW
    let symlinkRepo = root.appendingPathComponent("symlink-repo")
    let symlinkGit = symlinkRepo.appendingPathComponent(".git")
    try FileManager.default.createDirectory(at: symlinkGit, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
        at: symlinkGit.appendingPathComponent("HEAD"),
        withDestinationURL: gitDir.appendingPathComponent("HEAD")
    )
    #expect(GitContext.branch(forDirectory: symlinkRepo.path, stopAt: root.path) == nil)

    // 5. Bidi override characters are stripped from labels
    #expect(GitContext.sanitizeLabel("feat/\u{202E}spoof\u{202C}") == "feat/spoof")

    // 6. Non-git directory returns nil
    let plainDir = root.appendingPathComponent("plain")
    try FileManager.default.createDirectory(at: plainDir, withIntermediateDirectories: true)
    #expect(GitContext.branch(forDirectory: plainDir.path, stopAt: root.path) == nil)
}

@Test func stateSinceAnchorsAcrossRepeatedWorkingUpdatesAndRelativeAgeFormatsCleanly() {
    var live = LiveAttention()
    live.receive(LiveEvent(source: .codex, sessionID: "timed", project: "repo",
                           action: .running, timestamp: 1000, branch: "feat/timer"))
    #expect(live.queue.sessions.first?.stateSince == 1000)
    #expect(live.queue.sessions.first?.branch == "feat/timer")

    // Subsequent tool completions keep the original Working start time and branch
    live.receive(LiveEvent(source: .codex, sessionID: "timed", project: "repo",
                           action: .toolCompleted, timestamp: 1180))
    #expect(live.queue.sessions.first?.stateSince == 1000)
    #expect(live.queue.sessions.first?.branch == "feat/timer")

    // Transitioning to Needs you resets stateSince to when waiting started
    live.receive(LiveEvent(source: .codex, sessionID: "timed", project: "repo",
                           action: .needsInput, timestamp: 1240))
    #expect(live.queue.sessions.first?.stateSince == 1240)
    #expect(live.queue.sessions.first?.branch == "feat/timer")

    #expect(RelativeAge.format(since: 1000, now: 1005) == "just now")
    #expect(RelativeAge.format(since: 1000, now: 1042) == "42s")
    #expect(RelativeAge.format(since: 1000, now: 1240) == "4m")
    #expect(RelativeAge.format(since: 1000, now: 8200) == "2h")
    #expect(RelativeAge.format(since: 1000, now: 173_800) == "2d")
}

@Test func singleSessionCLISuppressesConcurrentForkedWorkersWhileAllowingSeparateTabsAndDesktopApps() {
    var live = LiveAttention()
    let cliTab1 = HostProcess(pid: 78816, startTime: 100, singleSessionCLI: true)
    let cliTab2 = HostProcess(pid: 93408, startTime: 200, singleSessionCLI: true)
    let desktopApp = HostProcess(pid: 12000, startTime: 50, singleSessionCLI: false)

    // Main coordinator starts in CLI tab 1
    let r1 = live.receive(LiveEvent(source: .agy, sessionID: "main-1", project: "repo",
                                    action: .running, timestamp: 10, hostProcess: cliTab1))
    #expect(r1)
    // Forked swarm worker spawns inside the same active CLI process -> suppressed
    let r2 = live.receive(LiveEvent(source: .agy, sessionID: "forked-worker-1", project: "repo",
                                    action: .running, timestamp: 11, hostProcess: cliTab1))
    #expect(!r2)
    // Worker's later Stop event is also suppressed
    let r3 = live.receive(LiveEvent(source: .agy, sessionID: "forked-worker-1", project: "repo",
                                    action: .finished, timestamp: 15, hostProcess: cliTab1))
    #expect(!r3)

    // Separate CLI tab (different PID) IS a distinct main agent -> accepted
    let r4 = live.receive(LiveEvent(source: .agy, sessionID: "main-2", project: "other",
                                    action: .running, timestamp: 12, hostProcess: cliTab2))
    #expect(r4)

    // Multi-session desktop app allows multiple concurrent main user tabs
    let r5 = live.receive(LiveEvent(source: .codex, sessionID: "desk-tab-1", project: "p1",
                                    action: .running, timestamp: 13, hostProcess: desktopApp))
    let r6 = live.receive(LiveEvent(source: .codex, sessionID: "desk-tab-2", project: "p2",
                                    action: .running, timestamp: 14, hostProcess: desktopApp))
    #expect(r5 && r6)

    #expect(live.queue.sessions.map(\.id.sessionID) == ["main-1", "main-2", "desk-tab-1", "desk-tab-2"])

    // Once CLI tab 1 finishes, starting a /new main conversation in CLI tab 1 IS accepted
    let r7 = live.receive(LiveEvent(source: .agy, sessionID: "main-1", project: "repo",
                                    action: .finished, timestamp: 20, hostProcess: cliTab1))
    let r8 = live.receive(LiveEvent(source: .agy, sessionID: "main-1-new", project: "repo",
                                    action: .running, timestamp: 25, hostProcess: cliTab1))
    #expect(r7 && r8)
    #expect(live.queue.sessions.contains { $0.id.sessionID == "main-1-new" })
}
