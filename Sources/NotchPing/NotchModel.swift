import AppKit
import Combine
import NotchCore

enum PingKind: Equatable, Sendable {
    case finished, needsInput, failed
}

@MainActor
final class NotchModel: ObservableObject {
    let demoMode: Bool
    private let originStore: OriginStore?
    private let appActivator: ((String) -> Bool)?
    private var chosenOrigins: [SessionKey: OriginApp] = [:]
    private var live = LiveAttention()
    @Published private(set) var queue = AttentionQueue()
    @Published var geometry = NotchGeometry()
    @Published private(set) var expanded = false
    @Published var forceReducedMotion = false
    @Published private(set) var playing = false
    @Published private(set) var pingTrigger = 0
    @Published private(set) var lastPingKind: PingKind = .finished
    @Published private(set) var hasUnreadAttention = false
    @Published private(set) var navigationStatus: String?
    var layoutChanged: (() -> Void)?
    var requestKeyboardFocus: (() -> Void)?
    private var replayTask: Task<Void, Never>?
    private var hoverTask: Task<Void, Never>?
    private var livenessTask: Task<Void, Never>?
    private var replayID = UUID()
    private var serial = 0
    private var pointerInside = false
    private var hoverSuppressed = false

    init(demoMode: Bool = false, originStore: OriginStore? = nil, appActivator: ((String) -> Bool)? = nil) {
        self.demoMode = demoMode
        self.appActivator = appActivator
        self.originStore = demoMode ? nil : originStore
    }

    func receiveLive(_ event: LiveEvent) {
        guard !demoMode, live.receive(event) else { return }
        queue = live.queue
        switch event.action {
        case .finished:
            hasUnreadAttention = true
            triggerPing(.finished)
        case .needsInput:
            hasUnreadAttention = true
            triggerPing(.needsInput)
        case .failed:
            hasUnreadAttention = true
            triggerPing(.failed)
        case .running, .toolCompleted:
            if queue.waitingCount == 0 && queue.finishedCount == 0 && queue.failedCount == 0 {
                hasUnreadAttention = false
            }
        case .started, .ended:
            break
        }
        settle()
    }

    func markAttentionChecked() {
        guard hasUnreadAttention else { return }
        hasUnreadAttention = false
    }

    func triggerPing(_ kind: PingKind = .finished) {
        lastPingKind = kind
        pingTrigger += 1
    }

    var summary: String {
        var parts: [String] = []
        if queue.workingCount > 0 { parts.append("\(queue.workingCount) working") }
        if queue.waitingCount > 0 { parts.append("\(queue.waitingCount) needs you") }
        if queue.finishedCount > 0 { parts.append("\(queue.finishedCount) finished") }
        if queue.failedCount > 0 { parts.append("\(queue.failedCount) failed") }
        return parts.joined(separator: " · ")
    }

    var headerTitle: String {
        let count = queue.sessions.count
        let attention = queue.waitingCount + queue.finishedCount + queue.failedCount
        if attention == 0 && queue.workingCount > 0 {
            return "\(count) active \(count == 1 ? "session" : "sessions")"
        } else if queue.workingCount == 0 {
            return "\(count) awaiting attention"
        } else {
            return "\(count) sessions (\(attention) awaiting)"
        }
    }

    var dropdownHeight: CGFloat { 40 + min(CGFloat(queue.sessions.count), 5) * 52 + 30 }

    func toggleExpanded() {
        reconcileDeadSessions()
        guard !queue.isEmpty else { return }
        markAttentionChecked()
        if expanded { collapse() }
        else {
            hoverTask?.cancel()
            expanded = true
            layoutChanged?()
            requestKeyboardFocus?()
        }
    }

    func collapse() {
        hoverTask?.cancel()
        expanded = false
        hoverSuppressed = pointerInside
        layoutChanged?()
    }

