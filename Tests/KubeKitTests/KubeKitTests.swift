import XCTest
import SwiftkubeModel
@testable import KubeKit

final class DisplayTests: XCTestCase {
    func testPodReadySummaryAndRestarts() {
        var pod = core.v1.Pod()
        pod.spec = core.v1.PodSpec(containers: [
            core.v1.Container(name: "a"),
            core.v1.Container(name: "b"),
        ])
        pod.status = core.v1.PodStatus(
            containerStatuses: [
                core.v1.ContainerStatus(
                    containerID: nil, image: "img", imageID: "id",
                    lastState: nil, name: "a", ready: true,
                    restartCount: 2, started: nil, state: nil
                ),
                core.v1.ContainerStatus(
                    containerID: nil, image: "img", imageID: "id",
                    lastState: nil, name: "b", ready: false,
                    restartCount: 1, started: nil, state: nil
                ),
            ],
            phase: "Running"
        )

        XCTAssertEqual(pod.readySummary, "1/2")
        XCTAssertEqual(pod.restarts, 3)
        XCTAssertEqual(pod.phase, "Running")
        XCTAssertEqual(pod.containerNames, ["a", "b"])
    }

    func testDeploymentReadySummary() {
        var dep = apps.v1.Deployment()
        dep.spec = apps.v1.DeploymentSpec(replicas: 3, selector: meta.v1.LabelSelector(), template: core.v1.PodTemplateSpec())
        dep.status = apps.v1.DeploymentStatus(readyReplicas: 2)
        XCTAssertEqual(dep.readySummary, "2/3")
    }

    func testServicePortSummary() {
        var svc = core.v1.Service()
        svc.spec = core.v1.ServiceSpec(
            ports: [core.v1.ServicePort(port: 80, protocol: "TCP")],
            type: "ClusterIP"
        )
        XCTAssertEqual(svc.serviceType, "ClusterIP")
        XCTAssertEqual(svc.portSummary, "80/TCP")
    }

    func testShortAge() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(shortAge(since: now.addingTimeInterval(-30), now: now), "30s")
        XCTAssertEqual(shortAge(since: now.addingTimeInterval(-120), now: now), "2m")
        XCTAssertEqual(shortAge(since: now.addingTimeInterval(-7200), now: now), "2h")
        XCTAssertEqual(shortAge(since: now.addingTimeInterval(-172_800), now: now), "2d")
        XCTAssertEqual(shortAge(since: nil, now: now), "—")
    }
}

final class ContextStoreTests: XCTestCase {
    // Mirrors the user's real kubeconfig shape: client-cert auth + custom CA.
    private let sampleYAML = """
    apiVersion: v1
    kind: Config
    current-context: default
    clusters:
    - name: default
      cluster:
        server: https://192.168.0.20:6443
        certificate-authority-data: QQ==
    contexts:
    - name: default
      context:
        cluster: default
        user: default
    - name: staging
      context:
        cluster: default
        user: default
        namespace: web
    users:
    - name: default
      user:
        client-certificate-data: QQ==
        client-key-data: QQ==
    """

    func testEnumeratesContexts() throws {
        let config = try ContextStore.parse(yaml: sampleYAML)
        XCTAssertEqual(config.contexts.map(\.name), ["default", "staging"])
        XCTAssertEqual(config.contexts.first?.namespace, "default") // defaulted
        XCTAssertEqual(config.contexts.last?.namespace, "web")       // explicit
        XCTAssertEqual(config.currentContext, "default")
        XCTAssertEqual(config.defaultContext?.name, "default")
    }
}
