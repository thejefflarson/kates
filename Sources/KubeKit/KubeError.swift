import Foundation

/// App-facing errors. SwiftkubeClient's own errors are wrapped into these so
/// the UI (and any future client implementation) has a stable surface.
public enum KubeError: Error, LocalizedError, Sendable {
    case noKubeconfig(String)
    case connectionFailed(String)
    case underlying(String)

    public var errorDescription: String? {
        switch self {
        case .noKubeconfig(let m): return "Could not load kubeconfig: \(m)"
        case .connectionFailed(let ctx): return "Could not connect using context “\(ctx)”."
        case .underlying(let m): return m
        }
    }
}
