// swift-tools-version:6.1
import PackageDescription

let package = Package(
    name: "CcCleanCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CcCleanCore", targets: ["CcCleanCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.5.0")
    ],
    targets: [
        .target(
            name: "CcCleanCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "CcCleanCoreTests",
            dependencies: ["CcCleanCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)