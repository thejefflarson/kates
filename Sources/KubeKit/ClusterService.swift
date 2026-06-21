import Foundation
import SwiftkubeClient
import SwiftkubeModel
import Yams

/// The app's stable boundary against SwiftkubeClient.
///
/// One instance corresponds to one connected kubeconfig context and is
/// immutable: switching contexts means shutting this down and creating a new
/// one. Keeping the SwiftkubeClient surface behind this type means a future
/// client swap touches only this file.
public final class ClusterService: Sendable {
    public let context: KubeContext
    private let client: KubernetesClient

    public init(context: KubeContext, kubeconfig: Kubeconfig) throws {
        guard let client = KubernetesClient(kubeConfig: kubeconfig.raw, contextName: context.name) else {
            throw KubeError.connectionFailed(context.name)
        }
        self.context = context
        self.client = client
    }

    public func shutdown() async {
        try? await client.shutdown()
    }

    /// apps/v1 Deployments have no named convenience accessor, so derive a
    /// typed namespaced client on demand.
    private var deployments: NamespacedGenericKubernetesClient<apps.v1.Deployment> {
        client.namespaceScoped(for: apps.v1.Deployment.self)
    }

    // MARK: - Discovery & generic listing

    /// All listable, non-subresource API types the cluster exposes, one entry
    /// per resource (deduped across versions), sorted by group then name.
    public func discoverResourceTypes() async throws -> [APIResourceType] {
        let groups = try await run { try await self.client.discoveryClient.serverGroups() }

        // Fetch each group-version's resources independently: aggregated APIs
        // (e.g. metrics) sometimes advertise a version whose endpoint 404s, and
        // a single failure must not wipe out the whole sidebar.
        var seen = Set<String>()
        var types: [APIResourceType] = []
        for gv in Set(groups.groups.flatMap { $0.versions.map(\.groupVersion) }) {
            guard let list = try? await run({
                try await self.client.discoveryClient.serverResources(forGroupVersion: gv)
            }) else { continue }
            let (group, version) = Self.splitGroupVersion(list.groupVersion)
            for r in list.resources where !r.name.contains("/") && r.verbs.contains("list") {
                let type = APIResourceType(group: group, version: version,
                                           name: r.name, kind: r.kind, namespaced: r.namespaced)
                if seen.insert(type.id).inserted { types.append(type) }
            }
        }
        return types.sorted {
            ($0.groupVersion.lowercased(), $0.name) < ($1.groupVersion.lowercased(), $1.name)
        }
    }

    /// Lists objects of any discovered type via the generic (unstructured) client.
    /// `namespace == nil` (or a cluster-scoped type) lists across all namespaces.
    public func listObjects(of type: APIResourceType, namespace: String?) async throws -> [GenericObject] {
        // SwiftkubeModel encodes the core group as "core" (→ /api/v1), not "".
        let gvr = GroupVersionResource(group: type.group.isEmpty ? "core" : type.group,
                                       version: type.version, resource: type.name)
        let generic = client.for(gvr: gvr)
        let selector: NamespaceSelector
        if type.namespaced, let namespace {
            selector = .namespace(namespace)
        } else {
            selector = .allNamespaces
        }
        let list = try await run { try await generic.list(in: selector) }
        return list.items.map(GenericObject.init)
    }

    /// Pods scheduled onto a given node (across all namespaces).
    public func listPodsOnNode(_ node: String) async throws -> [GenericObject] {
        let podsType = APIResourceType(group: "", version: "v1", name: "pods",
                                       kind: "Pod", namespaced: true)
        let pods = try await listObjects(of: podsType, namespace: nil)
        return pods.filter { $0.nodeName == node }
    }

    static func splitGroupVersion(_ gv: String) -> (group: String, version: String) {
        let parts = gv.split(separator: "/", maxSplits: 1)
        return parts.count == 2 ? (String(parts[0]), String(parts[1])) : ("", gv)
    }

    // MARK: - Read

    public func listNamespaces() async throws -> [core.v1.Namespace] {
        try await run { try await self.client.namespaces.list().items }
    }

    public func listPods(namespace: String) async throws -> [core.v1.Pod] {
        try await run { try await self.client.pods.list(in: .namespace(namespace)).items }
    }

    public func listDeployments(namespace: String) async throws -> [apps.v1.Deployment] {
        try await run { try await self.deployments.list(in: .namespace(namespace)).items }
    }

    public func listServices(namespace: String) async throws -> [core.v1.Service] {
        try await run { try await self.client.services.list(in: .namespace(namespace)).items }
    }

