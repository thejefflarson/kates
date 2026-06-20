import Foundation
import SwiftkubeModel

// Convenience, display-oriented accessors over the generated model types.
// These keep the SwiftUI layer free of optional-chaining noise and are the
// natural home for the small bits of presentation logic worth unit-testing.

extension core.v1.Pod {
    public var rowID: String { metadata?.uid ?? "\(displayNamespace)/\(displayName)" }
    public var displayName: String { metadata?.name ?? "—" }
    public var displayNamespace: String { metadata?.namespace ?? "" }
    public var phase: String { status?.phase ?? "Unknown" }
    public var nodeName: String { spec?.nodeName ?? "—" }
    public var createdAt: Date? { metadata?.creationTimestamp }

    /// "1/2"-style ready summary (ready containers / total containers).
    public var readySummary: String {
        let statuses = status?.containerStatuses ?? []
        let ready = statuses.filter(\.ready).count
        let total = spec?.containers.count ?? statuses.count
        return "\(ready)/\(total)"
    }

    public var restarts: Int {
        (status?.containerStatuses ?? []).reduce(0) { $0 + Int($1.restartCount) }
    }

    public var containerNames: [String] {
        (spec?.containers ?? []).map(\.name)
    }
}

extension apps.v1.Deployment {
    public var rowID: String { metadata?.uid ?? "\(displayNamespace)/\(displayName)" }
    public var displayName: String { metadata?.name ?? "—" }
    public var displayNamespace: String { metadata?.namespace ?? "" }
    public var desiredReplicas: Int { Int(spec?.replicas ?? 0) }
    public var readyReplicas: Int { Int(status?.readyReplicas ?? 0) }
    public var readySummary: String { "\(readyReplicas)/\(desiredReplicas)" }
    public var createdAt: Date? { metadata?.creationTimestamp }
}

extension core.v1.Service {
    public var rowID: String { metadata?.uid ?? "\(displayNamespace)/\(displayName)" }
    public var displayName: String { metadata?.name ?? "—" }
    public var displayNamespace: String { metadata?.namespace ?? "" }
    public var serviceType: String { spec?.type ?? "ClusterIP" }
    public var clusterIP: String { spec?.clusterIP ?? "—" }
    public var createdAt: Date? { metadata?.creationTimestamp }

    public var portSummary: String {
        (spec?.ports ?? []).map { p in
            "\(p.port)/\(p.protocol ?? "TCP")"
        }.joined(separator: ", ")
    }
}

extension core.v1.Namespace {
    public var displayName: String { metadata?.name ?? "—" }
    public var phase: String { status?.phase ?? "—" }
}

extension apiextensions.v1.CustomResourceDefinition {
    public var rowID: String { metadata?.uid ?? displayName }
    public var displayName: String { metadata?.name ?? "—" }
    public var group: String { spec.group }
    public var definedKind: String { spec.names.kind }
    public var scope: String { spec.scope }
    public var versionNames: [String] { spec.versions.map(\.name) }
    public var createdAt: Date? { metadata?.creationTimestamp }
}

/// Compact "5m", "3h", "2d"-style age from a creation timestamp.
public func shortAge(since date: Date?, now: Date = Date()) -> String {
    guard let date else { return "—" }
    let seconds = max(0, Int(now.timeIntervalSince(date)))
    switch seconds {
    case 0..<60: return "\(seconds)s"
    case 60..<3600: return "\(seconds / 60)m"
    case 3600..<86_400: return "\(seconds / 3600)h"
    default: return "\(seconds / 86_400)d"
    }
}
