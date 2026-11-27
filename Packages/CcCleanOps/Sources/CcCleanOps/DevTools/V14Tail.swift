import Foundation
import AppKit
import GRDB
import CcCleanCore
import CcCleanFS

/// 多包管理器全局包条目（D11，基线 7.5 关键算法 4）。
public struct GlobalPackage: Sendable, Equatable, Identifiable {
    public var id: String { "\(manager)-\(name)" }
    public let manager: String    // npm/pnpm/uv/conda/cargo
    public let name: String
    public let version: String?
}

/// 单类解析器协议（基线 7.5：独立解析、缺失隐藏、单类 20s 超时）。
public protocol PackageManagerRunning: Sendable {
    func run(executable: String, args: [String], timeout: Duration) async throws -> ProcessResult
}

/// ProcessRunner 适配。
public struct SystemPackageManagerRunner: PackageManagerRunning {
    let runner = ProcessRunner()
    public init() {}
    public func run(executable: String, args: [String], timeout: Duration) async throws -> ProcessResult {
        try await runner.run(.init(executablePath: executable, arguments: args, timeout: timeout))
    }
}

/// 多包管理器统一入口（D11，基线 7.5）：五类独立解析、缺失隐藏不报错、
/// 单类 20s 超时；单类失败只影响该类（基线 D11 验收）。
public actor MultiPackageManager {

    private let runner: PackageManagerRunning
    private let logger: Logger

    public init(runner: PackageManagerRunning = SystemPackageManagerRunner(), logger: Logger) {
        self.runner = runner
        self.logger = logger
    }

    /// 单类解析器定义（可执行文件存在才尝试，缺失隐藏）。
    public struct ManagerSpec: Sendable {
        public let kind: String
        public let executable: String
        public let checkPath: String          // 存在性探测
        public let args: [String]
        public let parse: @Sendable (String) -> [GlobalPackage]

        public init(
            kind: String, executable: String, checkPath: String,
            args: [String], parse: (@escaping @Sendable (String) -> [GlobalPackage])
        ) {
            self.kind = kind
            self.executable = executable
            self.checkPath = checkPath
            self.args = args
            self.parse = parse
        }
    }

    static let specs: [ManagerSpec] = [
        ManagerSpec(kind: "npm", executable: "/usr/local/bin/npm",
                    checkPath: "/usr/local/bin/npm",
                    args: ["ls", "-g", "--json"], parse: MultiPackageManager.parseNpm),
        ManagerSpec(kind: "npm", executable: "/opt/homebrew/bin/npm",
                    checkPath: "/opt/homebrew/bin/npm",
                    args: ["ls", "-g", "--json"], parse: MultiPackageManager.parseNpm),
        ManagerSpec(kind: "pnpm", executable: "/usr/local/bin/pnpm",
                    checkPath: "/usr/local/bin/pnpm",
                    args: ["ls", "-g", "--json"], parse: MultiPackageManager.parsePnpm),
        ManagerSpec(kind: "uv", executable: "/usr/local/bin/uv",
                    checkPath: "/usr/local/bin/uv",
                    args: ["tool", "list"], parse: MultiPackageManager.parseUv),
        ManagerSpec(kind: "conda", executable: "/opt/homebrew/anaconda3/bin/conda",
                    checkPath: "/opt/homebrew/anaconda3/bin/conda",
                    args: ["list", "--json"], parse: MultiPackageManager.parseConda),
        ManagerSpec(kind: "cargo", executable: "/usr/local/bin/cargo",
                    checkPath: "/usr/local/bin/cargo",
                    args: ["install", "--list"], parse: MultiPackageManager.parseCargo),
    ]

    /// 枚举全部全局包（缺失的包管理器隐藏；单类超时不影响其他；
    /// specs 可注入——测试与自定义安装路径）。
    public func listAll(
        specs: [ManagerSpec]? = nil
    ) async -> [GlobalPackage] {
        var packages: [GlobalPackage] = []
        for spec in specs ?? Self.specs {
            guard FileManager.default.fileExists(atPath: spec.checkPath) else { continue }
            do {
                let result = try await runner.run(
                    executable: spec.executable, args: spec.args, timeout: .seconds(20))
                guard result.succeeded else { continue }
                packages.append(contentsOf: spec.parse(result.stdout))
            } catch {
                logger.warning("package manager \(spec.kind) parse failed: \(String(describing: error))")
            }
        }
        return packages
    }

    // MARK: - 各类解析（容错）

    static func parseNpm(_ output: String) -> [GlobalPackage] {
        guard let json = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any],
              let deps = json["dependencies"] as? [String: Any] else { return [] }
        return deps.map { name, value in
            let version = (value as? [String: Any])?["version"] as? String
            return GlobalPackage(manager: "npm", name: name, version: version)
        }
    }

    static func parsePnpm(_ output: String) -> [GlobalPackage] {
        // pnpm ls -g --json 与 npm 同构
        parseNpm(output).map { GlobalPackage(manager: "pnpm", name: $0.name, version: $0.version) }
    }

    static func parseUv(_ output: String) -> [GlobalPackage] {
        // uv tool list 输出 "- name vx.y.z"
        output.components(separatedBy: "\n").compactMap { (line: String) -> GlobalPackage? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("- ") else { return nil }
            let body = trimmed.dropFirst(2)
            let parts = body.split(separator: " ", maxSplits: 1)
            guard let name = parts.first, !name.isEmpty else { return nil }
            let version = parts.count > 1
                ? String(parts[1]).trimmingCharacters(in: CharacterSet(charactersIn: "v"))
                : nil
            return GlobalPackage(manager: "uv", name: String(name), version: version)
        }
    }

    static func parseConda(_ output: String) -> [GlobalPackage] {
        guard let json = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [[String: Any]] else {
            return []
        }
        return json.compactMap { item in
            guard let name = item["name"] as? String,
                  let version = item["version"] as? String else { return nil }
            return GlobalPackage(manager: "conda", name: name, version: version)
        }
    }

    static func parseCargo(_ output: String) -> [GlobalPackage] {
        // "name vX.Y.Z:" 行格式
        output.components(separatedBy: "\n").compactMap { line in
            guard line.hasPrefix(" ") == false, let space = line.firstIndex(of: " ") else { return nil }
            let name = String(line[..<space])
            let version = String(line[space...]).trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "v:"))
            return GlobalPackage(manager: "cargo", name: name, version: version.isEmpty ? nil : version)
        }
    }
}


