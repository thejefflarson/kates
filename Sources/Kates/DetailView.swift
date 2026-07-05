import SwiftUI
import KubeKit

/// A small colored status pill (Running/Pending/Failed/…).
struct StatusBadge: View {
    let text: String

    private var color: Color {
        switch text {
        case "Running", "Active", "Succeeded", "Completed", "Normal": return .green
        case "Pending", "ContainerCreating", "Terminating", "Waiting", "Warning": return .orange
        case "Failed", "Error", "CrashLoopBackOff", "Terminated", "Unknown": return .red
        default: return .secondary
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).lineLimit(1)
        }
    }
}

struct DetailView: View {
    @Environment(AppModel.self) private var model

    @State private var confirmDelete = false
    @State private var replicasText = ""
    @State private var nodePodSort: NodePodSort = .name
    @State private var nodePodSortAsc = true

    enum NodePodSort { case name, namespace, cpu, mem, age }

    var body: some View {
        Group {
            if let obj = model.selectedObject {
                detail(for: obj)
            } else {
                ContentUnavailableView("Nothing selected", systemImage: "rectangle.split.1x2",
                                       description: Text("Select a resource to see details."))
            }
        }
        // .task(id:) runs on first appearance AND on every selection change,
        // so YAML shows even on the first selection (onChange would skip it).
        .task(id: model.selectedResourceID) {
            model.updateDetail()
            replicasText = model.selectedObject?.specReplicas.map(String.init) ?? ""
            if let obj = model.selectedObject { await model.loadEvents(for: obj) }
        }
    }

