import XCTest
import SwiftkubeModel
@testable import KubeKit

/// Exercises the dynamic-discovery path: `GenericObject` pulling typed values
/// out of an `UnstructuredResource`'s `[String: any Sendable]` dictionaries.
///
/// The fixtures deliberately mirror the *real* decoded shape — nested objects
/// as `[String: any Sendable]`, arrays as `[any Sendable]`, and a typed
/// `meta.v1.ObjectMeta` at `metadata`. That shape is exactly the casting
/// contract that regressed once (casting to `[String: Any]` fails at runtime),
/// so these tests guard that class of bug.
final class GenericObjectTests: XCTestCase {

    // Build `[String: any Sendable]` / `[any Sendable]` literals without
    // Swift inferring a narrower element type that fails the runtime cast.
    private func dict(_ pairs: [String: any Sendable]) -> [String: any Sendable] { pairs }
    private func arr(_ items: [any Sendable]) -> [any Sendable] { items }

    private func objectMeta(name: String, namespace: String? = nil,
                            uid: String? = nil, created: Date? = nil) -> meta.v1.ObjectMeta {
        var m = meta.v1.ObjectMeta()
        m.name = name
        m.namespace = namespace
        m.uid = uid
        m.creationTimestamp = created
        return m
    }

    private func object(kind: String, meta m: meta.v1.ObjectMeta,
                        _ extra: [String: any Sendable]) -> GenericObject {
        var props: [String: any Sendable] = ["kind": kind, "metadata": m]
        props.merge(extra) { _, new in new }
        return GenericObject(UnstructuredResource(properties: props))
    }

    // MARK: Identity & metadata

    func testIdentityFromUID() {
        let obj = object(kind: "Pod",
                         meta: objectMeta(name: "web", namespace: "default", uid: "uid-1"),
                         [:])
        XCTAssertEqual(obj.id, "uid-1")
        XCTAssertEqual(obj.name, "web")
        XCTAssertEqual(obj.namespace, "default")
        XCTAssertEqual(obj.kind, "Pod")
    }

    func testIdentityFallsBackToNamespacedName() {
        let obj = object(kind: "Pod", meta: objectMeta(name: "web", namespace: "kube-system"), [:])
        XCTAssertEqual(obj.id, "kube-system/web")
    }

    func testSortKeysTolerateMissingValues() {
        let obj = object(kind: "Node", meta: objectMeta(name: "n1"), [:])
        XCTAssertEqual(obj.sortNamespace, "")          // nil namespace → ""
        XCTAssertEqual(obj.sortCreated, .distantPast)  // nil createdAt → distantPast
    }

    // MARK: Pod containers & status

    func testContainerNamesAndStatuses() {
        let obj = object(kind: "Pod", meta: objectMeta(name: "web"), [
            "spec": dict([
                "containers": arr([
                    dict(["name": "app"]),
                    dict(["name": "sidecar"]),
                ]),
            ]),
            "status": dict([
                "containerStatuses": arr([
                    dict(["name": "app", "ready": true, "restartCount": 3, "image": "nginx",
                          "state": dict(["running": dict(["startedAt": "2026-06-20T10:00:00Z"])])]),
                    dict(["name": "sidecar", "ready": false, "restartCount": 0, "image": "busybox",
                          "state": dict(["waiting": dict(["reason": "CrashLoopBackOff"])])]),
                ]),
            ]),
        ])

        XCTAssertEqual(obj.containerNames, ["app", "sidecar"])

        let containers = obj.containers
        XCTAssertEqual(containers.count, 2)
        XCTAssertEqual(containers[0].name, "app")
        XCTAssertTrue(containers[0].ready)
        XCTAssertEqual(containers[0].restarts, 3)
        XCTAssertEqual(containers[0].image, "nginx")
        XCTAssertEqual(containers[0].state, "Running")
        XCTAssertFalse(containers[1].ready)
        XCTAssertEqual(containers[1].state, "CrashLoopBackOff")
    }

