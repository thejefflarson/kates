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
            let showsWide = model.selectedType?.isPod ?? false
            let isNode = model.selectedType?.isNode ?? false
            let isService = model.selectedType?.isService ?? false

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
                // kubectl -o wide extras (pods): node placement and pod IP.
                if showsWide {
                    TableColumn("Node", value: \.node) {
                        Text($0.node).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    .width(min: 90, ideal: 140)
                    TableColumn("IP", value: \.podIP) {
                        Text($0.podIP).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .width(min: 90, ideal: 120)
                }
                // kubectl -o wide extras (nodes).
                if isNode {
                    TableColumn("Internal-IP", value: \.nodeInternalIP) {
                        Text($0.nodeInternalIP).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .width(min: 90, ideal: 120)
                    TableColumn("OS", value: \.nodeOSImage) {
                        Text($0.nodeOSImage).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    .width(min: 100, ideal: 160)
                    TableColumn("Kernel", value: \.nodeKernelVersion) {
                        Text($0.nodeKernelVersion).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    .width(min: 90, ideal: 130)
                    TableColumn("Runtime", value: \.nodeContainerRuntime) {
                        Text($0.nodeContainerRuntime).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    .width(min: 90, ideal: 140)
                }
                // kubectl -o wide extras (services).
                if isService {
                    TableColumn("Type", value: \.serviceType) {
                        Text($0.serviceType).foregroundStyle(.secondary)
                    }
                    .width(min: 80, ideal: 100)
                    TableColumn("Cluster-IP", value: \.serviceClusterIP) {
                        Text($0.serviceClusterIP).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .width(min: 90, ideal: 120)
                    TableColumn("Ports", value: \.servicePorts) {
                        Text($0.servicePorts).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    .width(min: 90, ideal: 150)
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

/// A table row with every sortable/displayable value precomputed once at build
/// time. Sorting compares O(n log n) times, so deriving these lazily from the
/// unstructured object (re-parsing its dictionaries, and formatting dates) on
/// each access made large tables slow to sort — here every field is a stored
/// value the comparators read directly. Missing values sort as -1 / render "—".
struct ResourceRow: Identifiable {
    let id: String
    let name: String
    let age: String
    let sortNamespace: String
    let sortCreated: Date
    let namespaceText: String

    // `kubectl -o wide` pod columns.
    let node: String
    let podIP: String
    // `kubectl -o wide` node columns.
    let nodeInternalIP: String
    let nodeOSImage: String
    let nodeKernelVersion: String
    let nodeContainerRuntime: String
    // `kubectl -o wide` service columns.
    let serviceType: String
    let serviceClusterIP: String
    let servicePorts: String

    let cpuMilli: Int
    let memBytes: Int64
    let cpuText: String
    let memText: String
    let cpuPctReq: Double
    let cpuPctLim: Double
    let memPctReq: Double
    let memPctLim: Double

    // Event fields (kubectl events: LAST SEEN, TYPE, REASON, OBJECT, MESSAGE).
    let eventType: String
    let eventReason: String
    let eventObject: String
    let eventMessage: String
    let sortEventTime: Date
    let lastSeen: String

    init(object: GenericObject, usage: PodUsage?) {
        id = object.id
        name = object.name
        age = object.age
        sortNamespace = object.sortNamespace
        sortCreated = object.sortCreated
        namespaceText = object.namespace ?? "—"

        node = object.nodeName ?? "—"
        podIP = object.podIP ?? "—"
        nodeInternalIP = object.nodeInternalIP ?? "—"
        nodeOSImage = object.nodeOSImage ?? "—"
        nodeKernelVersion = object.nodeKernelVersion ?? "—"
        nodeContainerRuntime = object.nodeContainerRuntime ?? "—"
        serviceType = object.serviceType ?? "—"
        serviceClusterIP = object.serviceClusterIP ?? "—"
        let ports = object.servicePorts
        servicePorts = ports.isEmpty ? "—" : ports

        cpuMilli = usage?.cpuMillicores ?? -1
        memBytes = usage?.memoryBytes ?? -1
        cpuText = usage?.cpuDisplay ?? "—"
        memText = usage?.memoryDisplay ?? "—"
        let have = usage != nil
        let usedCPU = Int64(usage?.cpuMillicores ?? 0)
        let usedMem = usage?.memoryBytes ?? 0
        cpuPctReq = Self.percent(usedCPU, Int64(object.cpuRequestMillicores), have: have)
        cpuPctLim = Self.percent(usedCPU, Int64(object.cpuLimitMillicores), have: have)
        memPctReq = Self.percent(usedMem, object.memoryRequestBytes, have: have)
        memPctLim = Self.percent(usedMem, object.memoryLimitBytes, have: have)

        eventType = object.eventType
        eventReason = object.eventReason
        eventObject = object.eventObject
        eventMessage = object.eventMessage
        let last = object.eventLastTime
        sortEventTime = last ?? .distantPast
        let ageText = shortAge(since: last)
        let count = object.eventCount
        lastSeen = count > 1 ? "\(ageText) (x\(count))" : ageText
    }

    private static func percent(_ used: Int64, _ base: Int64, have: Bool) -> Double {
        guard have, base > 0 else { return -1 }
        return Double(used) / Double(base) * 100
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