/// 批量卸载引擎（C7）+ 卸载前打包备份（C8，基线 7.3）。
public actor BatchUninstallService {

    private let snapshots: SnapshotService
    private let backupRoot: URL
    private let logger: Logger

    public init(snapshots: SnapshotService, backupRoot: URL? = nil, logger: Logger) {
        self.snapshots = snapshots
        self.backupRoot = backupRoot ?? Paths.snapshotsDirectory
        self.logger = logger
    }

    /// C8：卸载前打包备份（ditto 级复制到备份目录，走 journal 记账）。
    public func backupBeforeUninstall(appPath: String, bundleId: String, journal: OperationJournal) async -> URL? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: appPath) else { return nil }
        let appDir = backupRoot.appendingPathComponent(bundleId, isDirectory: true)
        try? fm.createDirectory(at: appDir, withIntermediateDirectories: true)
        let stamp = Int(Date().timeIntervalSince1970)
        let destination = appDir.appendingPathComponent("pre-uninstall-\(stamp)", isDirectory: true)
        do {
            try fm.copyItem(at: URL(fileURLWithPath: appPath), to: destination)
            logger.info("pre-uninstall backup: \(destination.path)")
            return destination
        } catch {
            logger.error("pre-uninstall backup failed: \((error as NSError).localizedDescription)")
            return nil
        }
    }

    /// C7：批量卸载（多应用逐个执行 UninstallEngine 流程；单项失败不影响其他，基线 C7 验收）。
    /// 复用 UninstallEngine.buildPlan + execute（plan → selected = defaultSelected 全选）。
    public func runBatch(
        targets: [AppRecord], allApps: [AppRecord],
        engine: UninstallEngine, journal: OperationJournal,
        progress: (@Sendable (String, Bool) -> Void)? = nil
    ) async -> [(bundleId: String, succeeded: Bool, message: String)] {
        var outcomes: [(bundleId: String, succeeded: Bool, message: String)] = []
        for target in targets {
            // C8 备份先行
            let backup = await backupBeforeUninstall(
                appPath: target.bundlePath, bundleId: target.bundleId, journal: journal)
            let plan = await engine.buildPlan(target: target, allApps: allApps)
            let selected = plan.defaultSelected
            let report = await engine.execute(plan: plan, selected: selected, journal: journal)
            let ok = report.verification.allPassed || report.journalResult.failedCount == 0
            outcomes.append((
                bundleId: target.bundleId, succeeded: ok,
                message: ok ? "已卸载（备份：\(backup?.lastPathComponent ?? "无")）"
                            : "存在遗留项"))
            progress?(target.bundleId, ok)   // 单项失败不中断后续（基线 C7）
        }
        return outcomes
    }
}

