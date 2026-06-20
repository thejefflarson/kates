import SwiftUI
import AppKit

@main
struct KatesApp: App {
    @State private var model = AppModel()
    @StateObject private var updater = UpdaterViewModel()

    init() {
        // Ensure the SPM-built executable behaves as a regular foreground app.
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .frame(minWidth: 960, minHeight: 600)
                .task { await model.bootstrap() }
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesCommand(updater: updater)
            }
        }
    }
}
