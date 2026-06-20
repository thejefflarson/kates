import SwiftUI
import KubeKit

/// Embedded log pane shown beside pod details. On selection it tails the last
/// few lines and follows live; the user can toggle following or load the full log.
struct LogPane: View {
    @Environment(AppModel.self) private var model
    let object: GenericObject

    private static let tailCount = 10

    @State private var selectedContainer: String?
    @State private var follow = true
    @State private var fullLog = false
    @State private var lines: [String] = []
    @State private var failure: String?
    @State private var loading = false

    private var containers: [String] { object.containerNames }
    private var effectiveContainer: String? { selectedContainer ?? containers.first }

    // Re-runs the log task whenever any of these change.
    private var streamKey: String {
        "\(object.id)|\(effectiveContainer ?? "")|\(follow)|\(fullLog)"
    }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            logScroll
        }
        .task(id: streamKey) { await load() }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Label("Logs", systemImage: "text.alignleft").font(.headline)

            if containers.count > 1 {
                Picker("Container", selection: $selectedContainer) {
                    ForEach(containers, id: \.self) { Text($0).tag(Optional($0)) }
                }
                .labelsHidden().frame(maxWidth: 180)
            }

            Spacer()

            if loading { ProgressView().controlSize(.small) }
            Toggle("Follow", isOn: $follow)
                .toggleStyle(.switch).controlSize(.small)
                .onChange(of: follow) { _, on in if on { fullLog = false } }
            Button("Full logs") { fullLog = true; follow = false }
                .disabled(fullLog && !follow)
            Button {
                copyToPasteboard(copyText)
            } label: { Image(systemName: "doc.on.doc") }
                .help("Copy logs").disabled(lines.isEmpty && failure == nil)
        }
        .padding(8)
    }

    private var logScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { idx, line in
                        Text(line)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(idx)
                    }
                    if let failure {
                        Text(failure)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.red).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(8)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .onChange(of: lines.count) { _, count in
                if follow, count > 0 { proxy.scrollTo(count - 1, anchor: .bottom) }
            }
        }
    }

    private var copyText: String {
        var text = lines.joined(separator: "\n")
        if let failure { text += (text.isEmpty ? "" : "\n") + failure }
        return text
    }

    private func load() async {
        lines = []
        failure = nil

        if follow {
            do {
                for try await chunk in model.logStream(for: object, container: effectiveContainer,
                                                        tailLines: Self.tailCount) {
                    let newLines = chunk.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                    lines.append(contentsOf: newLines)
                }
            } catch is CancellationError {
                // expected on container switch / deselect
            } catch {
                failure = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            }
        } else {
            loading = true
            let text = await model.fetchLogs(for: object, container: effectiveContainer,
                                             tailLines: fullLog ? nil : Self.tailCount)
            loading = false
            lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        }
    }
}
