import SwiftUI
import NotchCore

struct DemoControls: View {
    @ObservedObject var model: NotchModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Try the notch").font(.system(size: 22, weight: .semibold))
                Text("Simulated events only. Your actual sessions are untouched.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button(model.playing ? "Restart demo" : "Play 8-second demo") { model.playDemo() }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                if model.playing {
                    Button("Stop") { model.stopReplay() }.controlSize(.large)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Or add a session").font(.headline)
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                    GridRow {
                        Button("Codex finished") { model.addDemo(source: .codex, state: .finished) }
                        Button("Claude needs input") { model.addDemo(source: .claude, state: .needsInput) }
                    }
                    GridRow {
                        Button("Claude finished") { model.addDemo(source: .claude, state: .finished) }
                        Button("Antigravity finished") { model.addDemo(source: .agy, state: .finished) }
                    }
                    GridRow {
                        Button("Antigravity working") { model.addDemo(source: .agy, state: .working) }
                        Button("Command failed") { model.addDemo(source: .terminal, state: .failed) }
                    }
                }
                .buttonStyle(.bordered)
            }

            HStack {
                Button("Resume oldest") { model.resumeOldest() }.disabled(model.queue.isEmpty)
                Button("Clear completed") { model.clearTerminal() }
                    .disabled(model.queue.finishedCount + model.queue.failedCount == 0)
                Spacer()
                Text("\(model.queue.sessions.count) pending").monospacedDigit().foregroundStyle(.secondary)
            }

            Toggle("Preview reduced motion", isOn: $model.forceReducedMotion)
                .toggleStyle(.checkbox)

            Text("A small Bot icon appears beside the notch. Hover near it to drop down the session details; move away to close. You can also click the Bot icon. The menu bar stays clear.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(24).frame(width: 424)
    }
}