    func testRestartCountAcceptsDouble() {
        // JSON decoders sometimes hand back numbers as Double.
        let obj = object(kind: "Pod", meta: objectMeta(name: "web"), [
            "status": dict([
                "containerStatuses": arr([
                    dict(["name": "app", "ready": true, "restartCount": 2.0]),
                ]),
            ]),
        ])
        XCTAssertEqual(obj.containers.first?.restarts, 2)
    }

    // MARK: Resource requests / limits

    func testCPUAndMemorySummedAcrossContainers() {
        let obj = object(kind: "Pod", meta: objectMeta(name: "web"), [
            "spec": dict([
                "containers": arr([
                    dict(["name": "app", "resources": dict([
                        "requests": dict(["cpu": "250m", "memory": "128Mi"]),
                        "limits": dict(["cpu": "1", "memory": "256Mi"]),
                    ])]),
                    dict(["name": "sidecar", "resources": dict([
                        "requests": dict(["cpu": "100m", "memory": "64Mi"]),
                        // no limits on the sidecar
                    ])]),
                ]),
            ]),
        ])

        XCTAssertEqual(obj.cpuRequestMillicores, 350)               // 250m + 100m
        XCTAssertEqual(obj.cpuLimitMillicores, 1000)                // 1 core + (unset)
        XCTAssertEqual(obj.memoryRequestBytes, 192 * 1_048_576)     // 128Mi + 64Mi
        XCTAssertEqual(obj.memoryLimitBytes, 256 * 1_048_576)       // 256Mi + (unset)
    }

    func testMissingResourcesAreZero() {
        let obj = object(kind: "Pod", meta: objectMeta(name: "web"), [
            "spec": dict(["containers": arr([dict(["name": "app"])])]),
        ])
        XCTAssertEqual(obj.cpuRequestMillicores, 0)
        XCTAssertEqual(obj.memoryLimitBytes, 0)
    }

    // MARK: Node name & replicas

    func testNodeName() {
        let scheduled = object(kind: "Pod", meta: objectMeta(name: "web"),
                               ["spec": dict(["nodeName": "node-1"])])
        XCTAssertEqual(scheduled.nodeName, "node-1")

        let pending = object(kind: "Pod", meta: objectMeta(name: "web"), ["spec": dict([:])])
        XCTAssertNil(pending.nodeName)
    }

    func testPodIP() {
        let running = object(kind: "Pod", meta: objectMeta(name: "web"),
                             ["status": dict(["podIP": "10.1.2.3"])])
        XCTAssertEqual(running.podIP, "10.1.2.3")

        let pending = object(kind: "Pod", meta: objectMeta(name: "web"), ["status": dict([:])])
        XCTAssertNil(pending.podIP)
    }

    func testNodeWideColumns() {
        let node = object(kind: "Node", meta: objectMeta(name: "node-1"), [
            "status": dict([
                "addresses": arr([
                    dict(["type": "InternalIP", "address": "192.168.0.20"]),
                    dict(["type": "Hostname", "address": "node-1"]),
                ]),
                "nodeInfo": dict([
                    "osImage": "Ubuntu 22.04.3 LTS",
                    "kernelVersion": "5.15.0-89-generic",
                    "containerRuntimeVersion": "containerd://1.7.2",
                ]),
            ]),
        ])
        XCTAssertEqual(node.nodeInternalIP, "192.168.0.20")
        XCTAssertEqual(node.nodeOSImage, "Ubuntu 22.04.3 LTS")
        XCTAssertEqual(node.nodeKernelVersion, "5.15.0-89-generic")
        XCTAssertEqual(node.nodeContainerRuntime, "containerd://1.7.2")

        let bare = object(kind: "Node", meta: objectMeta(name: "n2"), ["status": dict([:])])
        XCTAssertNil(bare.nodeInternalIP)
        XCTAssertNil(bare.nodeOSImage)
    }

    func testServiceWideColumns() {
        let svc = object(kind: "Service", meta: objectMeta(name: "web", namespace: "default"), [
            "spec": dict([
                "type": "ClusterIP",
                "clusterIP": "10.96.0.10",
                "ports": arr([
                    dict(["port": 80, "protocol": "TCP"]),
                    dict(["port": 443.0, "protocol": "TCP"]),   // Double from JSON
                ]),
            ]),
        ])
        XCTAssertEqual(svc.serviceType, "ClusterIP")
        XCTAssertEqual(svc.serviceClusterIP, "10.96.0.10")
        XCTAssertEqual(svc.servicePorts, "80/TCP,443/TCP")

        let empty = object(kind: "Service", meta: objectMeta(name: "s2"), ["spec": dict([:])])
        XCTAssertEqual(empty.servicePorts, "")
        XCTAssertNil(empty.serviceType)
    }

