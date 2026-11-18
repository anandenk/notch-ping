import Testing
@testable import NotchCore
@testable import NotchPing

@Test func repeatedEventDoesNotIncreaseCount() {
    var queue = AttentionQueue()
    queue.receive(PendingSession(source: .codex, sessionID: "a", project: "project", state: .finished))
    queue.receive(PendingSession(source: .codex, sessionID: "a", project: "project", state: .needsInput))
    #expect(queue.count(for: .codex) == 1)
    #expect(queue.needsInput(for: .codex))
    #expect(queue.finishedCount == 0)
}

@Test func sourcesCanUseTheSameSessionID() {
    var queue = AttentionQueue()
    for source in Source.allCases {
        queue.receive(PendingSession(source: source, sessionID: "same", project: "project", state: .finished))
    }
    #expect(queue.sessions.count == Source.allCases.count)
    queue.acknowledge(SessionKey(source: .codex, sessionID: "same"))
    #expect(queue.sources == [.claude, .agy, .terminal])
}

@Test func resumingSetsWorkingState() {
    var queue = AttentionQueue()
    queue.receive(PendingSession(source: .codex, sessionID: "a", project: "project", state: .finished))
    queue.resumed(source: .codex, sessionID: "a")
    #expect(queue.workingCount == 1)
    #expect(queue.sessions.first?.state == .working)
}

@Test func dismissingOnlyRemovesTargetSession() {
    var queue = AttentionQueue()
    queue.receive(PendingSession(source: .codex, sessionID: "a", project: "project", state: .finished))
    queue.receive(PendingSession(source: .codex, sessionID: "b", project: "project", state: .finished))
    queue.acknowledge(SessionKey(source: .codex, sessionID: "a"))
    #expect(queue.count(for: .codex) == 1)
    #expect(queue.sessions.first?.id.sessionID == "b")
    queue.acknowledge(SessionKey(source: .codex, sessionID: "b"))
    #expect(queue.isEmpty)
}

@Test func waitingAndFailuresRemainSeparateFromFinished() {
    var queue = AttentionQueue()
    queue.receive(PendingSession(source: .claude, sessionID: "a", project: "project", state: .needsInput))
    queue.receive(PendingSession(source: .terminal, sessionID: "b", project: "build", state: .failed))
    #expect(queue.waitingCount == 1)
    #expect(queue.failedCount == 1)
    #expect(queue.finishedCount == 0)
    #expect(queue.hasFailure(for: .terminal))
    queue.clear()
    #expect(queue.sources.isEmpty)
}

@Test func clearFinishedOnlyRemovesFinishedSessions() {
    var queue = AttentionQueue()
    queue.receive(PendingSession(source: .codex, sessionID: "a", project: "project", state: .finished))
    queue.receive(PendingSession(source: .codex, sessionID: "b", project: "project", state: .working))
    queue.receive(PendingSession(source: .codex, sessionID: "c", project: "project", state: .needsInput))
    queue.clearFinished()
    #expect(queue.count(for: .codex) == 2)
    #expect(queue.sessions.map(\.id.sessionID) == ["b", "c"])
    #expect(queue.finishedCount == 0)
    #expect(queue.workingCount == 1)
    #expect(queue.waitingCount == 1)
}

@Test func clearTerminalClearsBothFinishedAndFailedPreservingActive() {
    var queue = AttentionQueue()
    queue.receive(PendingSession(source: .codex, sessionID: "finished", project: "p1", state: .finished))
    queue.receive(PendingSession(source: .codex, sessionID: "failed", project: "p2", state: .failed))
    queue.receive(PendingSession(source: .claude, sessionID: "working", project: "p3", state: .working))
    queue.receive(PendingSession(source: .agy, sessionID: "needsInput", project: "p4", state: .needsInput))

    queue.clearTerminal()

    #expect(queue.sessions.count == 2)
    #expect(queue.finishedCount == 0)
    #expect(queue.failedCount == 0)
    #expect(queue.workingCount == 1)
    #expect(queue.waitingCount == 1)
    #expect(queue.sessions.map(\.id.sessionID).sorted() == ["needsInput", "working"])
}

@MainActor @Test func failedSessionsCanBeDismissedIndividually() {
    let model = NotchModel()
    model.receiveLive(LiveEvent(source: .terminal, sessionID: "term-fail", project: "build", action: .failed))
    #expect(model.queue.failedCount == 1)

    model.acknowledge(SessionKey(source: .terminal, sessionID: "term-fail"))
    #expect(model.queue.isEmpty)
}

@MainActor @Test func workingAndNeedsInputSessionsAreProtectedFromAccidentalDismissal() {
    let model = NotchModel()
    model.receiveLive(LiveEvent(source: .codex, sessionID: "sess-work", project: "proj", action: .running))
    model.receiveLive(LiveEvent(source: .claude, sessionID: "sess-wait", project: "proj", action: .needsInput))

    // Ordinary acknowledge does not dismiss working or needsInput
    model.acknowledge(SessionKey(source: .codex, sessionID: "sess-work"))
    model.acknowledge(SessionKey(source: .claude, sessionID: "sess-wait"))
    #expect(model.queue.workingCount == 1)
    #expect(model.queue.waitingCount == 1)

    // Explicit forceDismiss recovers the session
    model.forceDismiss(SessionKey(source: .codex, sessionID: "sess-work"))
    #expect(model.queue.workingCount == 0)
    #expect(model.queue.waitingCount == 1)

    model.forceDismiss(SessionKey(source: .claude, sessionID: "sess-wait"))
    #expect(model.queue.isEmpty)
}
