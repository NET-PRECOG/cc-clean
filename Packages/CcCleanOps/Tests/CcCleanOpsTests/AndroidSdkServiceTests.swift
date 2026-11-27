import Testing
import Foundation
@testable import CcCleanOps

@Suite("AndroidSdkService (M1)")
struct AndroidSdkServiceTests {

    func makeSdk(root: URL) throws -> String {
        let sdk = root.appendingPathComponent("AndroidSdk")
        for sub in ["platform-tools", "platforms/android-33", "build-tools/34.0.0",
                    "ndk/25.1", "cmdline-tools/latest", "system-images/android-33/google_apis/arm64-v8a",
                    "system-images/android-34/default/x86_64"] {
            try FileManager.default.createDirectory(
                at: sdk.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        return sdk.path
    }

    func makeAvd(root: URL, name: String, target: String?) throws {
        let avdDir = root.appendingPathComponent("avd/\(name).avd")
        try FileManager.default.createDirectory(at: avdDir, withIntermediateDirectories: true)
        let ini = """
        avd.ini.encoding=UTF-8
        path=\(avdDir.path)
        path.rel=avd/\(name).avd
        """
        try ini.data(using: .utf8)!.write(
            to: root.appendingPathComponent("avd/\(name).ini"))
        if let target {
            let config = "image.sysdir.1=\(target)/\n"
            try config.data(using: .utf8)!.write(to: avdDir.appendingPathComponent("config.ini"))
        }
    }

    @Test("ANDROID_HOME 探测：环境变量优先，无有效目录 → nil（不伪造）")
    func resolveSdkHome() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sdk-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sdk = try makeSdk(root: root)
        let service = AndroidSdkService()
        let home = root.appendingPathComponent("Home").path

        // 环境变量优先
        let fromEnv = service.resolveSdkHome(
            environment: ["ANDROID_HOME": sdk], home: home)
        #expect(fromEnv == sdk)
        // 无环境变量 → 用户目录候选（sdk 不在 ~/Library/Android/sdk → nil）
        #expect(service.resolveSdkHome(environment: [:], home: home) == nil)
        // ANDROID_HOME 指向无效目录（无 platform-tools）→ 回退且无效 → nil
        #expect(service.resolveSdkHome(
            environment: ["ANDROID_HOME": root.path + "/empty"], home: home) == nil)
    }

    @Test("SDK 组件枚举：platforms/build-tools/ndk/cmdline-tools 目录名即版本")
    func listComponents() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sdk-c-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sdk = try makeSdk(root: root)
        let service = AndroidSdkService()

        let components = service.listSdkComponents(sdkHome: sdk)
        #expect(components.contains { $0.kind == "platform" && $0.name == "android-33" })
        #expect(components.contains { $0.kind == "build-tools" && $0.name == "34.0.0" })
        #expect(components.contains { $0.kind == "ndk" && $0.name == "25.1" })
        #expect(components.contains { $0.kind == "cmdline-tools" && $0.name == "latest" })
        // 组件枚举不含 system-images（单独方法）
        #expect(components.allSatisfy { $0.kind != "system-image" })
    }

    @Test("系统镜像枚举：三层路径 → relativePath 归一化（无尾斜杠）")
    func listSystemImages() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sdk-i-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sdk = try makeSdk(root: root)
        let service = AndroidSdkService()

        let images = service.listSystemImages(sdkHome: sdk)
        #expect(images.count == 2)
        #expect(images.contains {
            $0.name == "android-33/google_apis/arm64-v8a"
                && $0.relativePath == "system-images/android-33/google_apis/arm64-v8a"
        })
        #expect(images.contains { $0.name == "android-34/default/x86_64" })
    }

    @Test("AVD 解析：ini path= → config.ini image.sysdir.1（去尾斜杠）；无 config → target nil")
    func listAvds() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sdk-a-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("Home").path
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Home/.android"), withIntermediateDirectories: true)
        try makeAvd(root: root.appendingPathComponent("Home/.android"),
                    name: "Pixel_5", target: "system-images/android-33/google_apis/arm64-v8a")
        try makeAvd(root: root.appendingPathComponent("Home/.android"),
                    name: "Bare", target: nil)
        let service = AndroidSdkService()

        let avds = service.listAvds(home: home)
        #expect(avds.count == 2)
        let pixel = avds.first { $0.name == "Pixel_5" }
        #expect(pixel?.imageTarget == "system-images/android-33/google_apis/arm64-v8a")
        #expect(avds.first { $0.name == "Bare" }?.imageTarget == nil)
    }

    @Test("镜像删除前引用检查：被 AVD 引用 → 阻止（非空）；未引用 → 空列表")
    func imageReferenceCheck() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sdk-r-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("Home").path
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Home/.android"), withIntermediateDirectories: true)
        try makeAvd(root: root.appendingPathComponent("Home/.android"),
                    name: "Pixel_5", target: "system-images/android-33/google_apis/arm64-v8a")
        let service = AndroidSdkService()

        // 被 Pixel_5 引用 → 不可删
        let blocked = service.avdsReferencing(
            imageRelativePath: "system-images/android-33/google_apis/arm64-v8a/", home: home)
        #expect(blocked == ["Pixel_5"])
        // 未被引用 → 可删
        #expect(service.avdsReferencing(
            imageRelativePath: "system-images/android-34/default/x86_64", home: home).isEmpty)
    }
}