    func hover(_ inside: Bool) {
        // Mouse monitors can fire frequently. Schedule only when crossing a boundary.
        guard inside != pointerInside else { return }
        pointerInside = inside
        hoverTask?.cancel()
        if inside {
            reconcileDeadSessions()
            markAttentionChecked()
            guard !hoverSuppressed, !queue.isEmpty, !expanded else { return }
            hoverTask = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(35)) }
                catch { return }
                guard let self, self.pointerInside, !self.queue.isEmpty else { return }
                self.expanded = true
                self.layoutChanged?()
            }
        } else {
            hoverSuppressed = false
            hoverTask = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(60)) }
                catch { return }
                self?.expanded = false
                self?.layoutChanged?()
            }
        }
    }

    func addDemo(source: Source, state: AttentionState) {
        guard demoMode else { return }
        stopReplay()
        serial += 1
        let (project, branch): (String, String?) = switch source {
        case .codex: ("notch-ping", "main")
        case .claude: ("website", "feat/auth")
        case .agy: ("infra", "refactor/deploy")
        case .terminal: ("build", nil)
        }
        receive(source: source, id: "demo-\(serial)", project: project, branch: branch, state: state)
    }

    func acknowledge(_ key: SessionKey) {
        stopReplay()
        guard let session = queue.sessions.first(where: { $0.id == key }),
              session.state == .finished || session.state == .failed else { return }
        if !demoMode { live.acknowledge(key) }
        queue.acknowledge(key)
        if queue.waitingCount == 0 && queue.finishedCount == 0 && queue.failedCount == 0 {
            hasUnreadAttention = false
        }
        settle()
    }

    /// Explicit safe recovery action to dismiss any session, including working or needsInput.
    func forceDismiss(_ key: SessionKey) {
        stopReplay()
        if !demoMode { live.acknowledge(key) }
        queue.acknowledge(key)
        if queue.waitingCount == 0 && queue.finishedCount == 0 && queue.failedCount == 0 {
            hasUnreadAttention = false
        }
        settle()
    }

    func resumeOldest() {
        guard demoMode else { return }
        stopReplay()
        guard let session = queue.sessions.first else { return }
        queue.resumed(source: session.id.source, sessionID: session.id.sessionID)
        settle()
    }

    func clearFinished() {
        clearTerminal()
    }

    /// Clears both finished and failed sessions, strictly protecting working and needsInput sessions.
    func clearTerminal() {
        stopReplay()
        live.clearTerminal()
        queue.clearTerminal()
        if queue.waitingCount == 0 && queue.finishedCount == 0 && queue.failedCount == 0 {
            hasUnreadAttention = false
        }
        settle()
    }

    func clear() {
        stopReplay()
        live.clear()
        queue.clear()
        hasUnreadAttention = false
        settle()
    }

    func destination(for session: PendingSession) -> SessionDestination {
        SessionDestination(origin: chosenOrigins[session.id] ?? originStore?.app(for: session.id)
            ?? session.originApp, workspace: session.cmuxWorkspace)
    }

    func chooseOrigin(_ app: OriginApp, for session: PendingSession) {
        chosenOrigins[session.id] = app
        do {
            try originStore?.remember(app, for: session.id)
            activateSession(session)
        } catch {
            navigationStatus = "Could not remember the app. Try again."
        }
    }

    func activateSession(_ session: PendingSession) {
        navigationStatus = nil
        switch destination(for: session) {
        case .unknown:
            navigationStatus = "Right-click this session → Open in…"
        case .app(let app):
            if activateApp(bundleID: app.bundleID) {
                if let liveSession = queue.sessions.first(where: { $0.id == session.id }),
                   liveSession.state == .finished {
                    acknowledge(session.id)
                }
                if expanded { collapse() }
            } else {
                navigationStatus = "\(app.name) is unavailable."
            }
        }
    }

    @discardableResult
    private func activateApp(bundleID: String) -> Bool {
        if let appActivator { return appActivator(bundleID) }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first { !$0.isTerminated }
        let appURL = running?.bundleURL ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        guard running != nil || appURL != nil else { return false }

        if let running {
            running.unhide()
            NSApp.yieldActivation(to: running)
            _ = running.activate(options: [.activateAllWindows])
        }
        if let appURL {
            let conf = NSWorkspace.OpenConfiguration()
            conf.activates = true
            NSWorkspace.shared.openApplication(at: appURL, configuration: conf) { [weak self] _, error in
                guard error != nil else { return }
                Task { @MainActor in self?.navigationStatus = "Could not open the selected app." }
            }
        }
        return true
    }

    /// Reconcile only active Working / Needs-input sessions whose tracked host process has exited.
    /// Terminal Finished / Failed notifications remain visible until checked or dismissed.
    @discardableResult
    func reconcileDeadSessions(isAlive: (HostProcess) -> Bool = ProcessLiveness.isAlive) -> Int {
        guard !demoMode else { return 0 }
        let orphaned = queue.sessions.filter { session in
            guard session.state == .working || session.state == .needsInput,
                  let host = session.hostProcess else { return false }
            return !isAlive(host)
        }
        guard !orphaned.isEmpty else { return 0 }
        for session in orphaned {
            live.acknowledge(session.id)
            queue.acknowledge(session.id)
        }
        settle()
        return orphaned.count
    }

    private func updateLivenessMonitor() {
        let needsMonitor = !demoMode && queue.sessions.contains {
            ($0.state == .working || $0.state == .needsInput) && $0.hostProcess != nil
        }
        if !needsMonitor {
            livenessTask?.cancel()
            livenessTask = nil
            return
        }
        guard livenessTask == nil else { return }
        livenessTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(3)) }
                catch { return }
                guard let self else { return }
                _ = self.reconcileDeadSessions()
            }
        }
    }

    func stopMonitoring() {
        livenessTask?.cancel()
        livenessTask = nil
        hoverTask?.cancel()
        hoverTask = nil
        stopReplay()
    }

    private func receive(source: Source, id: String, project: String, branch: String? = nil,
                         state: AttentionState, cmuxWorkspace: String? = nil,
                         stateSince: Double = Date().timeIntervalSince1970) {
        queue.receive(PendingSession(source: source, sessionID: id, project: project, state: state,
                                     cmuxWorkspace: cmuxWorkspace, branch: branch, stateSince: stateSince))
        switch state {
        case .finished:
            hasUnreadAttention = true
            triggerPing(.finished)
        case .needsInput:
            hasUnreadAttention = true
            triggerPing(.needsInput)
        case .failed:
            hasUnreadAttention = true
            triggerPing(.failed)
        case .working:
            if queue.waitingCount == 0 && queue.finishedCount == 0 && queue.failedCount == 0 {
                hasUnreadAttention = false
            }
        }
        layoutChanged?()
    }

    private func settle() {
        if queue.isEmpty || (queue.waitingCount == 0 && queue.finishedCount == 0 && queue.failedCount == 0) {
            hasUnreadAttention = false
        }
        if queue.isEmpty {
            hoverTask?.cancel()
            expanded = false
        }
        updateLivenessMonitor()
        layoutChanged?()
    }

    func stopReplay() {
        replayID = UUID()
        replayTask?.cancel()
        replayTask = nil
        playing = false
    }

    func playDemo() {
        guard demoMode else { return }
        clear()
        playing = true
        let token = UUID()
        replayID = token
        replayTask = Task { [weak self] in
            for step in 0..<7 {
                do { try await Task.sleep(for: .milliseconds(step == 0 ? 500 : 1100)) }
                catch { return }
                guard let self, self.replayID == token else { return }
                let now = Date().timeIntervalSince1970
                switch step {
                case 0:
                    self.receive(source: .agy, id: "sample-a", project: "notch-ping", branch: "main",
                                 state: .working, stateSince: now - 42)
                case 1:
                    self.receive(source: .claude, id: "sample-b", project: "website", branch: "feat/auth",
                                 state: .needsInput, stateSince: now - 125)
                case 2:
                    self.receive(source: .codex, id: "sample-c", project: "backend", branch: "fix/cache",
                                 state: .finished, stateSince: now)
                case 3:
                    self.receive(source: .terminal, id: "sample-d", project: "build", branch: nil,
                                 state: .failed, stateSince: now)
                case 4:
                    self.queue.resumed(source: .claude, sessionID: "sample-b", now: now)
                    self.settle()
                case 5:
                    self.receive(source: .agy, id: "sample-a", project: "notch-ping", branch: "main",
                                 state: .finished, stateSince: now)
                default:
                    self.receive(source: .claude, id: "sample-b", project: "website", branch: "feat/auth",
                                 state: .finished, stateSince: now)
                }
            }
            if self?.replayID == token { self?.playing = false }
        }
    }
}
