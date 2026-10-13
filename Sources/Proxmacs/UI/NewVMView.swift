import SwiftUI
import UniformTypeIdentifiers

struct NewVMView: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    @State private var name = "debian-1"
    @State private var cpus = 2
    @State private var memoryMB = 2048
    @State private var diskGB = 20
    @State private var bridged = true
    @State private var interface = ""
    @State private var interfaces: [HostInterface] = []
    @State private var useLocalImage = false
    @State private var localImage: URL?
    @State private var password = ""
    @State private var autostart = false
    @State private var startNow = true

    @State private var creating = false
    @State private var error: String?

    private let maxCPUs = ProcessInfo.processInfo.activeProcessorCount
    private let memoryChoices = [1024, 2048, 4096, 8192, 16384]

    var body: some View {
        Form {
            Section("Machine") {
                TextField("Name", text: $name)
                Stepper("CPUs: \(cpus)", value: $cpus, in: 1...maxCPUs)
                Picker("Memory", selection: $memoryMB) {
                    ForEach(memoryChoices, id: \.self) { Text("\($0 / 1024) GB").tag($0) }
                }
                Stepper("Disk: \(diskGB) GB", value: $diskGB, in: 5...1000, step: 5)
            }

            Section("Network") {
                Picker("Mode", selection: $bridged) {
                    Text("Bridged (own LAN IP)").tag(true)
                    Text("NAT (host-only reachable)").tag(false)
                }
                if bridged {
                    Picker("Interface", selection: $interface) {
                        ForEach(interfaces) { Text("\($0.name) (\($0.device))").tag($0.device) }
                    }
                    Text("Use wired Ethernet; Wi-Fi access points often drop bridged traffic.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Image") {
                Picker("Source", selection: $useLocalImage) {
                    Text("Debian 13 arm64 (download)").tag(false)
                    Text("Local .qcow2 / .raw").tag(true)
                }
                if useLocalImage {
                    HStack {
                        Text(localImage?.lastPathComponent ?? "No file selected").foregroundStyle(.secondary)
                        Spacer()
                        Button("Choose…", action: chooseImage)
                    }
                }
            }

            Section("Access") {
                SecureField("Console password for 'debian' (optional)", text: $password)
                Text("SSH keys from ~/.ssh/*.pub are installed for user 'debian'.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Start on login", isOn: $autostart)
                Toggle("Start after creating", isOn: $startNow)
            }

            if let error {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
            }
            if creating, let status = state.status {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(status)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create", action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(creating || name.isEmpty || (useLocalImage && localImage == nil) || (bridged && interface.isEmpty))
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .disabled(creating)
        .task {
            interfaces = await NetworkInterfaces.list()
            if interface.isEmpty {
                let preferred = await NetworkInterfaces.defaultRoute()
                interface = interfaces.first { $0.device == preferred }?.device ?? interfaces.first?.device ?? ""
            }
        }
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "qcow2"), UTType(filenameExtension: "raw"), UTType(filenameExtension: "img")].compactMap { $0 }
        panel.allowsOtherFileTypes = true
        if panel.runModal() == .OK { localImage = panel.url }
    }

    private func create() {
        let request = NewVMRequest(
            name: name.trimmingCharacters(in: .whitespaces),
            cpus: cpus,
            memoryMB: memoryMB,
            diskGB: diskGB,
            network: bridged ? .bridged(interface: interface) : .nat,
            image: useLocalImage ? .local(localImage!) : .debian13,
            password: password,
            autostart: autostart,
            startNow: startNow
        )
        creating = true
        error = nil
        Task {
            do {
                try await state.create(request)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            creating = false
        }
    }
}
