import Foundation
import Testing
@testable import NotchCore
@testable import NotchPing

@Suite struct SessionNavigationTests {
    @Test func cmuxNeedsOnlyAppIdentity() {
        #expect(SessionDestination(origin: .cmux) == .app(.cmux))
        #expect(SessionDestination(origin: nil, workspace: "legacy-workspace") == .app(.cmux))
        #expect(SessionDestination(origin: .terminal) == .app(.terminal))
        #expect(SessionDestination(origin: nil) == .unknown)
    }

    @Test func processAncestryDoesNotConfuseDaemonWithItsLauncher() {
        #expect(OriginDetector.app(ancestorPaths: ["/bin/zsh",
            "/Applications/cmux.app/Contents/MacOS/cmux"]) == .cmux)
        #expect(OriginDetector.app(ancestorPaths: [
            "/Users/example/.codex/packages/app-server-daemon/releases/version/bin/codex",
            "/Applications/cmux.app/Contents/MacOS/cmux"]) == nil)
        #expect(OriginDetector.app(ancestorPaths: ["/bin/zsh", "/sbin/launchd"]) == nil)
        #expect(OriginDetector.app(ancestorPaths: [
            "/Applications/Claude.app/Contents/MacOS/Claude"]) == .claude)
        #expect(OriginDetector.app(ancestorPaths: [
            "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"]) == .terminal)
    }

    @Test func originsSurviveRestartAndRemainScopedAndExpire() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = SessionKey(source: .codex, sessionID: "../../session")
        let store = OriginStore(directory: directory, lifetime: 100)
        try store.remember(.cmux, for: key, now: 1000)
        let reopened = OriginStore(directory: directory, lifetime: 100)
        #expect(reopened.app(for: key, now: 1001) == .cmux)
        #expect(reopened.app(for: SessionKey(source: .claude, sessionID: key.sessionID), now: 1001) == nil)
        #expect(reopened.app(for: key, now: 1100) == nil)
        #expect(reopened.app(for: key, now: 999) == nil)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        #expect(files.count == 1)
        let mode = try FileManager.default.attributesOfItem(atPath: files[0].path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: files[0])) as! [String: Any]
        #expect(Set(json.keys) == ["app", "timestamp"])
    }

    @Test func originRoundTripsAndSurvivesMetadataFreeEvents() throws {
        let event = LiveEvent(source: .codex, sessionID: "test", project: "test", action: .finished,
            timestamp: 1, originApp: .cmux)
        #expect(try JSONDecoder().decode(LiveEvent.self, from: JSONEncoder().encode(event)) == event)
        var attention = LiveAttention()
        let firstAccepted = attention.receive(event)
        #expect(firstAccepted)
        let secondAccepted = attention.receive(LiveEvent(source: .codex, sessionID: "test", project: "test",
            action: .running, timestamp: 2))
        #expect(secondAccepted)
        #expect(attention.queue.sessions.first?.originApp == .cmux)
    }

    @MainActor @Test func confirmedOriginWorksForAlreadyRunningSessionAndAfterUIRestart() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = OriginStore(directory: directory)
        let session = PendingSession(source: .codex, sessionID: "existing", project: "test", state: .finished)
        var activated: [String] = []
        let model = NotchModel(originStore: store, appActivator: { activated.append($0); return true })
        model.activateSession(session)
        #expect(activated.isEmpty)
        model.chooseOrigin(.cmux, for: session)
        #expect(activated == ["com.cmuxterm.app"])
        let restarted = NotchModel(originStore: store, appActivator: { activated.append($0); return true })
        restarted.activateSession(session)
        #expect(activated == ["com.cmuxterm.app", "com.cmuxterm.app"])
        #expect(restarted.navigationStatus == nil)
    }

    @MainActor @Test func unavailableAppIsVisibleAndDemoDoesNotPersistChoices() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = OriginStore(directory: directory)
        let session = PendingSession(source: .codex, sessionID: "demo", project: "test",
            state: .finished, originApp: .cmux)
        let model = NotchModel(demoMode: true, originStore: store, appActivator: { _ in false })
        model.chooseOrigin(.cmux, for: session)
        #expect(model.navigationStatus == "cmux is unavailable.")
        #expect(store.app(for: session.id) == nil)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test func sysctlProcessInfoReadsRealAncestryAndHostProcessDetectionSkipsShells() {
        let info = OriginDetector.processInfo(pid: getpid())
        #expect(info != nil)
        #expect((info?.ppid ?? 0) > 0)
        #expect((info?.startTime ?? 0) > 0)
        #expect(ProcessLiveness.isAlive(HostProcess(pid: getpid(), startTime: info!.startTime)))
        #expect(!ProcessLiveness.isAlive(HostProcess(pid: getpid(), startTime: info!.startTime + 1)))

        let ancestors: [OriginDetector.Ancestor] = [
            .init(pid: 500, startTime: 10, path: "/bin/sh"),
            .init(pid: 499, startTime: 9, path: "/Users/example/.local/share/claude/versions/2.1.312"),
            .init(pid: 498, startTime: 8, path: "/usr/bin/login"),
            .init(pid: 497, startTime: 7, path: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal")
        ]
        #expect(OriginDetector.app(ancestorPaths: ancestors.map(\.path)) == .terminal)
        #expect(OriginDetector.hostProcess(ancestors: ancestors) == HostProcess(pid: 499, startTime: 9, singleSessionCLI: true))

        let desktopAncestors: [OriginDetector.Ancestor] = [
            .init(pid: 601, startTime: 20, path: "/Applications/Antigravity.app/Contents/MacOS/Antigravity")
        ]
        #expect(OriginDetector.hostProcess(ancestors: desktopAncestors) == HostProcess(pid: 601, startTime: 20, singleSessionCLI: false))
    }

    @MainActor @Test func deadHostProcessReconcilesActiveSessionWhilePreservingFinished() {
        let model = NotchModel()
        let deadHost = HostProcess(pid: 999_999, startTime: 1)
        model.receiveLive(LiveEvent(source: .agy, sessionID: "dead-working", project: "proj",
                                    action: .running, timestamp: 1, hostProcess: deadHost))
        model.receiveLive(LiveEvent(source: .agy, sessionID: "done-exited", project: "proj",
                                    action: .finished, timestamp: 2, hostProcess: deadHost))
        #expect(model.queue.sessions.count == 2)

        let removed = model.reconcileDeadSessions(isAlive: { _ in false })
        #expect(removed == 1)
        #expect(model.queue.workingCount == 0)
        #expect(model.queue.finishedCount == 1)
        #expect(model.queue.sessions.first?.id.sessionID == "done-exited")
        model.stopMonitoring()
    }

    @MainActor @Test func failureArrivalTriggersUnreadAttentionAndPing() {
        let model = NotchModel()
        let before = model.pingTrigger
        model.receiveLive(LiveEvent(source: .claude, sessionID: "err-1", project: "proj", action: .failed, timestamp: 1))
        #expect(model.hasUnreadAttention)
        #expect(model.pingTrigger == before + 1)
        #expect(model.lastPingKind == .failed)

        model.receiveLive(LiveEvent(source: .claude, sessionID: "wait-1", project: "proj", action: .needsInput, timestamp: 2))
        #expect(model.lastPingKind == .needsInput)

        model.receiveLive(LiveEvent(source: .claude, sessionID: "done-1", project: "proj", action: .finished, timestamp: 3))
        #expect(model.lastPingKind == .finished)
    }

    @MainActor @Test func clickingFinishedSessionAutoClearsItWhileKeepingActiveAndFailed() throws {
        var activated: [String] = []
        let model = NotchModel(appActivator: { activated.append($0); return true })
        model.receiveLive(LiveEvent(source: .codex, sessionID: "done", project: "p1",
                                    action: .finished, timestamp: 10, originApp: .terminal))
        model.receiveLive(LiveEvent(source: .claude, sessionID: "waiting", project: "p2",
                                    action: .needsInput, timestamp: 11, originApp: .cmux))
        model.receiveLive(LiveEvent(source: .agy, sessionID: "working", project: "p3",
                                    action: .running, timestamp: 12, originApp: .antigravity))
        model.receiveLive(LiveEvent(source: .codex, sessionID: "failed", project: "p4",
                                    action: .failed, timestamp: 13, originApp: .codex))
        #expect(model.queue.sessions.count == 4)

        // Clicking Finished opens its app AND auto-clears only that Finished entry
        let finishedSession = try #require(model.queue.sessions.first { $0.id.sessionID == "done" })
        model.activateSession(finishedSession)
        #expect(activated == ["com.apple.Terminal"])
        #expect(!model.queue.sessions.contains { $0.id.sessionID == "done" })
        #expect(model.queue.sessions.count == 3)

        // Clicking Needs you, Working, or Failed opens their apps without auto-clearing them
        for id in ["waiting", "working", "failed"] {
            let s = try #require(model.queue.sessions.first { $0.id.sessionID == id })
            model.activateSession(s)
        }
        #expect(model.queue.sessions.count == 3)
        model.stopMonitoring()
    }

    @MainActor @Test func unavailableOrUnknownFinishedSessionIsNotAutoClearedUntilOpened() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = OriginStore(directory: directory)

        // 1. Unknown origin click does not discard Finished entry; choosing origin opens & clears it
        var allowOpen = false
        let model = NotchModel(originStore: store, appActivator: { _ in allowOpen })
        model.receiveLive(LiveEvent(source: .codex, sessionID: "unknown-done", project: "proj",
                                    action: .finished, timestamp: 1))
        let unknown = try #require(model.queue.sessions.first)
        model.activateSession(unknown)
        #expect(model.queue.sessions.count == 1)

        // 2. Unavailable app does not discard Finished entry
        model.chooseOrigin(.cmux, for: unknown)
        #expect(model.navigationStatus == "cmux is unavailable.")
        #expect(model.queue.sessions.count == 1)

        // 3. Once app opens successfully, Finished entry auto-clears
        allowOpen = true
        model.activateSession(unknown)
        #expect(model.queue.isEmpty)
    }
}