    /// CustomResourceDefinitions are cluster-scoped (no namespace).
    public func listCRDs() async throws -> [apiextensions.v1.CustomResourceDefinition] {
        try await run {
            try await self.client
                .clusterScoped(for: apiextensions.v1.CustomResourceDefinition.self)
                .list().items
        }
    }

    /// Fetches one pod and renders it as kubectl-style YAML for the detail pane.
    public func podYAML(namespace: String, name: String) async throws -> String {
        let pod = try await run {
            try await self.client.pods.get(in: .namespace(namespace), name: name)
        }
        return Self.yaml(pod)
    }

    // MARK: - Top (metrics.k8s.io)

    /// Per-pod resource usage from metrics-server (`kubectl top pods`).
    /// `metrics.k8s.io` isn't in the generated model, so it's fetched via the
    /// generic GVR client and parsed from the unstructured response.
    /// `namespace == nil` fetches pod metrics across all namespaces.
    public func listPodMetrics(namespace: String?) async throws -> [PodUsage] {
        let gvr = GroupVersionResource(group: "metrics.k8s.io", version: "v1beta1", resource: "pods")
        let metricsClient = client.for(gvr: gvr)
        let selector: NamespaceSelector = namespace.map { .namespace($0) } ?? .allNamespaces
        let list = try await run { try await metricsClient.list(in: selector) }
        return list.items.compactMap(Self.parseUsage)
    }

    /// Per-node resource usage (`kubectl top nodes`). Cluster-scoped.
    public func listNodeMetrics() async throws -> [PodUsage] {
        let gvr = GroupVersionResource(group: "metrics.k8s.io", version: "v1beta1", resource: "nodes")
        let metricsClient = client.for(gvr: gvr)
        let list = try await run { try await metricsClient.list(in: .allNamespaces) }
        return list.items.compactMap(Self.parseNodeUsage)
    }

    // MARK: - Write

    public func deletePod(namespace: String, name: String) async throws {
        try await run { try await self.client.pods.delete(inNamespace: .namespace(namespace), name: name) }
    }

    public func scaleDeployment(namespace: String, name: String, replicas: Int) async throws {
        try await run {
            let deployments = self.deployments
            var scale = try await deployments.getScale(in: .namespace(namespace), name: name)
            scale.spec = autoscaling.v1.ScaleSpec(replicas: Int32(replicas))
            _ = try await deployments.updateScale(in: .namespace(namespace), name: name, scale: scale)
        }
    }

    /// One-shot log fetch (no follow). `tailLines == nil` returns the full log.
    public func podLogs(namespace: String, pod: String, container: String?, tailLines: Int?) async throws -> String {
        try await run {
            try await self.client.pods.logs(
                in: .namespace(namespace), name: pod, container: container, tailLines: tailLines)
        }
    }

    // MARK: - Log streaming

    /// Streams a container's log lines. Follows live until the consuming task
    /// is cancelled, at which point the underlying connection is torn down.
    public func streamLogs(
        namespace: String,
        pod: String,
        container: String?,
        tailLines: Int = 500
    ) -> AsyncThrowingStream<String, Error> {
        let client = self.client
        return AsyncThrowingStream { continuation in
            // SwiftkubeClient defaults `follow` to `RetryStrategy.never`, which
            // means the moment the stream ends — an idle timeout, an API-server
            // hiccup, a server-closed connection — the task throws
            // `maxRetriesReached` instead of reconnecting. A live tail should
            // survive transient drops, so reconnect indefinitely with backoff.
            let strategy = RetryStrategy(
                policy: .always,
                backoff: .exponential(maximumDelay: 30.0, multiplier: 2.0),
                initialDelay: 1.0,
                jitter: 0.2)
            let box = FollowTaskBox()
            let outer = Task {
                do {
                    let task = try await client.pods.follow(
                        in: .namespace(namespace),
                        name: pod,
                        container: container,
                        tailLines: tailLines,
                        retryStrategy: strategy
                    )
                    await box.store(task)
                    for try await line in await task.start() {
                        continuation.yield(line)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: KubeError.underlying("\(error)"))
                }
            }
            // The follow now reconnects forever, so tearing the pane down must
            // cancel both our consuming task and the underlying connection.
            continuation.onTermination = { _ in
                outer.cancel()
                Task { await box.cancel() }
            }
        }
    }

    // MARK: - Helpers

