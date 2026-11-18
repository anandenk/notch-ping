import AppKit
import NotchCore
import SwiftUI

@MainActor
private enum SourceIcons {
    // Reuse installed application icons without copying proprietary artwork into this repo.
    static let images: [Source: NSImage] = {
        var result: [Source: NSImage] = [:]
        for (source, bundleID) in [(Source.codex, "com.openai.codex"), (.claude, "com.anthropic.claudefordesktop"), (.agy, "com.google.antigravity")] {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                result[source] = NSWorkspace.shared.icon(forFile: url.path)
            }
        }
        return result
    }()
}

struct SourceMark: View {
    let source: Source

    var body: some View {
        Group {
            if let image = SourceIcons.images[source] {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                Image(systemName: source == .codex ? "chevron.left.forwardslash.chevron.right" : source == .claude ? "asterisk" : source == .agy ? "atom" : "terminal")
                    .resizable().scaledToFit().padding(1)
                    .foregroundStyle(Theme.primary)
            }
        }
        .frame(width: 16, height: 16)
        .accessibilityHidden(true)
    }
}

/// Native rendering of the supplied Lucide Bot SVG (24×24 viewBox).
/// Source and ISC notice: ThirdParty/Lucide/.
private struct BotMark: Shape {
    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 24
        // Restore the original optical alignment within the circular halo.
        let origin = CGPoint(x: rect.midX - 12 * scale, y: rect.midY - 13.8 * scale)
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: origin.x + x * scale, y: origin.y + y * scale)
        }
        var path = Path()
        path.move(to: point(12, 8))
        path.addLine(to: point(12, 4))
        path.addLine(to: point(8, 4))
        path.addRoundedRect(in: CGRect(x: origin.x + 4 * scale, y: origin.y + 8 * scale,
                                      width: 16 * scale, height: 12 * scale),
                            cornerSize: CGSize(width: 2 * scale, height: 2 * scale))
        for (x1, y1, x2, y2): (CGFloat, CGFloat, CGFloat, CGFloat) in [
            (2, 14, 4, 14), (20, 14, 22, 14), (15, 13, 15, 15), (9, 13, 9, 15)
        ] {
            path.move(to: point(x1, y1))
            path.addLine(to: point(x2, y2))
        }
        return path
    }
}

/// Smooth GPU-driven orbiting progress arc shown only while at least one session is actively Working.
private struct WorkingOrbitHalo: View {
    let reduced: Bool
    @State private var spinning = false

    var body: some View {
        if reduced {
            Circle()
                .stroke(Theme.working.opacity(0.72), style: StrokeStyle(lineWidth: 1.35, lineCap: .round, dash: [2.5, 3.0]))
                .frame(width: 16, height: 16)
                .scaleEffect(1.32)
        } else {
            ZStack {
                Circle()
                    .stroke(Theme.working.opacity(0.16), lineWidth: 1.2)
                Circle()
                    .trim(from: 0.0, to: 0.28)
                    .stroke(Theme.working, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .rotationEffect(.degrees(spinning ? 360 : 0))
            }
            .frame(width: 16, height: 16)
            .scaleEffect(1.32)
            .onAppear {
                spinning = false
                withAnimation(.linear(duration: 1.35).repeatForever(autoreverses: false)) {
                    spinning = true
                }
            }
        }
    }
}

/// Outward-radiating GPU-driven beacon wave shown when an agent is blocked waiting on user input.
private struct WaitingBeaconHalo: View {
    @State private var pulsing = false

    var body: some View {
        Circle()
            .stroke(Theme.waiting.opacity(pulsing ? 0.0 : 0.8), lineWidth: 1.5)
            .frame(width: 16, height: 16)
            .scaleEffect(pulsing ? 1.56 : 1.02)
            .onAppear {
                pulsing = false
                withAnimation(.easeOut(duration: 1.45).repeatForever(autoreverses: false)) {
                    pulsing = true
                }
            }
    }
}

/// Compact GPU-driven spinner used inside expanded dropdown rows for Working sessions.
private struct InlineWorkingSpinner: View {
    let active: Bool
    let reduced: Bool
    @State private var spinning = false

    var body: some View {
        if reduced || !active {
            Circle()
                .stroke(Theme.working.opacity(0.85), style: StrokeStyle(lineWidth: 1.3, lineCap: .round, dash: [2.0, 2.2]))
                .frame(width: 10, height: 10)
        } else {
            ZStack {
                Circle()
                    .stroke(Theme.working.opacity(0.22), lineWidth: 1.2)
                Circle()
                    .trim(from: 0.0, to: 0.32)
                    .stroke(Theme.working, style: StrokeStyle(lineWidth: 1.35, lineCap: .round))
                    .rotationEffect(.degrees(spinning ? 360 : 0))
            }
            .frame(width: 10, height: 10)
            .onAppear {
                spinning = false
                withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) {
                    spinning = true
                }
            }
        }
    }
}

