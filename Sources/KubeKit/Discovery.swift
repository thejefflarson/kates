import Foundation
import SwiftkubeClient
import SwiftkubeModel
import Yams

/// One discovered API resource type (the unit the sidebar is built from).
public struct APIResourceType: Identifiable, Sendable, Hashable {
    public let group: String      // "" for the core group
    public let version: String
    public let name: String       // plural, e.g. "pods"
    public let kind: String       // e.g. "Pod"
    public let namespaced: Bool

    /// "v1" for core, otherwise "group/version".
    public var groupVersion: String { group.isEmpty ? version : "\(group)/\(version)" }

    /// One entry per resource (dedup key across versions).
    public var id: String { "\(group)/\(name)" }

    public var displayName: String { name }

    public var isPod: Bool { group.isEmpty && name == "pods" }
    public var isNode: Bool { group.isEmpty && name == "nodes" }
    public var isService: Bool { group.isEmpty && name == "services" }
    public var isDeployment: Bool { group == "apps" && name == "deployments" }
    public var isEvent: Bool { (group.isEmpty || group == "events.k8s.io") && name == "events" }

    /// Whether `metrics.k8s.io` usage applies to this type.
    public var hasMetrics: Bool { isPod || isNode }
}

/// A type-erased Kubernetes object for generic listing. Cheap fields are
/// extracted eagerly; YAML and nested lookups are computed on demand.
public struct GenericObject: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let namespace: String?
    public let createdAt: Date?
    public let kind: String
    let raw: UnstructuredResource

    init(_ resource: UnstructuredResource) {
        let trimmed = Self.trimmingHeavyMetadata(resource)
        let meta = trimmed.metadata
        self.name = meta?.name ?? "—"
        self.namespace = meta?.namespace
        self.createdAt = meta?.creationTimestamp
        self.kind = trimmed.kind
        if let uid = meta?.uid {
            self.id = uid
        } else {
            let ns = meta?.namespace.map { "\($0)/" } ?? ""
            self.id = "\(ns)\(meta?.name ?? "?")"
        }
        self.raw = trimmed
    }

    /// Server-side-apply `managedFields` and the `last-applied-configuration`
    /// annotation are the largest parts of a typical Kubernetes object and are
    /// never displayed. Dropping them stops live tables from retaining megabytes
    /// of bookkeeping across every refresh (and declutters the YAML view).
    private static let lastAppliedKey = "kubectl.kubernetes.io/last-applied-configuration"
    private static func trimmingHeavyMetadata(_ resource: UnstructuredResource) -> UnstructuredResource {
        guard var meta = resource.metadata,
              meta.managedFields != nil || meta.annotations?[lastAppliedKey] != nil
        else { return resource }
        meta.managedFields = nil
        meta.annotations?[lastAppliedKey] = nil
        if meta.annotations?.isEmpty == true { meta.annotations = nil }
        var props = resource.properties
        props["metadata"] = meta
        return UnstructuredResource(properties: props)
    }

    public var age: String { shortAge(since: createdAt) }

    // Sort keys (Table comparators need non-optional Comparable values).
    public var sortNamespace: String { namespace ?? "" }
    public var sortCreated: Date { createdAt ?? .distantPast }

    /// Container names (pods), parsed from the unstructured spec.
    public var containerNames: [String] {
        guard let spec = raw.properties["spec"] as? [String: any Sendable],
              let containers = spec["containers"] as? [any Sendable] else { return [] }
        return containers.compactMap { ($0 as? [String: any Sendable])?["name"] as? String }
    }

    /// Per-container runtime status (pods), from `status.containerStatuses`.
    public var containers: [ContainerStatusInfo] {
        guard let status = raw.properties["status"] as? [String: any Sendable],
              let statuses = status["containerStatuses"] as? [any Sendable] else { return [] }
        return statuses.compactMap { item in
            guard let cs = item as? [String: any Sendable],
                  let name = cs["name"] as? String else { return nil }
            let ready = cs["ready"] as? Bool ?? false
            let restarts = (cs["restartCount"] as? Int) ?? Int(cs["restartCount"] as? Double ?? 0)
            let image = cs["image"] as? String ?? "—"
            let state = Self.stateString(cs["state"] as? [String: any Sendable])
            return ContainerStatusInfo(name: name, ready: ready, restarts: restarts,
                                       image: image, state: state)
        }
    }

    private static func stateString(_ state: [String: any Sendable]?) -> String {
        guard let state else { return "—" }
        if state["running"] != nil { return "Running" }
        if let waiting = state["waiting"] as? [String: any Sendable] {
            return (waiting["reason"] as? String) ?? "Waiting"
        }
        if let terminated = state["terminated"] as? [String: any Sendable] {
            return (terminated["reason"] as? String) ?? "Terminated"
        }
        return "—"
    }

    private var specContainers: [[String: any Sendable]] {
        guard let spec = raw.properties["spec"] as? [String: any Sendable],
              let containers = spec["containers"] as? [any Sendable] else { return [] }
        return containers.compactMap { $0 as? [String: any Sendable] }
    }

    /// Summed CPU request/limit across containers, in millicores (0 if unset).
    public var cpuRequestMillicores: Int { sumCPU(section: "requests") }
    public var cpuLimitMillicores: Int { sumCPU(section: "limits") }
    /// Summed memory request/limit across containers, in bytes (0 if unset).
    public var memoryRequestBytes: Int64 { sumMemory(section: "requests") }
    public var memoryLimitBytes: Int64 { sumMemory(section: "limits") }

    private func sumCPU(section: String) -> Int {
        specContainers.reduce(0) { acc, c in
            guard let q = resourceQuantity(c, section: section, key: "cpu") else { return acc }
            return acc + ClusterService.cpuMillicores(q)
        }
    }

    private func sumMemory(section: String) -> Int64 {
        specContainers.reduce(0) { acc, c in
            guard let q = resourceQuantity(c, section: section, key: "memory") else { return acc }
            return acc + ClusterService.memoryBytes(q)
        }
    }

    private func resourceQuantity(_ container: [String: any Sendable], section: String, key: String) -> String? {
        guard let resources = container["resources"] as? [String: any Sendable],
              let sec = resources[section] as? [String: any Sendable] else { return nil }
        return sec[key] as? String
    }

    /// `spec.nodeName` (pods), if scheduled.
    public var nodeName: String? {
        (raw.properties["spec"] as? [String: any Sendable])?["nodeName"] as? String
    }

    /// `status.podIP` (pods) — the `kubectl -o wide` IP column.
    public var podIP: String? {
        (raw.properties["status"] as? [String: any Sendable])?["podIP"] as? String
    }

    // MARK: Node `-o wide` columns (status.addresses / status.nodeInfo)

    public var nodeInternalIP: String? { nodeAddress("InternalIP") }
    public var nodeOSImage: String? { nodeInfo("osImage") }
    public var nodeKernelVersion: String? { nodeInfo("kernelVersion") }
    public var nodeContainerRuntime: String? { nodeInfo("containerRuntimeVersion") }

    private func nodeAddress(_ type: String) -> String? {
        guard let status = raw.properties["status"] as? [String: any Sendable],
              let addresses = status["addresses"] as? [any Sendable] else { return nil }
        for a in addresses {
            if let d = a as? [String: any Sendable], d["type"] as? String == type {
                return d["address"] as? String
            }
        }
        return nil
    }

    private func nodeInfo(_ key: String) -> String? {
        guard let status = raw.properties["status"] as? [String: any Sendable],
              let info = status["nodeInfo"] as? [String: any Sendable] else { return nil }
        return info[key] as? String
    }

    // MARK: Service `-o wide` columns (spec.type / spec.clusterIP / spec.ports)

    public var serviceType: String? { specString("type") }
    public var serviceClusterIP: String? { specString("clusterIP") }

    /// "80/TCP,443/TCP"-style port summary.
    public var servicePorts: String {
        guard let spec = raw.properties["spec"] as? [String: any Sendable],
              let ports = spec["ports"] as? [any Sendable] else { return "" }
        return ports.compactMap { item -> String? in
            guard let d = item as? [String: any Sendable] else { return nil }
            let port = (d["port"] as? Int) ?? Int(d["port"] as? Double ?? 0)
            let proto = d["protocol"] as? String ?? "TCP"
            return "\(port)/\(proto)"
        }.joined(separator: ",")
    }

    private func specString(_ key: String) -> String? {
        (raw.properties["spec"] as? [String: any Sendable])?[key] as? String
    }

    /// `spec.replicas` (deployments/statefulsets), if present.
    public var specReplicas: Int? {
        guard let spec = raw.properties["spec"] as? [String: any Sendable] else { return nil }
        if let i = spec["replicas"] as? Int { return i }
        if let d = spec["replicas"] as? Double { return Int(d) }
        return nil
    }

    // MARK: Event fields (core/v1 Event and events.k8s.io/v1 Event)

    public var eventMessage: String {
        (raw.properties["message"] as? String) ?? (raw.properties["note"] as? String) ?? ""
    }
    public var eventReason: String { raw.properties["reason"] as? String ?? "" }
    public var eventType: String { raw.properties["type"] as? String ?? "Normal" }
    public var eventCount: Int {
        (raw.properties["count"] as? Int)
            ?? ((raw.properties["series"] as? [String: any Sendable])?["count"] as? Int)
            ?? 0
    }

    public var eventObject: String {
        let obj = (raw.properties["involvedObject"] as? [String: any Sendable])
            ?? (raw.properties["regarding"] as? [String: any Sendable])
        guard let obj else { return "" }
        let kind = obj["kind"] as? String ?? ""
        let name = obj["name"] as? String ?? ""
        return kind.isEmpty ? name : "\(kind)/\(name)"
    }

    /// Most-recent event time, falling back through the various timestamp fields.
    public var eventLastTime: Date? {
        for key in ["lastTimestamp", "deprecatedLastTimestamp", "eventTime"] {
            if let s = raw.properties[key] as? String, let d = Self.parseRFC3339(s) { return d }
        }
        return createdAt
    }

    // Allocating an ISO8601DateFormatter is expensive (ICU setup); reuse two
    // pre-configured instances instead of building one per parse. Accessed only
    // from the main-actor UI path, so sharing is safe.
    nonisolated(unsafe) private static let fractionalFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let plainFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func parseRFC3339(_ s: String) -> Date? {
        fractionalFormatter.date(from: s) ?? plainFormatter.date(from: s)
    }

    public func renderYAML() -> String {
        let encoder = YAMLEncoder()
        encoder.options.sortKeys = true
        return (try? encoder.encode(raw)) ?? "# could not render YAML"
    }
}

/// Runtime status of one container within a pod.
public struct ContainerStatusInfo: Sendable, Identifiable, Hashable {
    public let name: String
    public let ready: Bool
    public let restarts: Int
    public let image: String
    public let state: String     // Running / Waiting(reason) / Terminated(reason)

    public var id: String { name }
}
