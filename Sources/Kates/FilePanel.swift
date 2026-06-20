import AppKit

/// Presents a modal open panel for choosing a kubeconfig file.
/// kubeconfig files conventionally have no extension, so all files are allowed.
@MainActor
func presentKubeconfigOpenPanel() -> URL? {
    let panel = NSOpenPanel()
    panel.title = "Choose Kubeconfig"
    panel.prompt = "Open"
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.showsHiddenFiles = true
    panel.treatsFilePackagesAsDirectories = true
    panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".kube")
    return panel.runModal() == .OK ? panel.url : nil
}

/// Replaces the system pasteboard contents with `text`.
@MainActor
func copyToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}
