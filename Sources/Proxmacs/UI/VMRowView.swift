import SwiftUI

struct VMRowView: View {
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow
    let item: VMItem

    private var activity: String? { state.activity[item.name] }

    private var stateColor: Color {
        switch item.state {
        case "running": .green
        case "stopped": .secondary
        case "missing": .red
        default: .orange
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(stateColor).frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).fontWeight(.medium)
                HStack(spacing: 6) {
                    Text(item.meta.network.label)
                    if let ip = item.ip {
                        Button(ip) { state.copySSHCommand(item) }
                            .buttonStyle(.link)
                            .help("Copy ssh debian@\(ip)")
                    } else if item.isRunning {
                        Text("waiting for IP…")
                    }
                    if let activity {
                        ProgressView().controlSize(.mini)
                        Text(activity)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            if item.isRunning {
                Button { Task { await state.stop(item.name) } } label: { Image(systemName: "stop.fill") }
                    .help("Shut down")
            } else {
                Button { Task { await state.start(item.name) } } label: { Image(systemName: "play.fill") }
                    .help("Start")
                    .disabled(item.state == "missing")
            }

            Menu {
                Button("Open Console") { state.openConsole(item.name) }
                    .disabled(!item.isRunning)
                Button("Copy SSH Command") { state.copySSHCommand(item) }
                    .disabled(item.ip == nil)
                Divider()
                Button("Back Up Now") { Task { await state.backup(item.name) } }
                Button("Backups…") {
                    openWindow(id: "backups", value: item.name)
                    activateApp()
                }
                Divider()
                Toggle("Start on Login", isOn: Binding(
                    get: { item.meta.autostart },
                    set: { value in Task { await state.setAutostart(item.name, value) } }
                ))
                Divider()
                Button("Delete…", role: .destructive) { confirmDelete() }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .buttonStyle(.borderless)
        .disabled(activity != nil)
    }

    private func confirmDelete() {
        let alert = NSAlert()
        alert.messageText = "Delete \(item.name)?"
        alert.informativeText = "The VM and its disk will be removed. Backups are kept in the data folder."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        activateApp()
        if alert.runModal() == .alertFirstButtonReturn {
            Task { await state.delete(item.name) }
        }
    }
}
