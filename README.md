<div align="center">
<img src="Docs/icon.png" width="256" alt="Kates icon" />

# Kates

</div>

Kates is a native macOS application for working with Kubernetes clusters. It talks to the Kubernetes API directly over mutually-authenticated TLS — there are no `kubectl` shell-outs and no embedded web browser — so it starts quickly, stays responsive, and feels like a Mac app rather than a website in a window.

You point Kates at a kubeconfig, and it discovers every resource type your cluster exposes, lets you browse and search them in live tables, and gives you the everyday tools you reach for in `kubectl`: logs, resource usage, events, and a handful of safe actions.

## Features

### Browse anything in the cluster

The sidebar is built from the cluster's own API discovery endpoints rather than a fixed list, so every resource type appears automatically — the built-in kinds, everything under `apps` and the other API groups, and the custom resources defined by any installed CRDs. Types are grouped by API group so the list stays organized even on a busy cluster.

You can switch between kube contexts and namespaces from the toolbar, or choose **All Namespaces** to view a resource across the entire cluster at once. Every table column is sortable, and the tables refresh themselves automatically on an interval you control (anywhere from one second to ten, or off entirely).

### See what's happening

- **Logs.** Selecting a pod opens a log pane right in the detail view. It starts by tailing the most recent lines and then follows the stream live. You can turn following off, pull the complete log on demand, switch between containers, and copy the buffer.
- **Resource usage.** When `metrics-server` is available, Kates shows live CPU and memory for both pods and nodes. For pods it also computes usage as a percentage of the configured requests and limits, and flags anything running over its limit.
- **Events.** The Events view is laid out like `kubectl events` — last-seen time, type, reason, involved object, and the full message — sorted with the most recent at the top.
- **YAML.** Every object has a YAML view rendered in the same style as `kubectl get -o yaml`, with one-click copy.

### Act on workloads

Kates covers the most common day-to-day operations: delete a pod, scale a deployment, inspect the individual containers inside a pod (with their state, restart counts, and images), and see which pods are scheduled onto a given node.

## Installation

Download the latest release from the [Releases page](https://github.com/thejefflarson/kates/releases/latest), move `Kates.app` to your Applications folder, and open it. Kates checks for updates automatically using [Sparkle](https://sparkle-project.org); you can also trigger a check from **Kates → Check for Updates…**.

On first launch, open **Open Kubeconfig…** in the toolbar and select your kubeconfig file. Kates remembers your choice for next time.

> [!NOTE]
> Applications launched from Finder or the Dock do not inherit your shell's `$KUBECONFIG` environment variable. This is why Kates asks you to choose the file explicitly rather than guessing — and why the first thing you'll see is the **Open Kubeconfig…** button.

## Building from source

Kates is a Swift Package; there is no Xcode project to manage.

```bash
# Assemble a double-clickable, optimized Kates.app
./scripts/bundle.sh

# Or, for fast iteration during development
swift run
```

`scripts/bundle.sh` compiles the app in release configuration, renders the icon into an `.icns`, embeds the Sparkle framework, and assembles `Kates.app` with its `Info.plist`. Pass `debug` (`./scripts/bundle.sh debug`) to produce an unoptimized bundle far more quickly while developing.

### Requirements

- macOS 14.4 or later
- A Swift 6 toolchain (Xcode 16 or later)
- A reachable cluster and a kubeconfig

### Running the tests

```bash
swift test
```

The test suite covers KubeKit in isolation — display formatting, metric quantity parsing, and kubeconfig parsing — and does not require a live cluster.

## How it's built

Kates is split into two targets. **KubeKit** is a small library that owns everything to do with talking to Kubernetes; it is the only part of the codebase that imports [SwiftkubeClient](https://github.com/swiftkube/client). **Kates** is the SwiftUI application, which depends only on KubeKit's own types. Because the entire client surface is wrapped behind a single `ClusterService`, replacing or upgrading the underlying client would touch one file rather than the whole app.

```
┌──────────────────────────────────────────────────────────────┐
│  Kates  (SwiftUI application)                                  │
│                                                                │
│   AppModel (@Observable) drives the UI:                        │
│     • ContentView      — sidebar of discovered types + toolbar │
│     • ResourceListView — the live, sortable resource table     │
│     • DetailView       — YAML, containers, and actions         │
│         └─ LogPane     — embedded, follows logs live           │
│                              │                                 │
│                              ▼                                 │
│  KubeKit  (the cluster boundary)                               │
│     ClusterService — discovery, generic listing, logs,         │
│                      metrics, scale, delete, per-context conn. │
│     ContextStore   — kubeconfig loading and context selection  │
│     Discovery      — API resource types and generic objects    │
└──────────────────────────────────────────────────────────────┘
```

The networking stack is SwiftNIO and AsyncHTTPClient (by way of SwiftkubeClient and [SwiftkubeModel](https://github.com/swiftkube/model)), YAML rendering uses [Yams](https://github.com/jpsim/Yams), and automatic updates use [Sparkle](https://github.com/sparkle-project/Sparkle). It is pure Swift and SwiftUI throughout — no Electron and no web runtime.

## Project layout

```
Sources/
├── KubeKit/      Cluster boundary — ClusterService, ContextStore, Discovery,
│                 display helpers, and errors. Imports SwiftkubeClient/Model.
└── Kates/        SwiftUI app — KatesApp, AppModel, the views, the Sparkle
                  updater, and the kubeconfig file picker.

Tests/            KubeKit unit tests.
scripts/          make_icon.swift (icon renderer), bundle.sh (.app assembly),
                  and release.sh (signed, notarized, Sparkle-published release).
appcast.xml       The Sparkle update feed.
```

## Releasing

Releases are cut with `scripts/release.sh`, which builds and signs the app, packages it, signs the package for Sparkle, appends an entry to `appcast.xml`, and publishes a GitHub release:

```bash
./scripts/release.sh v0.2.0
```

The script expects an Ed25519 key pair for signing updates (generated once with Sparkle's `generate_keys`, with the public half recorded in the app's `Info.plist`) and, for a Gatekeeper-friendly download, an Apple Developer ID certificate plus notarization credentials. See the comments at the top of the script for the one-time setup. Sparkle clients read the feed from `appcast.xml` on `main`.

## License

Kates is released under the [MIT License](LICENSE).
