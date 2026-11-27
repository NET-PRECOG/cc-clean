import Foundation
import CcCleanCore
import CcCleanFS

/// brew 命令执行协议（测试注入 Fake，基线 13.1；真实实现走 ProcessRunner 唯一出口）。
public protocol BrewCommandRunning: Sendable {
    func run(brewPath: String, args: [String], timeout: Duration) async throws -> ProcessResult
}

/// ProcessRunner 适配。
public struct SystemBrewRunner: BrewCommandRunning {
    let runner = ProcessRunner()

    public init() {}

    public func run(brewPath: String, args: [String], timeout: Duration) async throws -> ProcessResult {
        try await runner.run(.init(
            executablePath: brewPath, arguments: args,
            environment: BrewService.fixedEnvironment, timeout: timeout
        ))
    }
}

/// brew 路径解析（基线 7.4 BrewPathResolver）。
public enum BrewPathResolver {

    /// 候选路径：Apple Silicon 优先，回退 Intel。
    public static let candidates = [
        "/opt/homebrew/bin/brew",
        "/usr/local/bin/brew",
    ]

    /// 探测 brew 位置（首个存在的候选）。
    public static func resolve() -> String? {
        candidates.first { FileManager.default.fileExists(atPath: $0) }
    }
}

/// brew 包记录（D1，对应基线 7.4 BrewPackageRecord）。
public struct BrewFormula: Codable, Sendable, Equatable {
    public let name: String
    public let installedVersion: String?
    public let latestVersion: String?
    public let outdated: Bool
    public let pinned: Bool

    public init(name: String, installedVersion: String?, latestVersion: String?, outdated: Bool, pinned: Bool) {
        self.name = name
        self.installedVersion = installedVersion
        self.latestVersion = latestVersion
        self.outdated = outdated
        self.pinned = pinned
    }
}

public struct BrewCask: Codable, Sendable, Equatable {
    public let token: String
    public let installedVersion: String?
    public let latestVersion: String?
    public let outdated: Bool
    /// cask 定义了 zap 段（--zap 可用）
    public let hasZap: Bool

    public init(token: String, installedVersion: String?, latestVersion: String?, outdated: Bool, hasZap: Bool) {
        self.token = token
        self.installedVersion = installedVersion
        self.latestVersion = latestVersion
        self.outdated = outdated
        self.hasZap = hasZap
    }
}

public enum BrewServiceError: Error, Equatable {
    case brewNotFound
    case commandFailed(command: String, stderr: String)
}

