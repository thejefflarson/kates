import Combine
import Sparkle
import SwiftUI

/// Wraps Sparkle's updater so SwiftUI can drive "Check for Updates…" and keep
/// the menu item enabled/disabled in step with Sparkle's own state.
@MainActor
final class UpdaterViewModel: ObservableObject {
    @Published private(set) var canCheckForUpdates = false
    private let controller: SPUStandardUpdaterController

    init() {
        // Starts the updater; it reads SUFeedURL / SUPublicEDKey from Info.plist
        // and performs scheduled background checks on its own.
        controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }
}

/// The "Check for Updates…" menu command (added under the app menu).
struct CheckForUpdatesCommand: View {
    @ObservedObject var updater: UpdaterViewModel

    var body: some View {
        Button("Check for Updates…") { updater.checkForUpdates() }
            .disabled(!updater.canCheckForUpdates)
    }
}
