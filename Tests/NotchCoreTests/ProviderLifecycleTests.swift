import Foundation
import Testing
@testable import NotchCore
@testable import NotchPing

@Test func agyBackgroundWorkRemainsWorkingUntilFullyIdle() throws {
    let payload = try JSONSerialization.data(withJSONObject: [
        "conversationId": "bg-work",
        "workspacePaths": ["/tmp/project"],
        "terminationReason": "model_stop",
        "fullyIdle": false
    ])
    let event = HookAdapter.event(source: .agy, payload: payload, timestamp: 1, eventOverride: "Stop")
    #expect(event?.action != .finished)
    #expect(event?.action == .running)
}

@Test func agyErrorReasonWithoutMessageReportsFailed() throws {
    let payload = try JSONSerialization.data(withJSONObject: [
        "conversationId": "err-stop",
        "workspacePaths": ["/tmp/project"],
        "terminationReason": "error",
        "fullyIdle": true,
        "error": ""
    ])
    let event = HookAdapter.event(source: .agy, payload: payload, timestamp: 1, eventOverride: "Stop")
    #expect(event?.action == .failed)
}

@MainActor @Test func failedSessionIsDismissible() {
    let model = NotchModel()
    model.receiveLive(LiveEvent(source: .claude, sessionID: "failed-turn", project: "project", action: .failed))
    model.acknowledge(SessionKey(source: .claude, sessionID: "failed-turn"))
    #expect(model.queue.isEmpty)
}

@MainActor @Test func staleWorkingSessionCanBeExplicitlyRecovered() {
    let model = NotchModel()
    let key = SessionKey(source: .claude, sessionID: "orphan")
    model.receiveLive(LiveEvent(source: .claude, sessionID: key.sessionID, project: "project", action: .running))
    model.acknowledge(key)
    #expect(model.queue.sessions.count == 1)
    model.forceDismiss(key)
    #expect(model.queue.isEmpty)
}

@MainActor @Test func codexWithoutOriginShowsStatusInsteadOfOpeningDesktop() {
    let model = NotchModel()
    model.activateSession(PendingSession(source: .codex, sessionID: "unknown-origin",
        project: "project", state: .finished))
    #expect(model.navigationStatus == "Right-click this session → Open in…")
}