/// BrewService（D1/D2，基线 7.4）：
/// list（--json=v2 容错解码，decodeIfPresent 全容错）、outdated、--zap 卸载 + ResidueScanner 复检联动。
/// 统一环境注入不继承用户 shell 变量（基线 7.4 要点 3）。
public actor BrewService {

    /// 固定环境（不继承用户 shell；基线 7.4 要点 3）
    public static let fixedEnvironment: [String: String] = [
        "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
        "HOME": NSHomeDirectory(),
        "HOMEBREW_NO_AUTO_UPDATE": "1",
        "HOMEBREW_NO_INSTALL_CLEANUP": "1",
        "LC_ALL": "en_US.UTF-8",
    ]

    private let runner: BrewCommandRunning
    private let logger: Logger

    public private(set) var brewPath: String?

    public init(runner: BrewCommandRunning = SystemBrewRunner(), brewPath: String? = nil, logger: Logger) {
        self.runner = runner
        self.logger = logger
        self.brewPath = brewPath ?? BrewPathResolver.resolve()
    }

    /// 测试与显式重设入口（internal，@testable 可访问）。
    func setBrewPath(_ path: String?) {
        self.brewPath = path
    }

    // MARK: - D1 列表与更新

    /// formula 列表（含 outdated 标记）。
    public func listFormulae() async throws -> [BrewFormula] {
        let json = try await runJSON(["info", "--json=v2", "--installed"])
        return Self.decodeFormulae(from: json)
    }

    /// cask 列表（含 hasZap 标记，供 D2）。
    public func listCasks() async throws -> [BrewCask] {
        let json = try await runJSON(["info", "--json=v2", "--cask", "--installed"])
        return Self.decodeCasks(from: json)
    }

    /// brew info --json=v2 容错解码（基线 D1 验收：可选字段容错不崩溃）。
    /// 可选字段缺失/类型不符 → nil；两个数组均可缺失 → 空列表。
    public static func decodeFormulae(from data: Data) -> [BrewFormula] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        guard let formulae = json["formulae"] as? [[String: Any]] else { return [] }
        return formulae.compactMap { item in
            guard let name = item["name"] as? String else { return nil }
            let installed = (item["installed"] as? [[String: Any]])?.compactMap { $0["version"] as? String }
            let installedVersion = installed?.first
            let latest = item["current"] as? String
            let outdated = (item["outdated"] as? Bool) ?? false
            let pinned = (item["pinned"] as? Bool) ?? false
            return BrewFormula(
                name: name, installedVersion: installedVersion,
                latestVersion: latest, outdated: outdated, pinned: pinned
            )
        }
    }

    public static func decodeCasks(from data: Data) -> [BrewCask] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        guard let casks = json["casks"] as? [[String: Any]] else { return [] }
        return casks.compactMap { item in
            guard let token = item["token"] as? String else { return nil }
            let installed = (item["installed"] as? String)
            let version = item["version"] as? String
            let outdated = (item["outdated"] as? Bool) ?? false
            // zap 段存在（任意形式）即视为可 --zap
            let hasZap = item["zap"] != nil
            return BrewCask(
                token: token, installedVersion: installed,
                latestVersion: version, outdated: outdated, hasZap: hasZap
            )
        }
    }

    // MARK: - D2 --zap 卸载 + 复检联动

    /// --zap 卸载 cask：brew zap（用户级，ProcessRunner）→ ResidueScanner 复检。
    /// 命令 argv 在 UI 层预览后调用（基线 7.4 要点 6：写操作前展示命令并记账）。
    public func zapCask(
        token: String,
        journal: OperationJournal,
        residueScanner: ResidueScanner,
        target: AppRecord,
        allApps: [AppRecord]
    ) async -> (zapOK: Bool, residueCheck: [ResidueItem], failed: [String: String]) {
        guard let brewPath else {
            return (false, [], ["brew": "未找到 Homebrew"])
        }
        let id = await journal.begin("brew zap \(token)")
        // argv 记账：brew zap --cask <token>（用户级白名单命令，OperationJournal 直跑）
        try? await journal.append(
            .runWhitelistedCommand(executable: brewPath, args: ["uninstall", "--zap", "--cask", token]),
            to: id
        )
        let result = await journal.commit(id)
        let zapOK = result.succeededCount > 0

        // D2 验收：zap 后自动 ResidueScanner 复检
        var residue: [ResidueItem] = []
        if zapOK {
            let plan = await residueScanner.scan(target: target, allApps: allApps)
            residue = plan.items
        }
        let failed = result.results.first?.failed ?? [:]
        return (zapOK, residue, failed)
    }

    // MARK: - D6 doctor 可视图（分类：error/warning/suggestion，可复制修复命令）

    public struct DoctorFinding: Codable, Sendable, Equatable {
        public enum Severity: String, Codable, Sendable {
            case warning, suggestion, error
        }

        public let severity: Severity
        public let message: String
        /// 提示性修复命令（brew doctor 无自动修复；不自动执行，基线 D6）
        public let fixHint: String?
    }

    /// brew doctor 输出解析为分类视图。
    public func doctor() async throws -> [DoctorFinding] {
        let result = try await runRaw(["doctor"])
        // brew doctor 非零退出也可能有输出（问题存在时退出码 1）
        let text = result.stdout.isEmpty ? result.stderr : result.stdout

        // 按非空行块分段（brew doctor 每个问题一个段落）
        let paragraphs = text.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return paragraphs.map { paragraph in
            let firstLine = paragraph.components(separatedBy: "\n").first ?? paragraph
            let severity: DoctorFinding.Severity
            var fixHint: String?
            if firstLine.contains("Error") || firstLine.contains("error") {
                severity = .error
                fixHint = "运行 `brew doctor` 查看详细说明，通常需要重装相关 formula"
            } else if firstLine.contains("Warning") || firstLine.contains("warning") {
                severity = .warning
                fixHint = "按提示运行修复命令（如 `brew cleanup`、`brew update`）"
            } else {
                severity = .suggestion
                fixHint = paragraph.hasPrefix("Please")
                    ? "按提示执行（不自动执行，可复制命令）"
                    : nil
            }
            return DoctorFinding(severity: severity, message: paragraph, fixHint: fixHint)
        }
    }

    // MARK: - D7 缓存清理（-n 预览 → 二次确认 → 执行记账）

    public struct CleanupPreview: Codable, Sendable, Equatable {
        public let bytesToFree: Int64
        /// 将删除的路径清单（预览与执行一致性核对）
        public let paths: [String]
        public let rawOutput: String
    }

    /// `brew cleanup -n` 预览（基线 D7 验收：误差 < 5%）。
    public func cleanupPreview() async throws -> CleanupPreview {
        let result = try await runRaw(["cleanup", "-n"])
        // 解析 "Would remove: <path> (x.x MB)" 行
        var bytes: Int64 = 0
        var paths: [String] = []
        let sizeRegex = try NSRegularExpression(pattern: #"\(([\d.]+)\s*(KB|MB|GB|B)\)"#)
        for line in result.stdout.components(separatedBy: "\n")
        where line.contains("Would remove") || line.contains("Would free") {
            if let range = line.range(of: ": ") {
                let body = String(line[range.upperBound...])
                let candidates = body.components(separatedBy: ", ")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                for candidate in candidates {
                    let matches = sizeRegex.matches(
                        in: candidate, range: NSRange(candidate.startIndex..., in: candidate))
                    if let match = matches.first, match.numberOfRanges > 2,
                       let sizeRange = Range(match.range(at: 1), in: candidate),
                       let unitRange = Range(match.range(at: 2), in: candidate) {
                        let value = Double(candidate[sizeRange]) ?? 0
                        let unit = String(candidate[unitRange]).uppercased()
                        let multiplier: Double = unit == "GB" ? 1_073_741_824 : (unit == "MB" ? 1_048_576 : (unit == "KB" ? 1024 : 1))
                        bytes += Int64(value * multiplier)
                        let cut = candidate.index(candidate.startIndex, offsetBy: match.range.location > 0 ? match.range.location : 0)
                        let pathPart = String(candidate[..<cut]).trimmingCharacters(in: .whitespaces)
                        if !pathPart.isEmpty { paths.append(pathPart) }
                    } else if candidate.hasPrefix("/") {
                        paths.append(candidate)
                    }
                }
            }
        }
        return CleanupPreview(bytesToFree: bytes, paths: paths, rawOutput: result.stdout)
    }

    /// 执行 `brew cleanup`（走 journal runWhitelistedCommand 记账，基线 D7：清理后可审计）。
    public func cleanupExecute(journal: OperationJournal) async -> Bool {
        guard let brewPath else { return false }
        let id = await journal.begin("brew cleanup")
        try? await journal.append(
            .runWhitelistedCommand(executable: brewPath, args: ["cleanup"]),
            to: id
        )
        let result = await journal.commit(id)
        return result.succeededCount > 0
    }

    // MARK: - D8 cask 搜索与安装

    /// `brew search --cask <query>`（token 列表）。
    public func searchCasks(_ query: String) async throws -> [String] {
        let result = try await runRaw(["search", "--cask", query])
        return result.stdout.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("==>") && !$0.hasPrefix("Cask") }
    }

    /// 安装 cask（走 journal 记账，argv 可预览）。
    public func installCask(_ token: String, journal: OperationJournal) async -> Bool {
        guard let brewPath else { return false }
        let id = await journal.begin("安装 cask \(token)")
        try? await journal.append(
            .runWhitelistedCommand(executable: brewPath, args: ["install", "--cask", token]),
            to: id
        )
        let result = await journal.commit(id)
        return result.succeededCount > 0
    }

    /// 卸载 cask（可选 --zap，走 journal 记账；zap 后建议 ResidueScanner 复检——D2 联动）。
    public func uninstallCask(_ token: String, zap: Bool, journal: OperationJournal) async -> Bool {
        guard let brewPath else { return false }
        var args = ["uninstall", "--cask"]
        if zap { args.append("--zap") }
        args.append(token)
        let id = await journal.begin("卸载 cask \(token)\(zap ? "（--zap）" : "")")
        try? await journal.append(
            .runWhitelistedCommand(executable: brewPath, args: args),
            to: id
        )
        let result = await journal.commit(id)
        return result.succeededCount > 0
    }

    // MARK: - D9 多版本 link 切换（formula 版本共存：link/unlink）

    /// link formula（启用某版本，走 journal 记账）。
    public func linkFormula(_ name: String, journal: OperationJournal) async -> Bool {
        guard let brewPath else { return false }
        let id = await journal.begin("link \(name)")
        try? await journal.append(
            .runWhitelistedCommand(executable: brewPath, args: ["link", name]),
            to: id
        )
        let result = await journal.commit(id)
        return result.succeededCount > 0
    }

    /// unlink formula（停用当前版本，可撤销——重新 link）。
    public func unlinkFormula(_ name: String, journal: OperationJournal) async -> Bool {
        guard let brewPath else { return false }
        let id = await journal.begin("unlink \(name)")
        try? await journal.append(
            .runWhitelistedCommand(executable: brewPath, args: ["unlink", name]),
            to: id
        )
        let result = await journal.commit(id)
        return result.succeededCount > 0
    }

    /// 列出某 formula 的已安装版本（Cellar 目录枚举）。
    public func installedVersions(of name: String) async -> [String] {
        guard let brewPath else { return [] }
        guard let cellarResult = try? await runner.run(
            brewPath: brewPath, args: ["--cellar"], timeout: .seconds(15)
        ), cellarResult.succeeded else { return [] }
        let cellar = cellarResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let formulaDir = cellar + "/" + name
        return ((try? FileManager.default.contentsOfDirectory(atPath: formulaDir)) ?? []).sorted()
    }

    // MARK: - D10 国内镜像源切换（备份 → 切换 → 一键还原）

    public enum BrewMirror: String, CaseIterable, Sendable {
        case official   // 官方（清除覆盖）
        case tsinghua   // 清华 TUNA
        case ustc       // 中科大
        case aliyun     // 阿里云

        public var apiDomain: String {
            switch self {
            case .official: return ""
            case .tsinghua: return "https://mirrors.tuna.tsinghua.edu.cn/homebrew-birrors/api"
            case .ustc: return "https://mirrors.ustc.edu.cn/homebrew-bottles/api"
            case .aliyun: return "https://mirrors.aliyun.com/homebrew/api"
            }
        }

        public var bottleDomain: String {
            switch self {
            case .official: return ""
            case .tsinghua: return "https://mirrors.tuna.tsinghua.edu.cn/homebrew-birrors/bottles"
            case .ustc: return "https://mirrors.ustc.edu.cn/homebrew-bottles"
            case .aliyun: return "https://mirrors.aliyun.com/homebrew/bottles"
            }
        }
    }

    /// 托管区块标记（与 M3 JDK 同模式：# >>> cclean brew >>> ... # <<< cclean brew <<<）。
    static let brewBlockBegin = "# >>> cclean brew >>>"
    static let brewBlockEnd = "# <<< cclean brew <<<"

    /// 切换镜像：备份 shell profile 原内容 → 托管区块写入环境导出 → 更新后生效需重开终端。
    public func switchMirror(
        _ mirror: BrewMirror, profilePath: String
    ) async -> Bool {
        let fm = FileManager.default
        // 备份原 profile（首次切换时）
        let backupPath = profilePath + ".cclean-backup"
        if fm.fileExists(atPath: profilePath), !fm.fileExists(atPath: backupPath) {
            try? fm.copyItem(atPath: profilePath, toPath: backupPath)
        }
        // 移除旧托管区块后写入新区块（official 清除覆盖）
        var content = fm.contents(atPath: profilePath).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        if let beginRange = content.range(of: Self.brewBlockBegin),
           let endRange = content.range(of: Self.brewBlockEnd) {
            content = content.replacingCharacters(
                in: beginRange.lowerBound..<endRange.upperBound, with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if mirror != .official {
            let block = """
            \(Self.brewBlockBegin)
            export HOMEBREW_API_DOMAIN="\(mirror.apiDomain)"
            export HOMEBREW_BOTTLE_DOMAIN="\(mirror.bottleDomain)"
            \(Self.brewBlockEnd)
            """
            content = (content.isEmpty ? "" : content + "\n\n") + block
        }
        do {
            try content.data(using: .utf8)?.write(
                to: URL(fileURLWithPath: profilePath), options: .atomic)
        } catch {
            return false
        }
        logger.info("brew mirror switched: \(mirror.rawValue)")
        return true
    }

    /// 一键还原：备份文件回写（D10 验收：还原可用）。
    public func restoreMirror(profilePath: String) async -> Bool {
        let backupPath = profilePath + ".cclean-backup"
        let fm = FileManager.default
        guard fm.fileExists(atPath: backupPath) else { return false }
        do {
            _ = try fm.replaceItemAt(
                URL(fileURLWithPath: profilePath),
                withItemAt: URL(fileURLWithPath: backupPath))
            return true
        } catch {
            do {
                try fm.removeItem(atPath: profilePath)
                try fm.copyItem(atPath: backupPath, toPath: profilePath)
                return true
            } catch {
                return false
            }
        }
    }

    // MARK: - D4 依赖树与反向依赖

    public struct DependencyNode: Codable, Sendable, Equatable {
        public let name: String
        public let isInstalled: Bool
        public var children: [DependencyNode]
    }

    /// `brew deps --tree <formula>` 解析为依赖树（两阶段：扁平解析 → 递归组装；层级按树形符号单元计数）。
    public func dependencyTree(formula: String) async throws -> DependencyNode? {
        let result = try await runRaw(["deps", "--tree", formula])
        let lines = result.stdout.components(separatedBy: "\n").filter { !$0.isEmpty }
        guard let rootLine = lines.first else { return nil }
        let rootName = rootLine.trimmingCharacters(in: .whitespaces)

        // 树形前缀单元计数（│ 三空格 / 四空格 / ├── / └── 各计一层；── 双字符导致
        // 字符数推断不稳定，改用符号单元）
        func treeDepth(_ line: String) -> Int {
            var depth = 0
            var s = line[...]
            while true {
                if s.hasPrefix("│   ") || s.hasPrefix("    ") {
                    depth += 1
                    s = s.dropFirst(4)
                } else if s.hasPrefix("├──") || s.hasPrefix("└──") {
                    depth += 1
                    break
                } else {
                    break
                }
            }
            return depth
        }

        struct FlatNode { let depth: Int; let name: String; let installed: Bool }
        let flats: [FlatNode] = lines.dropFirst().map { line in
            let depth = treeDepth(line)
            let name = line
                .trimmingCharacters(in: CharacterSet(charactersIn: "├─└│ "))
                .replacingOccurrences(of: "(not installed)", with: "")
                .trimmingCharacters(in: .whitespaces)
            return FlatNode(depth: depth, name: name, installed: !line.contains("not installed"))
        }
        guard !flats.isEmpty else {
            return DependencyNode(name: rootName, isInstalled: true, children: [])
        }

        // 递归组装：从 index 起收集 depth 层同级节点，更深层级挂到前一个兄弟
        func assemble(from index: Int, depth: Int) -> ([DependencyNode], Int) {
            var children: [DependencyNode] = []
            var i = index
            while i < flats.count {
                let flat = flats[i]
                if flat.depth < depth { break }
                if flat.depth > depth {
                    let (sub, next) = assemble(from: i, depth: flat.depth)
                    if !children.isEmpty {
                        children[children.count - 1].children = sub
                    }
                    i = next
                } else {
                    children.append(DependencyNode(name: flat.name, isInstalled: flat.installed, children: []))
                    i += 1
                }
            }
            return (children, i)
        }

        let (children, _) = assemble(from: 0, depth: 1)
        return DependencyNode(name: rootName, isInstalled: true, children: children)
    }

    /// `brew uses --installed <formula>` 反向依赖（删除前检查）。
    public func reverseDependencies(of formula: String) async throws -> [String] {
        let result = try await runRaw(["uses", "--installed", formula])
        return result.stdout.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    // MARK: - D12 安装/升级时间线

    public struct TimelineEntry: Codable, Sendable, Equatable {
        public let name: String
        public let installedAt: Date?
        public let onRequest: Bool
        public let asDependency: Bool
    }

    /// 安装/升级时间线（v2 JSON installed 数组的 installed_time 字段，按时间降序）。
    public func installTimeline() async throws -> [TimelineEntry] {
        let json = try await runJSON(["info", "--json=v2", "--installed"])
        guard let obj = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let formulae = obj["formulae"] as? [[String: Any]] else { return [] }
        var entries: [TimelineEntry] = []
        for item in formulae {
            guard let name = item["name"] as? String else { continue }
            let installed = (item["installed"] as? [[String: Any]])?.first
            let time = installed?["installed_time"] as? TimeInterval
            entries.append(TimelineEntry(
                name: name,
                installedAt: time.map { Date(timeIntervalSince1970: $0) },
                onRequest: (installed?["installed_on_request"] as? Bool) ?? false,
                asDependency: (installed?["installed_as_dependency"] as? Bool) ?? false
            ))
        }
        return entries.sorted { ($0.installedAt ?? .distantPast) > ($1.installedAt ?? .distantPast) }
    }

    // MARK: - 内部

    /// 非 JSON 命令执行（doctor/cleanup/search/deps/uses）。
    private func runRaw(_ args: [String]) async throws -> ProcessResult {
        guard let brewPath else { throw BrewServiceError.brewNotFound }
        return try await runner.run(brewPath: brewPath, args: args, timeout: .seconds(120))
    }

    private func runJSON(_ args: [String]) async throws -> Data {
        guard let brewPath else { throw BrewServiceError.brewNotFound }
        let result = try await runner.run(brewPath: brewPath, args: args, timeout: .seconds(60))
        guard result.succeeded else {
            throw BrewServiceError.commandFailed(command: "brew \(args.joined(separator: " "))", stderr: result.stderr)
        }
        return Data(result.stdout.utf8)
    }

    // MARK: - D5 Brewfile 导出/导入

    /// 导出 Brewfile（`brew bundle dump --file=-`；含 cask/tap/mas 段）。
    public func exportBrewfile() async throws -> String {
        let result = try await runRaw(["bundle", "dump", "--file=-"])
        return result.stdout
    }

    /// 导入 Brewfile（`brew bundle --file=<path>`，走 journal 记账；导入前建议 diff 核对）。
    public func importBrewfile(_ path: String, journal: OperationJournal) async -> Bool {
        guard let brewPath else { return false }
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return false }
        let id = await journal.begin("Brewfile 导入")
        try? await journal.append(
            .runWhitelistedCommand(
                executable: brewPath, args: ["bundle", "--file=\(path)"]
            ),
            to: id
        )
        let result = await journal.commit(id)
        return result.succeededCount > 0
    }

    /// 导入前 diff：Brewfile 中尚未安装的条目（导入预览）。
    public func brewfileDiff(_ brewfileContent: String) async throws -> [String] {
        let lines = brewfileContent.components(separatedBy: "\n")
        var pending: [String] = []
        let installed = try await listFormulae().map(\.name)
        let casks = try await listCasks().map(\.token)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("brew "), let name = trimmed.components(separatedBy: " ").dropFirst().first {
                if !installed.contains(name) { pending.append(line) }
            } else if trimmed.hasPrefix("cask "), let token = trimmed.components(separatedBy: " ").dropFirst().first {
                if !casks.contains(token) { pending.append(line) }
            } else if trimmed.hasPrefix("tap "), trimmed.hasSuffix("\"") {
                pending.append(line)
            }
        }
        return pending
    }
}