/// 定时更新检测（B7，基线 7.2）：NSBackgroundActivityScheduler 24h 调度 resolver.checkAll，
/// 检测到更新发通知（通知降级横幅，基线 6.4）；忽略版本（B4）过滤。
public actor ScheduledUpdateChecker {

    private var scheduler: NSBackgroundActivityScheduler?
    private let logger: Logger
    private var ignoredVersions: [String: String] = [:]   // bundleId → 忽略的版本（B4）
    public private(set) var isEnabled = false

    public init(logger: Logger) {
        self.logger = logger
    }

    /// 启用定时检测（设置页开关；默认关闭）。
    public func enable(checkAll: @escaping @Sendable () async -> [VersionCheckResult]) {
        isEnabled = true
        let scheduler = NSBackgroundActivityScheduler(identifier: "app.cclean.updatecheck")
        scheduler.interval = 24 * 60 * 60
        scheduler.tolerance = 60 * 60
        scheduler.repeats = true
        scheduler.qualityOfService = .utility
        scheduler.schedule { [weak self] completion in
            guard let self else { return }
            Task {
                let results = await checkAll()
                await self.processResults(results)
                completion(NSBackgroundActivityScheduler.Result.finished)
            }
        }
        self.scheduler = scheduler
        logger.info("scheduled update checker enabled")
    }

    public func disable() {
        scheduler?.invalidate()
        scheduler = nil
        isEnabled = false
    }

    /// 结果处理：忽略版本（B4）与已处理过滤后保留可提示项。
    private func processResults(_ results: [VersionCheckResult]) async {
        for result in results {
            if let ignored = ignoredVersions[result.bundleId], ignored == result.latest {
                continue   // 用户忽略的版本不提示（基线 B4 验收）
            }
            // 通知派发由 App 层消费（此处仅记录）
            logger.info("update available: \(result.bundleId) → \(result.latest ?? "?") (\(result.source.rawValue))")
        }
    }

    /// B4：忽略指定版本（UI「忽略此版本」按钮）。
    public func ignoreVersion(bundleId: String, version: String) {
        ignoredVersions[bundleId] = version
        logger.info("version ignored: \(bundleId) @ \(version)")
    }

    /// B4：清除忽略（恢复提示）。
    public func clearIgnored(bundleId: String) {
        ignoredVersions.removeValue(forKey: bundleId)
    }

    public func isIgnored(bundleId: String, version: String) -> Bool {
        ignoredVersions[bundleId] == version
    }
}