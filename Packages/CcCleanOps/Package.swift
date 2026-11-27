// swift-tools-version:6.1
import PackageDescription

let package = Package(
    name: "CcCleanOps",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CcCleanOps", targets: ["CcCleanOps"])
    ],
    dependencies: [
        .package(path: "../CcCleanCore"),
        .package(path: "../CcCleanFS")
    ],
    targets: [
        .target(
            name: "CcCleanOps",
            dependencies: [
                .product(name: "CcCleanCore", package: "CcCleanCore"),
                .product(name: "CcCleanFS", package: "CcCleanFS")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "CcCleanOpsTests",
            dependencies: ["CcCleanOps"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)