    @ViewBuilder
    private func detail(for obj: GenericObject) -> some View {
        let type = model.selectedType

        Group {
            if type?.isPod ?? false {
                // Pods: info on the left, a live log pane on the right.
                HSplitView {
                    info(obj, type: type).frame(minWidth: 320)
                    LogPane(object: obj).frame(minWidth: 340)
                }
            } else {
                info(obj, type: type)
            }
        }
        .confirmationDialog("Delete pod “\(obj.name)”?",
                            isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { Task { await model.deleteSelectedPod() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The pod will be deleted. A controller may recreate it.")
        }
    }

    @ViewBuilder
    private func info(_ obj: GenericObject, type: APIResourceType?) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header(obj)
                keyValues(metadata(for: obj, type: type))
                labelsSection(obj)

                if type?.isPod ?? false {
                    containersSection(obj)
                    Button(role: .destructive) { confirmDelete = true } label: {
                        Label("Delete Pod", systemImage: "trash")
                    }
                }
                if type?.isDeployment ?? false {
                    scaleControl(obj)
                }
                if type?.isNode ?? false {
                    nodePodsSection(obj)
                }
                conditionsSection(obj)
                eventsSection
                yamlSection
            }
            .padding()
        }
    }

    private func metadata(for obj: GenericObject, type: APIResourceType?) -> [(String, String)] {
        var pairs: [(String, String)] = [("Kind", obj.kind)]
        if let ns = obj.namespace { pairs.append(("Namespace", ns)) }
        if type?.hasMetrics ?? false {
            pairs.append(("CPU", model.usage[obj.name]?.cpuDisplay ?? "—"))
            pairs.append(("Memory", model.usage[obj.name]?.memoryDisplay ?? "—"))
        }
        pairs.append(("Age", obj.age))
        return pairs
    }

    // MARK: - Containers

    @ViewBuilder
    private func containersSection(_ obj: GenericObject) -> some View {
        let containers = obj.containers
        if !containers.isEmpty {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(containers) { c in
                        HStack(spacing: 8) {
                            StatusBadge(text: c.state)
                                .frame(width: 130, alignment: .leading)
                            Text(c.ready ? "ready" : "not ready")
                                .foregroundStyle(c.ready ? .green : .secondary)
                                .frame(width: 70, alignment: .leading)
                            Text("↺ \(c.restarts)").monospacedDigit().foregroundStyle(.secondary)
                            Spacer()
                            Text(c.image).font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        }
                    }
                }
                .padding(.top, 4)
            } label: {
                Text("Containers (\(containers.count))").font(.headline)
            }
        }
    }

    @ViewBuilder
    private func nodePodsSection(_ obj: GenericObject) -> some View {
        DisclosureGroup {
            VStack(spacing: 0) {
                nodePodHeader
                Divider()
                if model.nodePods.isEmpty {
                    Text("No pods scheduled here.")
                        .foregroundStyle(.secondary).font(.caption)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
                }
                ForEach(sortedNodePods) { pod in
                    let u = model.nodePodUsage[pod.name]
                    podRow(name: pod.name, ns: pod.namespace ?? "—",
                           cpu: u?.cpuDisplay ?? "—", mem: u?.memoryDisplay ?? "—",
                           age: shortAge(since: pod.createdAt), header: false)
                }
            }
            .padding(.top, 4)
        } label: {
            Text("Pods (\(model.nodePods.count))").font(.headline)
        }
        .task(id: obj.id) { await model.loadNodePods(obj.name) }
    }

    private var sortedNodePods: [GenericObject] {
        let asc = nodePodSortAsc
        func by<T: Comparable>(_ key: (GenericObject) -> T) -> [GenericObject] {
            model.nodePods.sorted { asc ? key($0) < key($1) : key($0) > key($1) }
        }
        switch nodePodSort {
        case .name: return by { $0.name }
        case .namespace: return by { $0.namespace ?? "" }
        case .cpu: return by { model.nodePodUsage[$0.name]?.cpuMillicores ?? -1 }
        case .mem: return by { model.nodePodUsage[$0.name]?.memoryBytes ?? -1 }
        case .age: return by { $0.sortCreated }
        }
    }

    private func toggleNodePodSort(_ field: NodePodSort) {
        if nodePodSort == field { nodePodSortAsc.toggle() }
        else { nodePodSort = field; nodePodSortAsc = true }
    }

    private var nodePodHeader: some View {
        HStack(spacing: 10) {
            sortHeader("Name", .name, width: nil).frame(maxWidth: .infinity, alignment: .leading)
            sortHeader("Namespace", .namespace, width: 110)
            sortHeader("CPU", .cpu, width: 56)
            sortHeader("Memory", .mem, width: 64)
            sortHeader("Age", .age, width: 44)
        }
        .padding(.vertical, 2)
    }

    private func sortHeader(_ title: String, _ field: NodePodSort, width: CGFloat?) -> some View {
        Button { toggleNodePodSort(field) } label: {
            HStack(spacing: 2) {
                Text(title).font(.caption.weight(.semibold))
                if nodePodSort == field {
                    Image(systemName: nodePodSortAsc ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8))
                }
            }
            .foregroundStyle(.secondary)
            .frame(width: width, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// One row of the node's pods mini-table, mirroring the main pods columns.
    private func podRow(name: String, ns: String, cpu: String, mem: String,
                        age: String, header: Bool) -> some View {
        HStack(spacing: 10) {
            cell(name, width: nil, header: header, dim: header)
                .frame(maxWidth: .infinity, alignment: .leading)
            cell(ns, width: 110, header: header, dim: true)
            cell(cpu, width: 56, header: header, dim: true, mono: true)
            cell(mem, width: 64, header: header, dim: true, mono: true)
            cell(age, width: 44, header: header, dim: true, mono: true)
        }
        .padding(.vertical, 2)
    }

    private func cell(_ text: String, width: CGFloat?, header: Bool, dim: Bool, mono: Bool = false) -> some View {
        Text(text)
            .font(header ? .caption.weight(.semibold) : (mono ? .body.monospacedDigit() : .body))
            .foregroundStyle(dim ? Color.secondary : Color.primary)
            .lineLimit(1).truncationMode(.middle)
            .frame(width: width, alignment: .leading)
    }

    // MARK: - Describe (labels, conditions, events)

    @ViewBuilder
    private func labelsSection(_ obj: GenericObject) -> some View {
        let labels = obj.labels.sorted { $0.key < $1.key }
        if !labels.isEmpty {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(labels, id: \.key) { key, value in
                        HStack(spacing: 6) {
                            Text(key).foregroundStyle(.secondary)
                            Text(value).textSelection(.enabled)
                        }
                        .font(.caption)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.top, 4)
            } label: { Text("Labels (\(labels.count))").font(.headline) }
        }
    }

    @ViewBuilder
    private func conditionsSection(_ obj: GenericObject) -> some View {
        let conditions = obj.conditions
        if !conditions.isEmpty {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(conditions) { c in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(c.status == "True" ? Color.green
                                          : (c.status == "False" ? Color.red : Color.secondary))
                                    .frame(width: 7, height: 7)
                                Text(c.type).fontWeight(.medium)
                                if !c.reason.isEmpty {
                                    Text(c.reason).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            if !c.message.isEmpty {
                                Text(c.message).font(.caption).foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
                .padding(.top, 4)
            } label: { Text("Conditions (\(conditions.count))").font(.headline) }
        }
    }

    @ViewBuilder
    private var eventsSection: some View {
        let events = model.relatedEvents
        if !events.isEmpty {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(events) { ev in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 8) {
                                StatusBadge(text: ev.eventType)
                                Text(ev.eventReason).fontWeight(.medium)
                                Spacer()
                                Text(shortAge(since: ev.eventLastTime))
                                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                            }
                            Text(ev.eventMessage).font(.caption).foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(.top, 4)
            } label: { Text("Events (\(events.count))").font(.headline) }
        }
    }

    @ViewBuilder
    private func scaleControl(_ obj: GenericObject) -> some View {
        GroupBox("Scale") {
            HStack {
                TextField("Replicas", text: $replicasText)
                    .frame(width: 70).textFieldStyle(.roundedBorder)
                Stepper("replicas", value: Binding(
                    get: { Int(replicasText) ?? 0 },
                    set: { replicasText = "\($0)" }
                ), in: 0...100).labelsHidden()
                Spacer()
                Button("Apply") {
                    if let n = Int(replicasText) { Task { await model.scaleSelectedDeployment(to: n) } }
                }
                .disabled(Int(replicasText) == nil)
            }
            .padding(8)
        }
    }

    // MARK: - Building blocks

    private func header(_ obj: GenericObject) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "cube.box").font(.largeTitle).foregroundStyle(.tint)
            VStack(alignment: .leading) {
                Text(obj.name).font(.title3.weight(.semibold)).textSelection(.enabled)
                Text(obj.kind).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private func keyValues(_ pairs: [(String, String)]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            ForEach(pairs, id: \.0) { key, value in
                GridRow {
                    Text(key).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    Text(value).textSelection(.enabled)
                }
            }
        }
    }

    @ViewBuilder
    private var yamlSection: some View {
        if !model.detailYAML.isEmpty {
            GroupBox {
                ScrollView {
                    Text(model.detailYAML)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                }
                .frame(maxHeight: 280)
            } label: {
                HStack {
                    Text("YAML")
                    Spacer()
                    Button { copyToPasteboard(model.detailYAML) } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless).help("Copy YAML")
                }
            }
        }
    }
}
