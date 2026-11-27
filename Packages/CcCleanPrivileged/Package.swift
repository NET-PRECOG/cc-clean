// swift-tools-version:6.1
import PackageDescription

let package = Package(
    name: "CcCleanPrivileged",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CcCleanPrivileged", targets: ["CcCleanPrivileged"])
    ],
    dependencies: [
        .package(path: "../CcCleanCore")
    ],
    targets: [
        .target(
            name: "CcCleanPrivileged",
            dependencies: [.product(name: "CcCleanCore", package: "CcCleanCore")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "CcCleanPrivilegedTests",
            dependencies: ["CcCleanPrivileged"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)