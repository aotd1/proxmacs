import SwiftUI

struct ProxmacsApp: App {
    @State private var state: AppState

    init() {
        let state = AppState()
        _state = State(initialValue: state)
        WebServer.shared.start(state: state)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
                .environment(state)
        } label: {
            Image(systemName: state.vms.contains(where: \.isRunning) ? "server.rack" : "rectangle.stack")
        }
        .menuBarExtraStyle(.window)

        Window("New VM", id: "new-vm") {
            NewVMView()
                .environment(state)
        }
        .windowResizability(.contentSize)

        WindowGroup("Backups", id: "backups", for: String.self) { $name in
            if let name {
                BackupsView(name: name)
                    .environment(state)
            }
        }
        .windowResizability(.contentSize)
    }
}

extension View {
    /// Menubar (LSUIElement) apps must activate explicitly or new windows open behind others.
    func activateApp() {
        NSApp.activate(ignoringOtherApps: true)
    }
}
