import SwiftUI

struct BackupsView: View {
    @Environment(AppState.self) private var state
    let name: String

    @State private var backups: [BackupInfo] = []
    @State private var policy = BackupPolicy()

    private var item: VMItem? { state.vms.first { $0.name == name } }
    private var busy: Bool { state.activity[name] != nil }

    var body: some View {
        Form {
            Section("Schedule") {
                Toggle("Daily backup", isOn: $policy.daily)
                Stepper("At \(policy.hour):00", value: $policy.hour, in: 0...23)
                    .disabled(!policy.daily)
                Stepper("Keep last \(policy.keep)", value: $policy.keep, in: 1...50)
                Text("Backups are instant APFS clones on this Mac's disk. They protect against mistakes inside the VM, not against losing this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                if backups.isEmpty {
                    Text("No backups yet").foregroundStyle(.secondary)
                }
                ForEach(backups) { backup in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(backup.record.date.formatted(date: .abbreviated, time: .standard))
                            Text(backup.record.consistent ? "filesystem-consistent" : "crash-consistent")
                                .font(.caption)
                                .foregroundStyle(backup.record.consistent ? Color.secondary : Color.orange)
                        }
                        Spacer()
                        Button("Restore") { confirmRestore(backup) }
                            .disabled(item?.isRunning != false || busy)
                            .help(item?.isRunning == true ? "Stop the VM first" : "Replace the VM's disk with this backup")
                        Button(role: .destructive) {
                            try? BackupManager.delete(backup)
                            reload()
                        } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                }
            } header: {
                HStack {
                    Text("Backups")
                    Spacer()
                    if let activity = state.activity[name] {
                        ProgressView().controlSize(.small)
                        Text(activity)
                    }
                    Button("Back Up Now") {
                        Task {
                            await state.backup(name)
                            reload()
                        }
                    }
                    .disabled(busy)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .frame(minHeight: 360)
        .navigationTitle("Backups — \(name)")
        .onAppear {
            policy = VMMeta.load(name)?.backup ?? BackupPolicy()
            reload()
        }
        .onChange(of: policy) { _, newValue in
            state.setBackupPolicy(name, newValue)
        }
        .onChange(of: state.activity[name]) { _, _ in reload() }
    }

    private func reload() {
        backups = BackupManager.list(name)
    }

    private func confirmRestore(_ backup: BackupInfo) {
        let alert = NSAlert()
        alert.messageText = "Restore \(name)?"
        alert.informativeText = "The VM's current disk will be replaced by the backup from \(backup.record.date.formatted()). Changes since then are lost."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Restore")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            Task {
                await state.restore(name, backup)
                reload()
            }
        }
    }
}
