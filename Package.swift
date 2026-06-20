// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Kates",
    platforms: [
        .macOS("14.4")   // conditional TableColumn content requires 14.4+
    ],
    products: [
        .executable(name: "Kates", targets: ["Kates"]),
        .library(name: "KubeKit", targets: ["KubeKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftkube/client.git", from: "0.26.0"),
        .package(url: "https://github.com/swiftkube/model.git", from: "0.19.0"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.0"),
    ],
    targets: [
        .target(
            name: "KubeKit",
            dependencies: [
                .product(name: "SwiftkubeClient", package: "client"),
                .product(name: "SwiftkubeModel", package: "model"),
                .product(name: "Yams", package: "Yams"),
            ]
        ),
        .executableTarget(
            name: "Kates",
            dependencies: ["KubeKit"]
        ),
        .testTarget(
            name: "KubeKitTests",
            dependencies: [
                "KubeKit",
                .product(name: "SwiftkubeClient", package: "client"),
            ]
        ),
    ]
)
