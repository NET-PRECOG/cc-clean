// swift-tools-version:6.1
import PackageDescription

let package = Package(
    name: "CcCleanFS",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CcCleanFS", targets: ["CcCleanFS"])
    ],
    dependencies: [
        .package(path: "../CcCleanCore")
    ],
    targets: [
        .target(
            name: "CcCleanFS",
            dependencies: [.product(name: "CcCleanCore", package: "CcCleanCore")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "CcCleanFSTests",
            dependencies: ["CcCleanFS"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)