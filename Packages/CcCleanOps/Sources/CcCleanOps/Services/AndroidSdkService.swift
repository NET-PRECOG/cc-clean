import Foundation
import CcCleanCore

/// Android SDK / AVD / 系统镜像管理（M1，基线 7.5）：
/// ANDROID_HOME 探测、SDK 组件枚举、AVD ini 解析、镜像删除前引用检查（DoD：删除不影响已建工程编译）。
public struct AndroidSdkService: Sendable {

    public init() {}

    // MARK: - SDK Home 探测

    /// 探测顺序：ANDROID_HOME → ANDROID_SDK_ROOT → ~/Library/Android/sdk → /opt/android-sdk。
    /// 以 platform-tools 存在为有效判定。
    public func resolveSdkHome(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory()
    ) -> String? {
        let candidates = [
            environment["ANDROID_HOME"],
            environment["ANDROID_SDK_ROOT"],
            home + "/Library/Android/sdk",
            "/opt/android-sdk",
        ].compactMap { $0 }
        let fm = FileManager.default
        for candidate in candidates where fm.fileExists(atPath: candidate + "/platform-tools") {
            return candidate
        }
        return nil
    }

    // MARK: - SDK 组件

    public struct SdkComponent: Sendable, Equatable {
        public let kind: String      // platform / build-tools / ndk / cmdline-tools / system-image
        public let name: String
        public let path: String
        public let relativePath: String   // 相对 sdkHome（image.sysdir.1 同源格式）

        public init(kind: String, name: String, path: String, relativePath: String) {
            self.kind = kind
            self.name = name
            self.path = path
            self.relativePath = relativePath
        }
    }

    /// SDK 组件枚举（目录型组件：platforms / build-tools / ndk / cmdline-tools）。
    public func listSdkComponents(sdkHome: String) -> [SdkComponent] {
        let specs: [(kind: String, dir: String)] = [
            ("platform", "platforms"),
            ("build-tools", "build-tools"),
            ("ndk", "ndk"),
            ("cmdline-tools", "cmdline-tools"),
        ]
        return Self.subdirectories(in: specs, sdkHome: sdkHome)
    }

    /// 系统镜像枚举（system-images/android-XX/<tag>/<abi>；三层叶子）。
    public func listSystemImages(sdkHome: String) -> [SdkComponent] {
        let fm = FileManager.default
        let root = sdkHome + "/system-images"
        guard let apiDirs = try? fm.contentsOfDirectory(atPath: root) else { return [] }
        var out: [SdkComponent] = []
        for api in apiDirs.sorted() {
            let apiDir = root + "/" + api
            guard let tags = try? fm.contentsOfDirectory(atPath: apiDir) else { continue }
            for tag in tags.sorted() {
                let tagDir = apiDir + "/" + tag
                guard let abis = try? fm.contentsOfDirectory(atPath: tagDir) else { continue }
                for abi in abis.sorted() {
                    let imageDir = tagDir + "/" + abi
                    var isDir: ObjCBool = false
                    guard fm.fileExists(atPath: imageDir, isDirectory: &isDir), isDir.boolValue else { continue }
                    let rel = "system-images/\(api)/\(tag)/\(abi)"
                    out.append(SdkComponent(
                        kind: "system-image", name: "\(api)/\(tag)/\(abi)",
                        path: imageDir, relativePath: rel))
                }
            }
        }
        return out
    }

    private static func subdirectories(
        in specs: [(kind: String, dir: String)], sdkHome: String
    ) -> [SdkComponent] {
        let fm = FileManager.default
        var out: [SdkComponent] = []
        for spec in specs {
            let dir = sdkHome + "/" + spec.dir
            guard let names = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for name in names.sorted() {
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: dir + "/" + name, isDirectory: &isDir), isDir.boolValue {
                    out.append(SdkComponent(
                        kind: spec.kind, name: name,
                        path: dir + "/" + name,
                        relativePath: spec.dir + "/" + name))
                }
            }
        }
        return out
    }

    // MARK: - AVD

    public struct AvdEntry: Sendable, Equatable {
        public let name: String
        public let path: String          // .avd 目录
        public let imageTarget: String?  // config.ini 的 image.sysdir.1（去尾斜杠）
    }

    /// AVD 解析：~/.android/avd/*.ini 的 path= → 各 .avd/config.ini 的 image.sysdir.1。
    public func listAvds(home: String) -> [AvdEntry] {
        let fm = FileManager.default
        let avdRoot = home + "/.android/avd"
        guard let inis = try? fm.contentsOfDirectory(atPath: avdRoot) else { return [] }
        var out: [AvdEntry] = []
        for ini in inis.sorted() where ini.hasSuffix(".ini") {
            let name = String(ini.dropLast(4))
            let iniPath = avdRoot + "/" + ini
            guard let iniText = try? String(contentsOfFile: iniPath, encoding: .utf8),
                  let pathLine = iniText.split(separator: "\n").first(where: { $0.hasPrefix("path=") })
            else { continue }
            let avdDir = String(pathLine.dropFirst("path=".count)).trimmingCharacters(in: .whitespaces)
            var target: String?
            if let configText = try? String(
                contentsOfFile: avdDir + "/config.ini", encoding: .utf8),
               let imageLine = configText.split(separator: "\n").first(where: { $0.hasPrefix("image.sysdir.1=") }) {
                target = String(imageLine.dropFirst("image.sysdir.1=".count))
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            }
            out.append(AvdEntry(name: name, path: avdDir, imageTarget: target))
        }
        return out
    }

    // MARK: - 镜像删除前引用检查

    /// 引用指定镜像（image.sysdir.1 相对路径）的 AVD 名称列表。
    /// 非空 → 删除操作应阻止（删除不影响已建 AVD/工程编译，基线 M1 DoD）。
    public func avdsReferencing(imageRelativePath: String, home: String) -> [String] {
        let normalized = imageRelativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return listAvds(home: home)
            .filter { $0.imageTarget == normalized }
            .map { $0.name }
    }
}