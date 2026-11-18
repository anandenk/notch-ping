import Foundation
import NotchCore

@main
enum Relay {
    static func main() {
        let timestamp = Date().timeIntervalSince1970
        let args = CommandLine.arguments
        if args.count == 5, args[1] == "remember-origin",
           let source = Source(rawValue: args[2]), !args[3].isEmpty,
           args[3].utf8.count <= 256, let app = OriginApp(rawValue: args[4]) {
            do {
                try OriginStore().remember(app, for: SessionKey(source: source, sessionID: args[3]))
                print("Remembered session app: " + app.name)
            } catch {
                FileHandle.standardError.write(Data("Could not save session app.\n".utf8))
                exit(1)
            }
            return
        }
        guard args.count >= 3, args[1] == "hook", let source = Source(rawValue: args[2]),
              source != .terminal else {
            FileHandle.standardError.write(Data("Usage: notch-relay hook codex|claude|agy [event]\n".utf8))
            return
        }
        let eventOverride = args.count > 3 ? args[3] : nil
        let processContext = OriginDetector.inspectCurrentProcess()
        let detected = processContext.app
        let hostProcess = processContext.host
        // Environment from a shared daemon may belong to its original launcher.
        // Only forward legacy cmux context when process ancestry confirms cmux.
        let cmuxWorkspace = detected == .cmux ? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"] : nil
        let cmuxSurface = detected == .cmux ? ProcessInfo.processInfo.environment["CMUX_SURFACE_ID"] : nil

        // All hook paths are advisory. No policy decisions, context, or error output.
        defer {
            if source == .agy && eventOverride == "PreToolUse" {
                print("{\"decision\":\"allow\"}")
            } else {
                print("{}")
            }
        }
        var payload = Data()
        while let chunk = try? FileHandle.standardInput.read(upToCount: 16384), !chunk.isEmpty {
            payload.append(chunk)
            if payload.count > 1_048_576 { return }
        }
        guard let event = HookAdapter.event(source: source, payload: payload, timestamp: timestamp,
                                            eventOverride: eventOverride, cmuxWorkspace: cmuxWorkspace,
                                            cmuxSurface: cmuxSurface),
              event.valid else { return }
        let key = SessionKey(source: source, sessionID: event.sessionID)
        let store = OriginStore()
        // Persist even when the UI is closed, including idle SessionStart.
        if let detected { try? store.remember(detected, for: key) }
        let origin = detected ?? store.app(for: key)
        let routedEvent = LiveEvent(source: event.source, sessionID: event.sessionID,
            project: event.project, action: event.action, timestamp: event.timestamp,
            cmuxWorkspace: event.cmuxWorkspace, cmuxSurface: event.cmuxSurface,
            originApp: origin, hostProcess: hostProcess, branch: event.branch)
        guard let data = try? JSONEncoder().encode(routedEvent) else { return }
        LocalSocket.send(data)
    }
}
