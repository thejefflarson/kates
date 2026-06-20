import SwiftUI
import KubeKit

struct ResourceListView: View {
    @Environment(AppModel.self) private var model
    @State private var sortOrder = [KeyPathComparator(\ResourceRow.name)]

    var body: some View {
        @Bindable var model = model

        Group {
            if model.service == nil {
                ContentUnavailableView {
                    Label("Not connected", systemImage: "bolt.horizontal.circle")
                } description: {
                    Text(model.contexts.isEmpty
                         ? "Choose a kubeconfig file to connect to a cluster."
                         : "Pick a context to connect to a cluster.")
                } actions: {
                    Button("Open Kubeconfig…") {
                        if let url = presentKubeconfigOpenPanel() {
                            Task { await model.chooseKubeconfig(url) }
                        }
                    }
                }
            } else if model.selectedObject == nil {
                // Nothing open: table fills the whole pane.
                table
            } else {
                // A resource is open: table shrinks, detail appears below.
                VSplitView {
                    table
                        .frame(minHeight: 140, idealHeight: 240)
                    DetailView()
                        .frame(minHeight: 240, idealHeight: 380)
                }
            }
        }
        .navigationTitle(model.selectedType?.kind ?? "Resources")
        .navigationSubtitle(subtitle)
        .onChange(of: model.selectedTypeID) {
            // Events default to newest-first; everything else to name.
            sortOrder = (model.selectedType?.isEvent ?? false)
                ? [KeyPathComparator(\ResourceRow.sortEventTime, order: .reverse)]
                : [KeyPathComparator(\ResourceRow.name)]
        }
    }

    private var subtitle: String {
        guard let ctx = model.selectedContextName else { return "" }
        guard model.selectedType?.namespaced ?? false else { return ctx }
        let ns = model.isAllNamespaces ? "all namespaces" : model.selectedNamespace
        return "\(ctx) · \(ns)"
    }

