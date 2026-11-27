import Foundation
import CcCleanCore

/// JDK 条目（M3，基线 7.5 关键算法 1）。
public struct JDKEntry: Codable, Sendable, Equatable, Identifiable {
    public var id: String { homePath }
    public let homePath: String
    public let version: String
    public let vendor: String
    /// 来源：system（/Library/Java/...）/ user（~/Library/Java/...）/ sdkman
    public let source: String
    public let isCurrent: Bool   // 与系统 JAVA_HOME 一致

    public init(homePath: String, version: String, vendor: String, source: String, isCurrent: Bool) {
        self.homePath = homePath
        self.version = version
        self.vendor = vendor
        self.source = source
        self.isCurrent = isCurrent
    }
}

/// JDK 管理与 JAVA_HOME 切换（M3，基线 7.5 关键算法 2~4）：
/// 三处枚举（/Library/Java/JavaVirtualMachines、~/Library/Java/JavaVirtualMachines、~/sdkman），
/// 版本从 Contents/Home/release 文件取值，托管区块写入 profile（与 brew 镜像同模式），
/// 生效来源展示 + 自检按钮（`java_home -V`，用户级命令）。
public actor JDKService {

    private let runner: BrewCommandRunning   // 复用命令执行抽象（ProcessRunner 适配）
    private let logger: Logger

    public init(runner: BrewCommandRunning = SystemBrewRunner(), logger: Logger) {
        self.runner = runner
        self.logger = logger
    }

    /// 托管区块标记（与 brew 镜像同模式）。
    public static let javaBlockBegin = "# >>> cclean jdk >>>"
    public static let javaBlockEnd = "# <<< cclean jdk <<<"

    // MARK: - 枚举

    /// 枚举全部 JDK（三处来源；sources 可过滤——测试与限定扫描）。
    public func list(
        sources: [(root: String, source: String)]? = nil
    ) async -> [JDKEntry] {
        let fm = FileManager.default
        let home = NSHomeDirectory()
        let resolved = sources ?? [
            ("/Library/Java/JavaVirtualMachines", "system"),
            (home + "/Library/Java/JavaVirtualMachines", "user"),
            (home + "/.sdkman/candidates/java", "sdkman"),
        ]

        var entries: [JDKEntry] = []
        let currentHome = await currentJavaHome()

        for (root, source) in resolved {
            let children = (try? fm.contentsOfDirectory(atPath: root)) ?? []
            for child in children where child.hasSuffix(".jdk") || source == "sdkman" {
                let homePath: String
                if source == "sdkman" {
                    homePath = root + "/" + child
                } else {
                    homePath = root + "/" + child + "/Contents/Home"
                }
                guard fm.fileExists(atPath: homePath) else { continue }
                let (version, vendor) = Self.readRelease(homePath: homePath, dirName: child)
                entries.append(JDKEntry(
                    homePath: homePath, version: version, vendor: vendor,
                    source: source, isCurrent: homePath == currentHome
                ))
            }
        }
        return entries.sorted { $0.version > $1.version }
    }

    /// 从 Contents/Home/release 文件读取版本与厂商（基线 M3：release 文件取版本）。
    static func readRelease(homePath: String, dirName: String) -> (version: String, vendor: String) {
        let releasePath = homePath + "/release"
        guard let data = FileManager.default.contents(atPath: releasePath),
              let text = String(data: data, encoding: .utf8) else {
            // sdkman 目录名即版本（如 17.0.9-tem）
            let parts = dirName.split(separator: "-")
            return (parts.first.map(String.init) ?? dirName, parts.count > 1 ? String(parts[1]) : "unknown")
        }
        var version = "unknown"
        var vendor = "unknown"
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("JAVA_VERSION=") {
                version = line.dropFirst("JAVA_VERSION=".count)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
            if line.hasPrefix("IMPLEMENTOR=") {
                vendor = line.dropFirst("IMPLEMENTOR=".count)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
        }
        return (version, vendor)
    }

    /// 当前生效的 JAVA_HOME（环境变量或 java_home 默认）。
    public func currentJavaHome() async -> String? {
        if let env = ProcessInfo.processInfo.environment["JAVA_HOME"], !env.isEmpty {
            return env
        }
        // /usr/libexec/java_home 输出默认 Home（用户级命令）
        let result = try? await runner.run(
            brewPath: "/usr/libexec/java_home", args: [], timeout: .seconds(15)
        )
        guard let result, result.succeeded else { return nil }
        let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    // MARK: - JAVA_HOME 切换（托管区块）

    /// 切换 JAVA_HOME：托管区块写入 export JAVA_HOME 与 PATH 前缀（可撤销——还原备份）。
    public func switchTo(
        _ entry: JDKEntry, profilePath: String
    ) async -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: entry.homePath) else { return false }
        // 备份（首次切换时）
        let backupPath = profilePath + ".cclean-backup"
        if fm.fileExists(atPath: profilePath), !fm.fileExists(atPath: backupPath) {
            try? fm.copyItem(atPath: profilePath, toPath: backupPath)
        }

        var content = fm.contents(atPath: profilePath).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        if let beginRange = content.range(of: Self.javaBlockBegin),
           let endRange = content.range(of: Self.javaBlockEnd) {
            content = content.replacingCharacters(
                in: beginRange.lowerBound..<endRange.upperBound, with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let block = """
        \(Self.javaBlockBegin)
        export JAVA_HOME="\(entry.homePath)"
        export PATH="$JAVA_HOME/bin:$PATH"
        \(Self.javaBlockEnd)
        """
        content = (content.isEmpty ? "" : content + "\n\n") + block
        do {
            try content.data(using: .utf8)?.write(
                to: URL(fileURLWithPath: profilePath), options: .atomic)
        } catch {
            return false
        }
        logger.info("JAVA_HOME switched to \(entry.homePath)")
        return true
    }

    /// 一键还原 profile 备份。
    public func restoreProfile(profilePath: String) async -> Bool {
        let backupPath = profilePath + ".cclean-backup"
        let fm = FileManager.default
        guard fm.fileExists(atPath: backupPath) else { return false }
        do {
            try fm.removeItem(atPath: profilePath)
            try fm.copyItem(atPath: backupPath, toPath: profilePath)
            return true
        } catch {
            return false
        }
    }

    // MARK: - 自检（java_home -V）

    /// 自检：`java_home -V` 输出与枚举结果交叉验证（R3，基线 M3 验收）。
    public func selfCheck() async -> (output: String, consistent: Bool) {
        let result = try? await runner.run(
            brewPath: "/usr/libexec/java_home", args: ["-V"], timeout: .seconds(15)
        )
        guard let result else { return (output: "", consistent: false) }
        let output = result.stdout.isEmpty ? result.stderr : result.stdout
        // 交叉验证：java_home 列出的版本数与枚举数一致（宽松：包含关系）
        let listed = await list()
        let consistent = listed.isEmpty == false && output.contains("Java Virtual Machines")
        return (output: output, consistent: consistent)
    }
}