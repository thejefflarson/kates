import SwiftUI
import KubeKit

struct ResourceListView: View {
    @Environment(AppModel.self) private var model
    @State private var filterText = ""

    /// Objects matching the filter (name/namespace, plus event fields for the
    /// events view). Empty filter = everything.
    private var filteredObjects: [GenericObject] {
        let q = filterText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return model.objects }
        return model.objects.filter { o in
            o.name.localizedCaseInsensitiveContains(q)
                || (o.namespace?.localizedCaseInsensitiveContains(q) ?? false)
                || o.eventReason.localizedCaseInsensitiveContains(q)
                || o.eventObject.localizedCaseInsensitiveContains(q)
                || o.eventMessage.localizedCaseInsensitiveContains(q)
        }
    }

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
            } else {
                // Keep the table in one stable position (always the first child
                // of this VSplitView) and add the detail below only when a row is
                // selected. Moving the table between if-branches would make
                // SwiftUI recreate the NSViewRepresentable — a new coordinator
                // that loses the current sort on the first selection.
                VSplitView {
                    table
                        .frame(minHeight: 140, maxHeight: .infinity)
                    if model.selectedObject != nil {
                        DetailView()
                            .frame(minHeight: 240, idealHeight: 380)
                    }
                }
            }
        }
        // This is a data view — never animate. SwiftUI otherwise animates the
        // row reorder on sort (which read as ~1s of lag), row insert/remove on
        // filter, and the table growing on type/selection change. Snap instead.
        .transaction { $0.animation = nil }
        .searchable(text: $filterText, placement: .automatic, prompt: "Filter by name")
        .navigationTitle(model.selectedType?.kind ?? "Resources")
        .navigationSubtitle(subtitle)
        .onChange(of: model.selectedTypeID) {
            filterText = ""   // a filter for one type rarely applies to the next
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
        } else if model.objects.isEmpty && model.isLoading {
            // Type/namespace switch in flight — spinner beats a "No X" flash.
            ProgressView().controlSize(.large).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.objects.isEmpty {
            ContentUnavailableView("No \(model.selectedType?.displayName ?? "resources")",
                                   systemImage: "tray",
                                   description: Text(emptyDescription))
        } else if filteredObjects.isEmpty {
            ContentUnavailableView.search(text: filterText)
        } else if model.selectedType?.isEvent ?? false {
            let rows = filteredObjects.map { ResourceRow(object: $0, usage: nil) }
            ResourceTableView(rows: rows, columns: Self.eventColumns,
                              selection: $model.selectedResourceID, defaultDescending: true)
        } else {
            let rows = filteredObjects.map { ResourceRow(object: $0, usage: model.usage[$0.name]) }
            ResourceTableView(rows: rows, columns: genericColumns(for: model.selectedType),
                              selection: $model.selectedResourceID)
        }
    }

    // MARK: - Column definitions (native table)

    private static let secondary = NSColor.secondaryLabelColor

    private func genericColumns(for type: APIResourceType?) -> [RowColumn] {
        var cols: [RowColumn] = [
            RowColumn(id: "name", title: "Name", width: 240, bold: true,
                      text: { $0.name }, color: { _ in .labelColor },
                      less: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }),
        ]
        if type?.namespaced ?? false {
            cols.append(RowColumn(id: "namespace", title: "Namespace", width: 120,
                text: { $0.namespaceText },
                less: { $0.sortNamespace.localizedStandardCompare($1.sortNamespace) == .orderedAscending }))
        }
        if type?.hasMetrics ?? false {
            cols.append(RowColumn(id: "cpu", title: "CPU", width: 64, mono: true,
                text: { $0.cpuText }, less: { $0.cpuMilli < $1.cpuMilli }))
            cols.append(RowColumn(id: "memory", title: "Memory", width: 76, mono: true,
                text: { $0.memText }, less: { $0.memBytes < $1.memBytes }))
        }
        if type?.isPod ?? false {
            cols.append(pctColumn(id: "cpureq", title: "CPU/req", value: { $0.cpuPctReq }))
            cols.append(pctColumn(id: "cpulim", title: "CPU/lim", value: { $0.cpuPctLim }))
            cols.append(pctColumn(id: "memreq", title: "Mem/req", value: { $0.memPctReq }))
            cols.append(pctColumn(id: "memlim", title: "Mem/lim", value: { $0.memPctLim }))
            cols.append(RowColumn(id: "node", title: "Node", width: 140,
                text: { $0.node },
                less: { $0.node.localizedStandardCompare($1.node) == .orderedAscending }))
            cols.append(RowColumn(id: "ip", title: "IP", width: 120, mono: true,
                text: { $0.podIP },
                less: { $0.podIP.localizedStandardCompare($1.podIP) == .orderedAscending }))
        }
        if type?.isNode ?? false {
            cols.append(RowColumn(id: "internalip", title: "Internal-IP", width: 120, mono: true,
                text: { $0.nodeInternalIP },
                less: { $0.nodeInternalIP.localizedStandardCompare($1.nodeInternalIP) == .orderedAscending }))
            cols.append(RowColumn(id: "os", title: "OS", width: 160,
                text: { $0.nodeOSImage },
                less: { $0.nodeOSImage.localizedStandardCompare($1.nodeOSImage) == .orderedAscending }))
            cols.append(RowColumn(id: "kernel", title: "Kernel", width: 130,
                text: { $0.nodeKernelVersion },
                less: { $0.nodeKernelVersion.localizedStandardCompare($1.nodeKernelVersion) == .orderedAscending }))
            cols.append(RowColumn(id: "runtime", title: "Runtime", width: 140,
                text: { $0.nodeContainerRuntime },
                less: { $0.nodeContainerRuntime.localizedStandardCompare($1.nodeContainerRuntime) == .orderedAscending }))
        }
        if type?.isService ?? false {
            cols.append(RowColumn(id: "svctype", title: "Type", width: 100,
                text: { $0.serviceType },
                less: { $0.serviceType.localizedStandardCompare($1.serviceType) == .orderedAscending }))
            cols.append(RowColumn(id: "clusterip", title: "Cluster-IP", width: 120, mono: true,
                text: { $0.serviceClusterIP },
                less: { $0.serviceClusterIP.localizedStandardCompare($1.serviceClusterIP) == .orderedAscending }))
            cols.append(RowColumn(id: "ports", title: "Ports", width: 150,
                text: { $0.servicePorts },
                less: { $0.servicePorts.localizedStandardCompare($1.servicePorts) == .orderedAscending }))
        }
        cols.append(RowColumn(id: "age", title: "Age", width: 60, mono: true,
            text: { $0.age }, less: { $0.sortCreated < $1.sortCreated }))
        return cols
    }

    private func pctColumn(id: String, title: String, value: @escaping (ResourceRow) -> Double) -> RowColumn {
        RowColumn(id: id, title: title, width: 72, mono: true,
                  text: { value($0) < 0 ? "—" : "\(Int(value($0).rounded()))%" },
                  color: { value($0) > 100 ? .systemRed : Self.secondary },
                  less: { value($0) < value($1) })
    }

    private static let eventColumns: [RowColumn] = [
        RowColumn(id: "lastseen", title: "Last Seen", width: 110, mono: true,
                  text: { $0.lastSeen }, less: { $0.sortEventTime < $1.sortEventTime }),
        RowColumn(id: "type", title: "Type", width: 84,
                  text: { $0.eventType },
                  color: { switch $0.eventType {
                      case "Warning": return .systemOrange
                      case "Normal": return .systemGreen
                      default: return secondary } },
                  less: { $0.eventType.localizedStandardCompare($1.eventType) == .orderedAscending }),
        RowColumn(id: "reason", title: "Reason", width: 170, text: { $0.eventReason },
                  color: { _ in .labelColor },
                  less: { $0.eventReason.localizedStandardCompare($1.eventReason) == .orderedAscending }),
        RowColumn(id: "eobject", title: "Object", width: 200, text: { $0.eventObject },
                  less: { $0.eventObject.localizedStandardCompare($1.eventObject) == .orderedAscending }),
        RowColumn(id: "message", title: "Message", width: 420, text: { $0.eventMessage },
                  color: { _ in .labelColor },
                  less: { $0.eventMessage.localizedStandardCompare($1.eventMessage) == .orderedAscending }),
    ]

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
struct ResourceRow: Identifiable, Equatable, Hashable {
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
