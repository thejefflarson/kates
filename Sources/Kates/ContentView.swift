import SwiftUI
import KubeKit

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 360)
                .navigationTitle("Resources")
        } detail: {
            ResourceListView()
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                contextPicker
                namespacePicker
            }
            ToolbarItemGroup(placement: .primaryAction) {
                if model.isLoading { ProgressView().controlSize(.small) }
                Button {
                    Task { await model.refresh() }
                } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                .disabled(model.service == nil)

                Picker("Auto-refresh", selection: Binding(
                    get: { model.refreshRate },
                    set: { model.setRefreshRate($0) }
                )) {
                    ForEach(RefreshRate.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.menu)
                .fixedSize()
                .help("Auto-refresh interval")
                .disabled(model.service == nil)

                Button {
                    if let url = presentKubeconfigOpenPanel() {
                        Task { await model.chooseKubeconfig(url) }
                    }
                } label: { Label("Open Kubeconfig…", systemImage: "folder") }
                .help(model.kubeconfigURL?.path ?? "Choose a kubeconfig file")
            }
        }
        .alert("Something went wrong",
               isPresented: Binding(
                   get: { model.errorMessage != nil },
                   set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var contextPicker: some View {
        @Bindable var model = model
        return Picker("Context", selection: Binding(
            get: { model.selectedContextName ?? "" },
            set: { name in Task { await model.connect(to: name) } }
        )) {
            ForEach(model.contexts) { ctx in Text(ctx.name).tag(ctx.name) }
        }
        .pickerStyle(.menu)
        .fixedSize()
        .help("Kubeconfig context")
    }

    private var namespacePicker: some View {
        @Bindable var model = model
        return Picker("Namespace", selection: Binding(
            get: { model.selectedNamespace },
            set: { model.selectNamespace($0) }
        )) {
            Text("All Namespaces").tag(AppModel.allNamespaces)
            Divider()
            ForEach(model.namespaces, id: \.self) { ns in Text(ns).tag(ns) }
        }
        .pickerStyle(.menu)
        .fixedSize()
        .help("Namespace")
        .disabled(model.namespaces.isEmpty || !(model.selectedType?.namespaced ?? true))
    }
}

/// The resource-type sidebar, isolated into its own view. It reads only the
/// type list and its selection, so SwiftUI's observation tracking keeps it from
/// re-rendering (and re-diffing this whole `List` through AppKit's slow
/// outline-table coordinator) when unrelated model state changes — the object
/// list, metrics, the 2s refresh, or the selected row. That re-diff was the
/// dominant cost in profiling.
struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.service == nil {
            VStack { Text("Not connected").foregroundStyle(.secondary) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // Plain ScrollView + LazyVStack instead of `List`: SwiftUI's List on
            // macOS re-diffs every row (a per-row NSHostingView + automatic-height
            // Auto Layout pass) through AppKitOutlineTableCoordinator on *every*
            // window layout pass — the dominant cost in profiling. LazyVStack has
            // no such coordinator and only builds visible rows.
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1, pinnedViews: [.sectionHeaders]) {
                    ForEach(model.groupedTypes, id: \.groupVersion) { section in
                        Section {
                            ForEach(section.types) { type in row(type) }
                        } header: {
                            Text(section.groupVersion)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10).padding(.vertical, 3)
                                .background(.bar)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func row(_ type: APIResourceType) -> some View {
        let selected = model.selectedTypeID == type.id
        return Label(type.displayName, systemImage: Self.symbol(for: type))
            .lineLimit(1)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Color.accentColor.opacity(0.20) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
            .onTapGesture { model.selectType(type.id) }
            .padding(.horizontal, 6)
    }

    private static func symbol(for type: APIResourceType) -> String {
        switch type.name {
        case "pods": return "shippingbox"
        case "deployments", "replicasets": return "square.stack.3d.up"
        case "statefulsets", "daemonsets": return "square.stack.3d.down.right"
        case "services": return "network"
        case "configmaps": return "doc.plaintext"
        case "secrets": return "key"
        case "namespaces": return "square.grid.3x3"
        case "nodes": return "cpu"
        case "ingresses": return "arrow.triangle.branch"
        case "persistentvolumeclaims", "persistentvolumes": return "externaldrive"
        default: return type.namespaced ? "cube" : "globe"
        }
    }
}
