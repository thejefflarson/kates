import XCTest
import Logging
import SwiftkubeClient
@testable import KubeKit

/// Live diagnostic that hits the real cluster from the user's kubeconfig.
/// Gated behind KATES_LIVE=1 so the normal test suite stays offline.
///
///   KATES_LIVE=1 swift test --disable-sandbox --filter LiveDiagnostics
final class LiveDiagnostics: XCTestCase {
    override func setUp() {
        guard ProcessInfo.processInfo.environment["KATES_LIVE"] == "1" else {
            return
        }
    }

    func testLiveConnection() async throws {
        guard ProcessInfo.processInfo.environment["KATES_LIVE"] == "1" else {
            throw XCTSkip("set KATES_LIVE=1 to run")
        }

        let url = ContextStore.defaultURL
        print("‣ kubeconfig path: \(url.path)")
        print("‣ exists: \(FileManager.default.fileExists(atPath: url.path))")

        // 1. Load via the library directly, with a logger that prints warnings —
        //    this is what's swallowed in the app.
        var logger = Logger(label: "kates.diag")
        logger.logLevel = .trace

        let rawConfig = try KubeConfig.from(url: url)
        print("‣ current-context: \(rawConfig.currentContext ?? "nil")")
        print("‣ contexts: \((rawConfig.contexts ?? []).map(\.name))")

        let user = rawConfig.users?.first?.authInfo
        print("‣ has client-cert-data: \(user?.clientCertificateData != nil)")
        print("‣ has client-key-data:  \(user?.clientKeyData != nil)")
        print("‣ has token:            \(user?.token != nil)")
        if let auth = user?.authentication(logger: logger) {
            print("‣ authentication parsed: \(auth)")
        } else {
            print("‣ authentication parsed: nil  ← would make KubernetesClient init fail")
        }

        // 2. Build the client exactly as the app does, but WITH a logger.
        let client = KubernetesClient(
            kubeConfig: rawConfig,
            contextName: rawConfig.currentContext,
            logger: logger
        )
        print("‣ KubernetesClient init nil? \(client == nil)")
        guard let client else {
            XCTFail("KubernetesClient init returned nil")
            return
        }
        defer { try? client.syncShutdown() }

        // 3. Try an actual API call.
        do {
            let namespaces = try await client.namespaces.list()
            print("‣ namespaces.list() OK — \(namespaces.items.count) namespaces")
            print("  \(namespaces.items.compactMap { $0.metadata?.name }.prefix(10))")
        } catch {
            print("‣ namespaces.list() FAILED: \(error)")
            throw error
        }
    }
}
