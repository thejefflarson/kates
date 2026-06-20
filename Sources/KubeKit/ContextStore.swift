import Foundation
import SwiftkubeClient
import SwiftkubeModel

/// A lightweight, display-friendly view of one kubeconfig context.
public struct KubeContext: Identifiable, Sendable, Hashable {
    public let name: String
    public let cluster: String
    public let namespace: String

    public var id: String { name }
}

/// A loaded kubeconfig. Wraps SwiftkubeClient's `KubeConfig` so that callers
/// (the app, tests) deal only in KubeKit types and never import the client
/// library directly — keeping the dependency contained to KubeKit.
public struct Kubeconfig: Sendable {
    let raw: KubeConfig
    public let contexts: [KubeContext]
    public let currentContext: String?

    init(raw: KubeConfig) {
        self.raw = raw
        self.contexts = (raw.contexts ?? []).map { named in
            KubeContext(
                name: named.name,
                cluster: named.context.cluster,
                namespace: named.context.namespace ?? "default"
            )
        }
        self.currentContext = raw.currentContext
    }

    /// The context matching `currentContext`, or the first available one.
    public var defaultContext: KubeContext? {
        if let current = currentContext, let match = contexts.first(where: { $0.name == current }) {
            return match
        }
        return contexts.first
    }
}

public enum ContextStore {
    /// Default kubeconfig location, honoring `$KUBECONFIG` (first entry only).
    public static var defaultURL: URL {
        let env = ProcessInfo.processInfo.environment
        if let kc = env["KUBECONFIG"], !kc.isEmpty {
            let first = kc.split(separator: ":").first.map(String.init) ?? kc
            return URL(fileURLWithPath: (first as NSString).expandingTildeInPath)
        }
        let home = env["HOME"] ?? NSHomeDirectory()
        return URL(fileURLWithPath: home).appendingPathComponent(".kube/config")
    }

    public static func load(from url: URL? = nil) throws -> Kubeconfig {
        let target = url ?? defaultURL
        do {
            return Kubeconfig(raw: try KubeConfig.from(url: target))
        } catch {
            throw KubeError.noKubeconfig("\(target.path): \(error)")
        }
    }

    /// Parses kubeconfig YAML directly (used by the app's reload and by tests).
    public static func parse(yaml: String) throws -> Kubeconfig {
        do {
            return Kubeconfig(raw: try KubeConfig.from(config: yaml))
        } catch {
            throw KubeError.noKubeconfig("\(error)")
        }
    }
}
