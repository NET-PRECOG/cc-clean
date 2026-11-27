// swift-tools-version:6.1
import PackageDescription

/// 开发聚合 workspace：无完整 Xcode 环境下用 `swift build` / `swift test`
/// 编译验证全部本地包。Xcode 工程就绪后，App/Helper/Widgets target 直接引用
/// Packages/ 下各包，本文件仅承载 CcCleanCLI 与 CcCleanApp 两个 target。
let package = Package(
    name: "CcClean",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "Packages/CcCleanCore"),
        .package(path: "Packages/CcCleanFS"),
        .package(path: "Packages/CcCleanOps"),
        .package(path: "Packages/CcCleanMetrics"),
        .package(path: "Packages/CcCleanPrivileged")
    ],
    targets: [
        .executableTarget(
            name: "CcCleanCLI",
            dependencies: [
                .product(name: "CcCleanCore", package: "CcCleanCore"),
                .product(name: "CcCleanFS", package: "CcCleanFS"),
                .product(name: "CcCleanOps", package: "CcCleanOps"),
                .product(name: "CcCleanMetrics", package: "CcCleanMetrics"),
                .product(name: "CcCleanPrivileged", package: "CcCleanPrivileged")
            ],
            path: "Targets/CcCleanCLI",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "CcCleanApp",
            dependencies: [
                .product(name: "CcCleanCore", package: "CcCleanCore"),
                .product(name: "CcCleanFS", package: "CcCleanFS"),
                .product(name: "CcCleanOps", package: "CcCleanOps"),
                .product(name: "CcCleanMetrics", package: "CcCleanMetrics"),
                .product(name: "CcCleanPrivileged", package: "CcCleanPrivileged")
            ],
            path: "Targets/CcCleanApp",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "CcCleanHelper",
            dependencies: [
                .product(name: "CcCleanCore", package: "CcCleanCore"),
                .product(name: "CcCleanPrivileged", package: "CcCleanPrivileged")
            ],
            path: "Targets/CcCleanHelper",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "CcCleanWidget",
            dependencies: [
                .product(name: "CcCleanCore", package: "CcCleanCore")
            ],
            path: "Targets/CcCleanWidget",
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)