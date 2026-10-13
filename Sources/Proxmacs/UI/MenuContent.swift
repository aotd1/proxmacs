import SwiftUI

struct MenuContent: View {
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Proxmacs").font(.headline)
                Spacer()
                Text(state.tartVersion.map { "tart \($0)" } ?? "tart not found")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if state.tart == nil {
                Text("Install Tart (signed build with bridged networking):\nbrew install openai/tools/tart")
                    .font(.caption)
                    .textSelection(.enabled)
            }

            Divider()

            if state.vms.isEmpty {
                Text("No VMs yet").foregroundStyle(.secondary)
            } else {
                ForEach(state.vms) { item in
                    VMRowView(item: item)
                }
            }

            if let status = state.status {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            if let error = state.lastError {
                HStack(alignment: .top) {
                    Text(error).font(.caption).foregroundStyle(.red).lineLimit(5).textSelection(.enabled)
                    Spacer()
                    Button { state.lastError = nil } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                }
            }

            Divider()

            HStack {
                Button("New VM…") {
                    openWindow(id: "new-vm")
                    activateApp()
                }
                .disabled(state.tart == nil)
                Spacer()
                Button {
                    NSWorkspace.shared.open(Paths.support)
                } label: { Image(systemName: "folder") }
                    .help("Open data folder")
                Button("Quit") { NSApp.terminate(nil) }
                    .help("VMs keep running after quitting")
            }
        }
        .padding(12)
        .frame(width: 380)
    }
}