    @ViewBuilder
    private var table: some View {
        @Bindable var model = model

        if model.objects.isEmpty, let err = model.listError {
            ContentUnavailableView {
                Label("Couldn’t load", systemImage: "exclamationmark.triangle")
            } description: {
                Text(err)
            } actions: {
                Button("Retry") { Task { await model.refresh() } }
            }
        } else if model.objects.isEmpty {
            ContentUnavailableView("No \(model.selectedType?.displayName ?? "resources")",
                                   systemImage: "tray",
                                   description: Text(emptyDescription))
        } else if model.selectedType?.isEvent ?? false {
            let rows = model.objects
                .map { ResourceRow(object: $0, usage: nil) }
                .sorted(using: sortOrder)
            Table(rows, selection: $model.selectedResourceID, sortOrder: $sortOrder) {
                TableColumn("Last Seen", value: \.sortEventTime) {
                    Text($0.lastSeen).foregroundStyle(.secondary).monospacedDigit()
                }
                .width(min: 80, ideal: 110)
                TableColumn("Type", value: \.eventType) { StatusBadge(text: $0.eventType) }
                    .width(min: 70, ideal: 84)
                TableColumn("Reason", value: \.eventReason) { Text($0.eventReason) }
                    .width(min: 120, ideal: 170)
                TableColumn("Object", value: \.eventObject) {
                    Text($0.eventObject).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                .width(min: 140, ideal: 200)
                TableColumn("Message", value: \.eventMessage) {
                    Text($0.eventMessage).lineLimit(2).textSelection(.enabled)
                }
                .width(min: 220, ideal: 420)
            }
        } else {
            let rows = model.objects
                .map { ResourceRow(object: $0, usage: model.usage[$0.name]) }
                .sorted(using: sortOrder)
            let showsNamespace = model.selectedType?.namespaced ?? false
            let showsUsage = model.selectedType?.hasMetrics ?? false
            let showsPercents = model.selectedType?.isPod ?? false

            Table(rows, selection: $model.selectedResourceID, sortOrder: $sortOrder) {
                TableColumn("Name", value: \.name) { Text($0.name).fontWeight(.medium) }
                    .width(min: 160, ideal: 240)
                if showsNamespace {
                    TableColumn("Namespace", value: \.sortNamespace) {
                        Text($0.namespaceText).foregroundStyle(.secondary)
                    }
                    .width(min: 90, ideal: 120)
                }
                if showsUsage {
                    TableColumn("CPU", value: \.cpuMilli) {
                        Text($0.cpuText).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .width(min: 56, ideal: 64)
                    TableColumn("Memory", value: \.memBytes) {
                        Text($0.memText).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .width(min: 64, ideal: 76)
                }
                if showsPercents {
                    TableColumn("CPU/req", value: \.cpuPctReq) { PercentCell($0.cpuPctReq) }
                        .width(min: 64, ideal: 72)
                    TableColumn("CPU/lim", value: \.cpuPctLim) { PercentCell($0.cpuPctLim) }
                        .width(min: 64, ideal: 72)
                    TableColumn("Mem/req", value: \.memPctReq) { PercentCell($0.memPctReq) }
                        .width(min: 64, ideal: 72)
                    TableColumn("Mem/lim", value: \.memPctLim) { PercentCell($0.memPctLim) }
                        .width(min: 64, ideal: 72)
                }
                TableColumn("Age", value: \.sortCreated) {
                    Text($0.age).foregroundStyle(.secondary).monospacedDigit()
                }
                .width(min: 48, ideal: 56)
            }
        }
    }

    private var emptyDescription: String {
        guard model.selectedType?.namespaced ?? false else { return "No objects of this type." }
        return model.isAllNamespaces ? "None in any namespace." : "Nothing in “\(model.selectedNamespace)”."
    }
}

/// A table row carrying both the object and its (optional) usage, so every
/// column — including CPU/memory and request/limit percentages — is sortable.
/// Missing values sort as -1 (and render as "—").
struct ResourceRow: Identifiable {
    let object: GenericObject
    let usage: PodUsage?

    var id: String { object.id }
    var name: String { object.name }
    var age: String { object.age }
    var sortNamespace: String { object.sortNamespace }
    var sortCreated: Date { object.sortCreated }
    var namespaceText: String { object.namespace ?? "—" }

    var cpuMilli: Int { usage?.cpuMillicores ?? -1 }
    var memBytes: Int64 { usage?.memoryBytes ?? -1 }
    var cpuText: String { usage?.cpuDisplay ?? "—" }
    var memText: String { usage?.memoryDisplay ?? "—" }

    var cpuPctReq: Double { percent(Int64(usage?.cpuMillicores ?? 0), Int64(object.cpuRequestMillicores), have: usage != nil) }
    var cpuPctLim: Double { percent(Int64(usage?.cpuMillicores ?? 0), Int64(object.cpuLimitMillicores), have: usage != nil) }
    var memPctReq: Double { percent(usage?.memoryBytes ?? 0, object.memoryRequestBytes, have: usage != nil) }
    var memPctLim: Double { percent(usage?.memoryBytes ?? 0, object.memoryLimitBytes, have: usage != nil) }

    private func percent(_ used: Int64, _ base: Int64, have: Bool) -> Double {
        guard have, base > 0 else { return -1 }
        return Double(used) / Double(base) * 100
    }

    // Event fields (kubectl events: LAST SEEN, TYPE, REASON, OBJECT, MESSAGE).
    var eventType: String { object.eventType }
    var eventReason: String { object.eventReason }
    var eventObject: String { object.eventObject }
    var eventMessage: String { object.eventMessage }
    var sortEventTime: Date { object.eventLastTime ?? .distantPast }
    var lastSeen: String {
        let age = shortAge(since: object.eventLastTime)
        return object.eventCount > 1 ? "\(age) (x\(object.eventCount))" : age
    }
}

/// Renders a percentage (or "—" when unset); >100% is highlighted red.
struct PercentCell: View {
    let value: Double
    init(_ value: Double) { self.value = value }

    var body: some View {
        if value < 0 {
            Text("—").foregroundStyle(.secondary)
        } else {
            Text("\(Int(value.rounded()))%")
                .monospacedDigit()
                .foregroundStyle(value > 100 ? .red : .secondary)
        }
    }
}
