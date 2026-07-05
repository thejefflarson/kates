import Foundation
import SwiftUI
import KubeKit

/// Auto-refresh cadence for the live tables.
enum RefreshRate: Double, CaseIterable, Identifiable {
    case off = 0, one = 1, two = 2, five = 5, ten = 10
    var id: Double { rawValue }
    var label: String { self == .off ? "Off" : "\(Int(rawValue))s" }
}

@MainActor
@Observable
final class AppModel {
    // Connection state
    private(set) var kubeconfig: Kubeconfig?
    private(set) var kubeconfigURL: URL?
    private(set) var contexts: [KubeContext] = []
    var selectedContextName: String?
    private(set) var service: ClusterService?

    private let kubeconfigDefaultsKey = "kubeconfigPath"

    /// Sentinel namespace value meaning "all namespaces".
    static let allNamespaces = "__all_namespaces__"
    var isAllNamespaces: Bool { selectedNamespace == Self.allNamespaces }

    /// nil when "all namespaces" is selected (for the service layer).
    private var namespaceFilter: String? { isAllNamespaces ? nil : selectedNamespace }

    // Discovery / browsing
    private(set) var resourceTypes: [APIResourceType] = []
    var selectedTypeID: String?
    private(set) var namespaces: [String] = []
    var selectedNamespace: String = "default"

    // Loaded objects
    private(set) var objects: [GenericObject] = []
    private(set) var usage: [String: PodUsage] = [:]   // CPU/mem keyed by pod or node name
    private(set) var nodePods: [GenericObject] = []     // pods on the selected node
    private(set) var nodePodUsage: [String: PodUsage] = [:]
    private(set) var relatedEvents: [GenericObject] = [] // events for the selected object (describe)

    // UI state
    var selectedResourceID: String?
    private(set) var detailYAML: String = ""
    private(set) var isRenderingYAML = false
    private(set) var isLoading = false
    var errorMessage: String?          // connection-level (modal)
    private(set) var listError: String?  // per-list (inline, self-healing)

    private var autoRefreshTask: Task<Void, Never>?
    private let refreshRateKey = "kates.refreshRate"

    private(set) var refreshRate: RefreshRate = {
        let raw = UserDefaults.standard.object(forKey: "kates.refreshRate") as? Double
        return raw.flatMap(RefreshRate.init(rawValue:)) ?? .two
    }()

    func setRefreshRate(_ rate: RefreshRate) {
        refreshRate = rate
        UserDefaults.standard.set(rate.rawValue, forKey: refreshRateKey)
        if service != nil { startAutoRefresh() }
    }

    // MARK: - Derived

    var selectedContext: KubeContext? { contexts.first { $0.name == selectedContextName } }
    var selectedType: APIResourceType? { resourceTypes.first { $0.id == selectedTypeID } }
    var selectedObject: GenericObject? { objects.first { $0.id == selectedResourceID } }

    /// Resource types grouped by API group/version, for a sectioned sidebar.
    var groupedTypes: [(groupVersion: String, types: [APIResourceType])] {
        let groups = Dictionary(grouping: resourceTypes, by: \.groupVersion)
        return groups.keys.sorted { coreFirst($0, $1) }.map { ($0, groups[$0] ?? []) }
    }

    private func coreFirst(_ a: String, _ b: String) -> Bool {
        if a == "v1" { return true }
        if b == "v1" { return false }
        return a.lowercased() < b.lowercased()
    }

    // MARK: - Lifecycle

    func bootstrap() async {
        guard let saved = UserDefaults.standard.string(forKey: kubeconfigDefaultsKey),
              FileManager.default.fileExists(atPath: saved) else {
            return
        }
        await loadKubeconfig(at: URL(fileURLWithPath: saved), persist: false)
    }

    func loadKubeconfig(at url: URL, persist: Bool) async {
        do {
            let config = try ContextStore.load(from: url)
            self.kubeconfig = config
            self.kubeconfigURL = url
            self.contexts = config.contexts

            guard !config.contexts.isEmpty else {
                await disconnect()
                self.errorMessage = "No contexts found in \(url.path). Choose a kubeconfig file with “Open Kubeconfig…”."
                return
            }
            if persist { UserDefaults.standard.set(url.path, forKey: kubeconfigDefaultsKey) }
            if let initial = config.defaultContext {
                await connect(to: initial.name)
            }
        } catch {
            await disconnect()
            reportError(error)
        }
    }

    func chooseKubeconfig(_ url: URL) async {
        await loadKubeconfig(at: url, persist: true)
    }

    func connect(to contextName: String) async {
        guard let kubeconfig, let context = contexts.first(where: { $0.name == contextName }) else { return }
        await disconnect()

        do {
            let newService = try ClusterService(context: context, kubeconfig: kubeconfig)
            self.service = newService
            self.selectedContextName = contextName
            self.selectedNamespace = context.namespace
            self.errorMessage = nil

            async let namespaces = newService.listNamespaces()
            async let types = newService.discoverResourceTypes()
            self.namespaces = (try? await namespaces)?.compactMap { $0.metadata?.name }.sorted() ?? []
            self.resourceTypes = (try await types)

            if !self.namespaces.contains(selectedNamespace), let first = self.namespaces.first {
                selectedNamespace = first
            }
            // Default to Pods if present, else the first discovered type.
            selectedTypeID = (resourceTypes.first { $0.isPod } ?? resourceTypes.first)?.id

            await refresh()
            startAutoRefresh()
        } catch {
            await disconnect()
            reportError(error)
        }
    }

