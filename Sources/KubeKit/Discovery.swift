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
        let meta = resource.metadata
        self.name = meta?.name ?? "—"
        self.namespace = meta?.namespace
        self.createdAt = meta?.creationTimestamp
        self.kind = resource.kind
        if let uid = meta?.uid {
            self.id = uid
        } else {
            let ns = meta?.namespace.map { "\($0)/" } ?? ""
            self.id = "\(ns)\(meta?.name ?? "?")"
        }
        self.raw = resource
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

    private static func parseRFC3339(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
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
