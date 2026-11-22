// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LocalizeWork",
    platforms: [.iOS(.v15), .macOS(.v12), .tvOS(.v15), .watchOS(.v8)],
    products: [
        .library(name: "LocalizeWork", targets: ["LocalizeWork"]),
    ],
    targets: [
        .target(
            name: "LocalizeWork",
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
        .testTarget(
            name: "LocalizeWorkTests",
            dependencies: ["LocalizeWork"]
        ),
    ]
)