    func testSpecReplicasIntAndDouble() {
        let intReplicas = object(kind: "Deployment", meta: objectMeta(name: "api"),
                                 ["spec": dict(["replicas": 3])])
        XCTAssertEqual(intReplicas.specReplicas, 3)

        let doubleReplicas = object(kind: "Deployment", meta: objectMeta(name: "api"),
                                    ["spec": dict(["replicas": 5.0])])
        XCTAssertEqual(doubleReplicas.specReplicas, 5)

        let none = object(kind: "Pod", meta: objectMeta(name: "web"), ["spec": dict([:])])
        XCTAssertNil(none.specReplicas)
    }

    // MARK: Describe (labels, conditions, event matching)

    func testLabelsAndConditions() {
        var m = objectMeta(name: "web", namespace: "default", uid: "uid-1")
        m.labels = ["app": "web", "tier": "frontend"]
        let obj = object(kind: "Pod", meta: m, [
            "status": dict([
                "conditions": arr([
                    dict(["type": "Ready", "status": "True"]),
                    dict(["type": "ContainersReady", "status": "False",
                          "reason": "ContainersNotReady", "message": "containers not ready"]),
                    dict(["foo": "bar"]),   // no type → skipped
                ]),
            ]),
        ])
        XCTAssertEqual(obj.uid, "uid-1")
        XCTAssertEqual(obj.labels, ["app": "web", "tier": "frontend"])

        let conds = obj.conditions
        XCTAssertEqual(conds.count, 2)
        XCTAssertEqual(conds[0].type, "Ready")
        XCTAssertEqual(conds[0].status, "True")
        XCTAssertEqual(conds[1].reason, "ContainersNotReady")
        XCTAssertEqual(conds[1].message, "containers not ready")
    }

    func testEventInvolvedUIDForMatching() {
        let core = object(kind: "Event", meta: objectMeta(name: "e1"),
                          ["involvedObject": dict(["kind": "Pod", "name": "web", "uid": "uid-1"])])
        XCTAssertEqual(core.eventInvolvedUID, "uid-1")

        let k8sio = object(kind: "Event", meta: objectMeta(name: "e2"),
                           ["regarding": dict(["kind": "Pod", "name": "api", "uid": "uid-2"])])
        XCTAssertEqual(k8sio.eventInvolvedUID, "uid-2")

        let none = object(kind: "Pod", meta: objectMeta(name: "web"), [:])
        XCTAssertNil(none.eventInvolvedUID)
    }

    // MARK: Events — core/v1 shape

    func testCoreV1EventFields() {
        let obj = object(kind: "Event", meta: objectMeta(name: "evt", namespace: "default"), [
            "message": "Back-off restarting failed container",
            "reason": "BackOff",
            "type": "Warning",
            "count": 5,
            "involvedObject": dict(["kind": "Pod", "name": "web"]),
            "lastTimestamp": "2026-06-20T10:00:00Z",
        ])
        XCTAssertEqual(obj.eventMessage, "Back-off restarting failed container")
        XCTAssertEqual(obj.eventReason, "BackOff")
        XCTAssertEqual(obj.eventType, "Warning")
        XCTAssertEqual(obj.eventCount, 5)
        XCTAssertEqual(obj.eventObject, "Pod/web")
        XCTAssertNotNil(obj.eventLastTime)
    }

    // MARK: Events — events.k8s.io/v1 shape (note/series/regarding/eventTime)