/// The menu-bar band stays transparent, except for the small Bot status icon.
/// The details have a constant width and reveal only downward, below that band.
struct NotchView: View {
    @ObservedObject var model: NotchModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pingScale: CGFloat = 1.0
    @State private var pingRotation: Double = 0.0
    @State private var pingShakeX: CGFloat = 0.0
    @State private var pingRingScale: CGFloat = 0.8
    @State private var pingRingOpacity: Double = 0.0
    @State private var pingShadowRadius: CGFloat = 0.0
    @State private var isBreathing = false

    private var reduced: Bool { reduceMotion || model.forceReducedMotion }
    private var motion: Animation { reduced ? Theme.reducedMotion : model.expanded ? Theme.spring : Theme.collapse }
    private var indicatorColor: Color {
        if model.queue.waitingCount > 0 { return Theme.waiting }
        if model.queue.failedCount > 0 { return Theme.failure }
        if model.queue.finishedCount > 0 { return Theme.ready }
        return Theme.working
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .top) {
                if !model.queue.isEmpty {
                    Button { model.toggleExpanded() } label: {
                        ZStack {
                            Circle()
                                .stroke(indicatorColor.opacity(pingRingOpacity), lineWidth: 1.5)
                                .scaleEffect(pingRingScale)
                                .frame(width: 16, height: 16)

                            if model.queue.workingCount > 0 {
                                WorkingOrbitHalo(reduced: reduced)
                            }

                            if model.queue.waitingCount > 0 {
                                if model.hasUnreadAttention && !reduced {
                                    WaitingBeaconHalo()
                                } else {
                                    Circle()
                                        .fill(Theme.waiting)
                                        .frame(width: 4.5, height: 4.5)
                                        .overlay(Circle().stroke(Theme.surface, lineWidth: 1.1))
                                        .offset(x: 7.5, y: -7.5)
                                }
                            } else if model.hasUnreadAttention {
                                Circle()
                                    .stroke(indicatorColor.opacity(reduced ? 0.45 : (isBreathing ? 0.72 : 0.16)), lineWidth: 1.5)
                                    .scaleEffect(reduced ? 1.22 : (isBreathing ? 1.38 : 1.05))
                                    .frame(width: 16, height: 16)
                            }

                            BotMark()
                                .stroke(indicatorColor, style: StrokeStyle(lineWidth: 4.0 / 3.0, lineCap: .round, lineJoin: .round))
                                .frame(width: 16, height: 16)
                                .scaleEffect(pingScale * (reduced ? 1.0 : (model.hasUnreadAttention && model.queue.waitingCount == 0 && isBreathing ? 1.09 : 1.0)))
                                .rotationEffect(.degrees(pingRotation))
                                .offset(x: pingShakeX)
                                .shadow(color: indicatorColor.opacity(pingShadowRadius > 0 ? 0.9 : (model.hasUnreadAttention && isBreathing ? 0.65 : 0)),
                                        radius: max(pingShadowRadius, model.hasUnreadAttention && isBreathing ? 4.5 : 0))
                        }
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Notch Ping, \(model.summary). \(model.expanded ? "Hide" : "Show") sessions")
                    .position(x: proxy.size.width / 2 + model.geometry.width / 2 + Theme.indicatorOffset,
                              y: model.geometry.height / 2)
                    .transition(.opacity)

                    details
                        .frame(width: Theme.detailsWidth, height: model.dropdownHeight, alignment: .top)
                        .frame(height: model.expanded ? model.dropdownHeight : 0, alignment: .top)
                        .background(Theme.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .opacity(model.expanded ? 1 : 0)
                        .shadow(color: model.expanded ? Theme.shadow : .clear, radius: 10, y: 4)
                        .offset(y: model.geometry.height + Theme.dropdownGap)
                        .allowsHitTesting(model.expanded)
                        .accessibilityHidden(!model.expanded)
                        .animation(motion, value: model.queue)
                        .animation(motion, value: model.expanded)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
        }
        .onExitCommand { model.collapse() }
        .onChange(of: model.pingTrigger) { playArrivalAnimation(for: model.lastPingKind) }
        .onChange(of: model.hasUnreadAttention) { syncBreathing() }
        .onChange(of: model.queue.waitingCount) { syncBreathing() }
        .onChange(of: reduced) { syncBreathing() }
        .onAppear { syncBreathing() }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
    }

    private func playArrivalAnimation(for kind: PingKind) {
        guard !reduced else { return }
        pingRingScale = 0.88
        pingRingOpacity = 0.88
        pingShadowRadius = 6

        switch kind {
        case .finished:
            withAnimation(.easeOut(duration: 0.38)) {
                pingRingScale = 1.65
                pingRingOpacity = 0.0
            }
            withAnimation(.spring(duration: 0.24, bounce: 0.42)) {
                pingScale = 1.24
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                withAnimation(.spring(duration: 0.26, bounce: 0.25)) {
                    pingScale = 1.0
                    pingShadowRadius = 0
                }
            }

        case .needsInput:
            // Friendly double-ripple + gentle wave to signal "Needs you".
            withAnimation(.easeOut(duration: 0.34)) {
                pingRingScale = 1.65
                pingRingOpacity = 0.0
            }
            withAnimation(.spring(duration: 0.16, bounce: 0.35)) {
                pingScale = 1.18
                pingRotation = 11
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.13) {
                withAnimation(.spring(duration: 0.16, bounce: 0.35)) {
                    pingRotation = -9
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.26) {
                pingRingScale = 0.94
                pingRingOpacity = 0.65
                withAnimation(.easeOut(duration: 0.32)) {
                    pingRingScale = 1.52
                    pingRingOpacity = 0.0
                }
                withAnimation(.spring(duration: 0.16, bounce: 0.3)) {
                    pingRotation = 5
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.42) {
                withAnimation(.spring(duration: 0.2, bounce: 0.2)) {
                    pingScale = 1.0
                    pingRotation = 0
                    pingShadowRadius = 0
                }
            }

        case .failed:
            // Crisp horizontal shake + alert flash for failures.
            withAnimation(.easeOut(duration: 0.32)) {
                pingRingScale = 1.55
                pingRingOpacity = 0.0
            }
            withAnimation(.linear(duration: 0.06)) { pingShakeX = -3.5 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                withAnimation(.linear(duration: 0.07)) { pingShakeX = 3.5 }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.13) {
                withAnimation(.linear(duration: 0.07)) { pingShakeX = -2.2 }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) {
                withAnimation(.linear(duration: 0.06)) { pingShakeX = 1.2 }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.26) {
                withAnimation(.easeOut(duration: 0.12)) {
                    pingShakeX = 0
                    pingScale = 1.0
                    pingShadowRadius = 0
                }
            }
        }
    }

    private func syncBreathing() {
        if model.hasUnreadAttention && model.queue.waitingCount == 0 && !reduced {
            withAnimation(.easeInOut(duration: 0.95).repeatForever(autoreverses: true)) {
                isBreathing = true
            }
        } else {
            withAnimation(.easeOut(duration: 0.2)) {
                isBreathing = false
            }
        }
    }

    private var clearActionTitle: String {
        let hasActive = model.queue.workingCount > 0 || model.queue.waitingCount > 0
        if hasActive {
            if model.queue.finishedCount > 0 && model.queue.failedCount > 0 {
                return "Clear completed"
            } else if model.queue.failedCount > 0 {
                return "Clear failed"
            } else {
                return "Clear finished"
            }
        } else {
            return "Clear all"
        }
    }

    private var terminalCount: Int {
        model.queue.finishedCount + model.queue.failedCount
    }

    private var details: some View {
        TimelineView(.animation(minimumInterval: 15.0, paused: !model.expanded)) { context in
            let now = context.date.timeIntervalSince1970
            VStack(spacing: 0) {
                HStack {
                    Text(model.headerTitle).font(Theme.label)
                    Spacer()
                    Button(clearActionTitle) {
                        model.clearTerminal()
                    }
                    .font(Theme.detail).buttonStyle(.plain)
                    .foregroundStyle(terminalCount > 0 ? Theme.secondary : Theme.secondary.opacity(0.35))
                    .disabled(terminalCount == 0)
                }
                .padding(.horizontal, 18)
                .frame(height: 40)

                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.queue.sessions) { session in
                            SessionRow(
                                session: session,
                                now: now,
                                dropdownExpanded: model.expanded,
                                reducedMotion: reduced,
                                needsOriginChoice: model.destination(for: session) == .unknown,
                                select: { model.activateSession(session) },
                                dismiss: { model.acknowledge(session.id) },
                                forceDismiss: { model.forceDismiss(session.id) },
                                chooseOrigin: { model.chooseOrigin($0, for: session) }
                            )
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .frame(height: min(CGFloat(model.queue.sessions.count), 5) * 52)

                Text(model.navigationStatus ?? (model.demoMode ? "Simulated sessions" : "Live sessions"))
                    .font(Theme.detail).foregroundStyle(Theme.secondary)
                    .lineLimit(2)
                    .help(model.navigationStatus ?? "Session status")
                    .frame(height: 30)
            }
            .foregroundStyle(Theme.primary)
        }
    }
}

@MainActor
private final class OriginMenuTarget: NSObject {
    let app: OriginApp
    let handler: (OriginApp) -> Void

    init(app: OriginApp, handler: @escaping (OriginApp) -> Void) {
        self.app = app
        self.handler = handler
    }

    @objc func pick() {
        handler(app)
    }
}

private struct SessionRow: View {
    let session: PendingSession
    let now: Double
    let dropdownExpanded: Bool
    let reducedMotion: Bool
    var needsOriginChoice = false
    let select: () -> Void
    let dismiss: () -> Void
    var forceDismiss: (() -> Void)? = nil
    var chooseOrigin: ((OriginApp) -> Void)? = nil
    @State private var hovered = false

    private var stateColor: Color {
        switch session.state {
        case .working: Theme.working
        case .finished: Theme.ready
        case .needsInput: Theme.waiting
        case .failed: Theme.failure
        }
    }

    private var subtitleText: String {
        var parts: [String] = [session.id.source.name]
        if let branch = session.branch, !branch.isEmpty {
            parts.append(branch)
        }
        parts.append(RelativeAge.format(since: session.stateSince, now: now))
        if needsOriginChoice {
            parts.append("Open in…")
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var stateIcon: some View {
        switch session.state {
        case .working:
            InlineWorkingSpinner(active: dropdownExpanded, reduced: reducedMotion)
        case .needsInput:
            Image(systemName: "questionmark.circle.fill")
                .font(.system(size: 10.5, weight: .semibold))
        case .finished:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 10.5, weight: .semibold))
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10.5, weight: .semibold))
        }
    }

    @MainActor
    private func handleRowClick() {
        select()
        guard needsOriginChoice, let chooseOrigin,
              let currentEvent = NSApp.currentEvent,
              currentEvent.type == .leftMouseUp || currentEvent.type == .leftMouseDown else { return }
        let menu = NSMenu(title: "Open in…")
        let header = NSMenuItem(title: "Open in…", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())
        var targets: [OriginMenuTarget] = []
        for app in OriginApp.allCases {
            let target = OriginMenuTarget(app: app, handler: chooseOrigin)
            targets.append(target)
            let item = NSMenuItem(title: app.name, action: #selector(OriginMenuTarget.pick), keyEquivalent: "")
            item.target = target
            menu.addItem(item)
        }
        withExtendedLifetime(targets) {
            _ = menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
    }

    private var rowHelpText: String {
        let idSuffix = String(session.id.sessionID.suffix(8))
        if needsOriginChoice {
            return "Choose which app owns \(session.project) (\(session.id.source.name) · \(idSuffix))"
        } else if session.state == .finished {
            return "Open \(session.project) (\(session.id.source.name) · \(idSuffix)) and clear notification"
        } else {
            return "Open the app for \(session.project) (\(session.id.source.name) · \(idSuffix))"
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: handleRowClick) {
                HStack(spacing: 12) {
                    SourceMark(source: session.id.source)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(session.project).font(Theme.label).lineLimit(1)
                        Text(subtitleText)
                            .font(Theme.detail).foregroundStyle(Theme.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    HStack(spacing: 5) {
                        stateIcon
                        Text(session.state.label).font(Theme.detail)
                    }
                    .foregroundStyle(stateColor)
                    .fixedSize()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(rowHelpText)

            if session.state == .finished || session.state == .failed {
                Button(action: dismiss) {
                    Image(systemName: "xmark").font(Theme.detail).frame(width: 28, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.secondary)
                .help("Dismiss \(session.project)")
                .accessibilityLabel("Dismiss \(session.id.source.name) \(session.project) \(session.id.sessionID)")
            } else {
                Color.clear.frame(width: 28, height: 32)
            }
        }
        .padding(.leading, 18).padding(.trailing, 12)
        .frame(height: 52)
        .background(hovered ? Theme.rowHover : Theme.surface)
        .onHover { hovered = $0 }
        .contextMenu {
            if let chooseOrigin {
                Menu("Open in…") {
                    ForEach(OriginApp.allCases, id: \.self) { app in
                        Button(app.name) { chooseOrigin(app) }
                    }
                }
                Divider()
            }
            if session.state == .finished || session.state == .failed {
                Button("Dismiss Session") { dismiss() }
            } else if let force = forceDismiss {
                Button("Dismiss Session (Force)") { force() }
            }
        }
        .accessibilityElement(children: .contain)
    }
}
