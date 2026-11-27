// swift-tools-version:6.1
import PackageDescription

let package = Package(
    name: "CcCleanMetrics",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CcCleanMetrics", targets: ["CcCleanMetrics"])
    ],
    dependencies: [
        .package(path: "../CcCleanCore")
    ],
    targets: [
        .target(
            name: "CcCleanMetrics",
            dependencies: [.product(name: "CcCleanCore", package: "CcCleanCore")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "CcCleanMetricsTests",
            dependencies: ["CcCleanMetrics"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)