    func testEventsK8sIoV1FallbackFields() {
        let obj = object(kind: "Event", meta: objectMeta(name: "evt", namespace: "default"), [
            "note": "Readiness probe failed",
            "reason": "Unhealthy",
            "type": "Warning",
            "series": dict(["count": 12]),
            "regarding": dict(["kind": "Pod", "name": "api"]),
            "eventTime": "2026-06-20T11:30:00.500Z",
        ])
        XCTAssertEqual(obj.eventMessage, "Readiness probe failed")  // note fallback
        XCTAssertEqual(obj.eventCount, 12)                          // series.count fallback
        XCTAssertEqual(obj.eventObject, "Pod/api")                  // regarding fallback
        XCTAssertNotNil(obj.eventLastTime)                          // fractional-seconds parse
    }

    // MARK: Heavy-metadata trimming (memory)

    func testStripsManagedFieldsAndLastAppliedAnnotation() {
        var m = objectMeta(name: "web", namespace: "default", uid: "uid-1")
        var mf = meta.v1.ManagedFieldsEntry()
        mf.manager = "kubectl-client-side-apply"
        m.managedFields = [mf]
        m.annotations = [
            "kubectl.kubernetes.io/last-applied-configuration": "{\"huge\":\"blob\"}",
            "app": "web",
        ]

        let obj = GenericObject(UnstructuredResource(properties: ["kind": "Pod", "metadata": m]))
        let yaml = obj.renderYAML()

        // The two heavy, never-displayed bits are gone…
        XCTAssertFalse(yaml.contains("kubectl-client-side-apply"))
        XCTAssertFalse(yaml.contains("last-applied-configuration"))
        // …but real metadata survives.
        XCTAssertTrue(yaml.contains("app"))
        XCTAssertEqual(obj.name, "web")
        XCTAssertEqual(obj.id, "uid-1")
    }

    func testTrimmingIsANoOpWithoutHeavyMetadata() {
        let obj = object(kind: "Pod",
                         meta: objectMeta(name: "web", namespace: "default", uid: "uid-1"), [
            "spec": dict(["nodeName": "node-1"]),
        ])
        XCTAssertEqual(obj.nodeName, "node-1")   // untouched objects still parse
        XCTAssertEqual(obj.name, "web")
    }

    func testEventDefaults() {
        let obj = object(kind: "Event", meta: objectMeta(name: "evt"), [:])
        XCTAssertEqual(obj.eventMessage, "")
        XCTAssertEqual(obj.eventReason, "")
        XCTAssertEqual(obj.eventType, "Normal")   // defaults to Normal
        XCTAssertEqual(obj.eventCount, 0)
        XCTAssertEqual(obj.eventObject, "")
    }
}

/// Kubernetes quantity parsers — pure, suffix-sensitive, and easy to get subtly
/// wrong (these underpin every CPU/memory column).
final class QuantityParsingTests: XCTestCase {

    func testCPUMillicores() {
        XCTAssertEqual(ClusterService.cpuMillicores("250m"), 250)
        XCTAssertEqual(ClusterService.cpuMillicores("1"), 1000)         // whole cores
        XCTAssertEqual(ClusterService.cpuMillicores("2"), 2000)
        XCTAssertEqual(ClusterService.cpuMillicores("12345678n"), 12)   // nanocores (metrics-server)
        XCTAssertEqual(ClusterService.cpuMillicores("500000u"), 500)    // microcores
        XCTAssertEqual(ClusterService.cpuMillicores("garbage"), 0)
    }

    func testMemoryBytesBinarySuffixes() {
        XCTAssertEqual(ClusterService.memoryBytes("64Ki"), 65_536)
        XCTAssertEqual(ClusterService.memoryBytes("128Mi"), 134_217_728)
        XCTAssertEqual(ClusterService.memoryBytes("1Gi"), 1_073_741_824)
        XCTAssertEqual(ClusterService.memoryBytes("1Ti"), 1_099_511_627_776)
    }

    func testMemoryBytesDecimalSuffixesAndBare() {
        XCTAssertEqual(ClusterService.memoryBytes("1K"), 1_000)
        XCTAssertEqual(ClusterService.memoryBytes("1M"), 1_000_000)
        XCTAssertEqual(ClusterService.memoryBytes("1G"), 1_000_000_000)
        XCTAssertEqual(ClusterService.memoryBytes("12345"), 12_345)     // bare bytes
        XCTAssertEqual(ClusterService.memoryBytes("garbage"), 0)
    }
}