    private func run<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        do { return try await body() }
        catch let error as KubeError { throw error }
        catch let error as SwiftkubeClientError { throw KubeError.underlying(Self.describe(error)) }
        catch { throw KubeError.underlying("\(error)") }
    }

    /// Renders SwiftkubeClient's errors into readable text — most importantly,
    /// decoding `unexpectedError`'s opaque bytes (e.g. "404 page not found").
    static func describe(_ error: SwiftkubeClientError) -> String {
        switch error {
        case .unexpectedError(let data):
            let body = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return "Unexpected server response: \(body ?? "\(data.count) bytes")"
        case .statusError(let status):
            return status.message ?? status.reason ?? "Kubernetes returned an error status."
        case .badRequest(let message): return message
        case .decodingError(let message): return "Could not decode response: \(message)"
        case .clientError(let underlying), .taskError(let underlying): return "\(underlying)"
        case .emptyResponse: return "The server returned an empty response."
        case .invalidURL: return "Invalid request URL."
        case .maxRetriesReached: return "Gave up after repeated retries."
        }
    }

    private static func yaml<T: Encodable>(_ value: T) -> String {
        let encoder = YAMLEncoder()
        encoder.options.sortKeys = true
        guard let string = try? encoder.encode(value) else {
            return "# could not encode object"
        }
        return string
    }

    // MARK: Metrics parsing

    private static func parseUsage(_ resource: UnstructuredResource) -> PodUsage? {
        guard let name = resource.metadata?.name else { return nil }
        // UnstructuredResource stores nested values as `any Sendable` collections;
        // cast to those exact types (casting to [Any]/[String:Any] fails at runtime).
        let containers = (resource.properties["containers"] as? [any Sendable]) ?? []
        var cpu = 0
        var mem: Int64 = 0
        for container in containers {
            guard let dict = container as? [String: any Sendable],
                  let usage = dict["usage"] as? [String: any Sendable] else { continue }
            if let cpuStr = usage["cpu"] as? String { cpu += cpuMillicores(cpuStr) }
            if let memStr = usage["memory"] as? String { mem += memoryBytes(memStr) }
        }
        return PodUsage(podName: name, cpuMillicores: cpu, memoryBytes: mem)
    }

    /// NodeMetrics carry usage at the top level (no containers array).
    private static func parseNodeUsage(_ resource: UnstructuredResource) -> PodUsage? {
        guard let name = resource.metadata?.name,
              let usage = resource.properties["usage"] as? [String: any Sendable] else { return nil }
        let cpu = (usage["cpu"] as? String).map(cpuMillicores) ?? 0
        let mem = (usage["memory"] as? String).map(memoryBytes) ?? 0
        return PodUsage(podName: name, cpuMillicores: cpu, memoryBytes: mem)
    }

    /// Converts a Kubernetes CPU quantity to millicores. metrics-server usually
    /// reports nanocores (e.g. "12345678n"); cores/milli/micro also handled.
    static func cpuMillicores(_ s: String) -> Int {
        if s.hasSuffix("n"), let v = Double(s.dropLast()) { return Int(v / 1_000_000) }
        if s.hasSuffix("u"), let v = Double(s.dropLast()) { return Int(v / 1_000) }
        if s.hasSuffix("m"), let v = Double(s.dropLast()) { return Int(v) }
        if let v = Double(s) { return Int(v * 1000) }
        return 0
    }

    /// Converts a Kubernetes memory quantity (Ki/Mi/Gi/Ti or K/M/G/T) to bytes.
    static func memoryBytes(_ s: String) -> Int64 {
        let units: [(String, Double)] = [
            ("Ki", 1024), ("Mi", 1_048_576), ("Gi", 1_073_741_824), ("Ti", 1_099_511_627_776),
            ("K", 1_000), ("M", 1_000_000), ("G", 1_000_000_000), ("T", 1_000_000_000_000),
        ]
        for (suffix, multiplier) in units where s.hasSuffix(suffix) {
            if let v = Double(s.dropLast(suffix.count)) { return Int64(v * multiplier) }
        }
        return Int64(Double(s) ?? 0)
    }
}

/// Holds the in-flight follow task so the stream's termination handler can tear
/// down the underlying connection. `SwiftkubeClientTask` is an actor, so its
/// `cancel()` must be awaited — this box bridges the synchronous `onTermination`
/// callback to that async call.
private actor FollowTaskBox {
    private var task: SwiftkubeClientTask<String>?

    func store(_ task: SwiftkubeClientTask<String>) { self.task = task }

    func cancel() async {
        await task?.cancel()
        task = nil
    }
}

/// Per-pod resource usage sampled from metrics-server.
public struct PodUsage: Sendable, Hashable {
    public let podName: String
    public let cpuMillicores: Int
    public let memoryBytes: Int64

    public var cpuDisplay: String { "\(cpuMillicores)m" }

    public var memoryDisplay: String {
        let mib = Double(memoryBytes) / 1_048_576
        return mib >= 1024
            ? String(format: "%.1fGi", mib / 1024)
            : String(format: "%.0fMi", mib)
    }
}