    func disconnect() async {
        autoRefreshTask?.cancel()
        autoRefreshTask = nil
        await service?.shutdown()
        service = nil
        objects = []
        usage = [:]
        resourceTypes = []
        selectedResourceID = nil
        detailYAML = ""
    }

    // MARK: - Loading

    func selectType(_ id: String?) {
        selectedTypeID = id
        selectedResourceID = nil
        detailYAML = ""
        listError = nil
        // Drop the previous type's rows immediately so they don't render under
        // the new type's columns while the fresh list loads.
        objects = []
        usage = [:]
        Task { await refresh() }
    }

    func selectNamespace(_ ns: String) {
        selectedNamespace = ns
        selectedResourceID = nil
        detailYAML = ""
        listError = nil
        objects = []
        usage = [:]
        Task { await refresh() }
    }

    func refresh(silent: Bool = false) async {
        guard let service, let type = selectedType else { return }
        // Capture what we're loading; a slow list must not clobber the table if
        // the user switched type/namespace (or an overlapping poll) meanwhile —
        // that race is what made pods/nodes flip back and forth.
        let requestedType = type.id
        let requestedNamespace = namespaceFilter
        if !silent { isLoading = true }
        defer { if !silent { isLoading = false } }

        do {
            let loaded = try await service.listObjects(of: type, namespace: namespaceFilter)
            guard selectedTypeID == requestedType, namespaceFilter == requestedNamespace else { return }
            self.objects = loaded
            self.listError = nil
            if type.hasMetrics {
                await refreshMetrics(for: type, service: service)
            } else {
                usage = [:]
            }
            // Drop stale selection if the selected object disappeared.
            if let sel = selectedResourceID, !loaded.contains(where: { $0.id == sel }) {
                selectedResourceID = nil
                detailYAML = ""
            }
        } catch {
            // Inline + self-healing: the live poll retries, so transient
            // conditions ("storage is (re)initializing") clear on their own.
            listError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    private func refreshMetrics(for type: APIResourceType, service: ClusterService) async {
        let samples: [PodUsage]?
        if type.isNode {
            samples = try? await service.listNodeMetrics()
        } else {
            samples = try? await service.listPodMetrics(namespace: namespaceFilter)
        }
        usage = Dictionary(uniqueKeysWithValues: (samples ?? []).map { ($0.podName, $0) })
    }

    /// Renders the selected object's YAML off the main thread (Yams encoding can
    /// be non-trivial for large objects), with a loading flag so the pulldown
    /// can show a spinner. Independent of whether the pulldown is open.
    func updateDetail() async {
        guard let obj = selectedObject else { detailYAML = ""; isRenderingYAML = false; return }
        let id = obj.id
        detailYAML = ""
        isRenderingYAML = true
        let yaml = await Task.detached(priority: .userInitiated) { obj.renderYAML() }.value
        guard selectedResourceID == id else { return }   // selection changed while rendering
        detailYAML = yaml
        isRenderingYAML = false
    }

    /// Loads events referencing the selected object (describe view). Cleared
    /// first so a slow fetch never shows the previous object's events.
    func loadEvents(for obj: GenericObject) async {
        relatedEvents = []
        guard let service, let uid = obj.uid else { return }
        relatedEvents = (try? await service.eventsForObject(
            namespace: obj.namespace ?? "default", uid: uid)) ?? []
    }

    func loadNodePods(_ node: String) async {
        guard let service else { nodePods = []; nodePodUsage = [:]; return }
        nodePods = (try? await service.listPodsOnNode(node)) ?? []
        let metrics = (try? await service.listPodMetrics(namespace: nil)) ?? []
        nodePodUsage = Dictionary(metrics.map { ($0.podName, $0) }, uniquingKeysWith: { a, _ in a })
    }

    private func startAutoRefresh() {
        autoRefreshTask?.cancel()
        guard refreshRate != .off else { autoRefreshTask = nil; return }
        let seconds = refreshRate.rawValue
        autoRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(seconds))
                if Task.isCancelled { break }
                await self?.refresh(silent: true)
            }
        }
    }

    // MARK: - Actions (special-cased by kind)

    func deleteSelectedPod() async {
        guard let service, let obj = selectedObject else { return }
        do {
            try await service.deletePod(namespace: obj.namespace ?? selectedNamespace, name: obj.name)
            await refresh()
        } catch { reportError(error) }
    }

    func scaleSelectedDeployment(to replicas: Int) async {
        guard let service, let obj = selectedObject else { return }
        do {
            try await service.scaleDeployment(namespace: obj.namespace ?? selectedNamespace,
                                              name: obj.name, replicas: replicas)
            await refresh()
        } catch { reportError(error) }
    }

    func logStream(for obj: GenericObject, container: String?, tailLines: Int) -> AsyncThrowingStream<String, Error> {
        guard let service else { return AsyncThrowingStream { $0.finish() } }
        return service.streamLogs(namespace: obj.namespace ?? selectedNamespace,
                                  pod: obj.name, container: container, tailLines: tailLines)
    }

    /// One-shot logs (no follow). `tailLines == nil` returns the full log.
    func fetchLogs(for obj: GenericObject, container: String?, tailLines: Int?) async -> String {
        guard let service else { return "" }
        do {
            return try await service.podLogs(namespace: obj.namespace ?? selectedNamespace,
                                             pod: obj.name, container: container, tailLines: tailLines)
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    private func reportError(_ error: Error) {
        errorMessage = (error as? LocalizedError)?.errorDescription ?? "\(error)"
    }
}
