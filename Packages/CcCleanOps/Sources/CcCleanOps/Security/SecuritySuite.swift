import Foundation
import CcCleanCore
import CcCleanFS

/// 安全扫描发现项（I1/I7，基线 11.3 ④：只报路径与规则名，不展示密钥/内容全文）。
public struct SecurityFinding: Sendable, Equatable, Identifiable {
    public var id: String { path }
    public let path: String
    public let title: String
    public let reason: String
    /// 风险级（I1 高危误报零容忍：正常签名应用不进入列表）
    public let risk: RiskLevel

    public init(path: String, title: String, reason: String, risk: RiskLevel) {
        self.path = path
        self.title = title
        self.reason = reason
        self.risk = risk
    }
}

/// 安全与隐私服务（I1/I2/I3/I7，基线 7.7）：
/// I1 可疑签名扫描（签名无效/ad-hoc/quarantine 下载/LaunchDaemon 指向临时目录；零高危误报）；
/// I2 隐私痕迹清理（每类独立勾选 + 预览条目数，不清除未选类别）；
/// I3 TCC 权限总览（只读 TCC.db 9 类 service；重置走 Helper resetTCC 逐服务）；
/// I7 敏感文件扫描（sensitive-file.json 规则驱动，只报路径不展示内容）。
public actor SecuritySuite {

    private let appEnvironment: AppEnvironmentProviding
    private let runner = ProcessRunner()
    private let logger: Logger

    public init(
        appEnvironment: AppEnvironmentProviding, logger: Logger
    ) {
        self.appEnvironment = appEnvironment
        self.logger = logger
    }

    // MARK: - I1 可疑签名扫描

    public struct SuspiciousApp: Sendable, Equatable {
        public let bundlePath: String
        public let name: String
        public let reasons: [String]
        public let risk: RiskLevel
    }

    /// 可疑应用扫描（复用 AppScanner 台账 + 签名判定；零高危误报语义：
    /// ad-hoc 仅 medium、quarantine 不报（拖拽正常）、未公证仅提示）。
    /// - Parameters:
    ///   - records: 应用台账（AppScanner 扫描结果）
    ///   - signatures: bundlePath → (teamId, isAdHoc) 签名缓存（resolveSignatures 产出）
    public func scanSuspiciousApps(
        records: [AppRecord],
        signatures: [String: (teamId: String?, isAdHoc: Bool)]
    ) -> [SuspiciousApp] {
        var findings: [SuspiciousApp] = []
        for record in records {
            guard !record.isProtected else { continue }   // 系统应用跳过（零误报）
            var reasons: [String] = []
            var risk: RiskLevel = .medium

            if let sig = signatures[record.bundlePath] {
                if sig.isAdHoc {
                    reasons.append("ad-hoc 签名（无开发者身份）")
                    risk = .medium
                } else if sig.teamId == nil {
                    reasons.append("未签名")
                    risk = .medium
                }
                // 有 teamId 的正常签名应用不进入列表（零高危误报）
                else { continue }
            }

            if reasons.isEmpty { continue }
            findings.append(SuspiciousApp(
                bundlePath: record.bundlePath, name: record.displayName,
                reasons: reasons, risk: risk))
        }
        logger.info("suspicious scan: \(findings.count) findings")
        return findings
    }

    /// 可疑 launchd 指向临时目录（恶意软件驻留常见特征，基线 I1）。
    public func scanSuspiciousLaunchd(entries: [LaunchdEntry]) -> [SuspiciousApp] {
        let tempPrefixes = ["/tmp/", "/private/tmp/", "/Users/Shared/", "/var/folders/"]
        return entries.compactMap { entry in
            let executable = entry.program ?? entry.args.first
            guard let executable, tempPrefixes.contains(where: { executable.hasPrefix($0) }) else {
                return nil
            }
            return SuspiciousApp(
                bundlePath: executable, name: entry.label,
                reasons: ["launchd 指向临时目录：\(executable)"],
                risk: .high)
        }
    }

    // MARK: - I3 TCC 权限总览（POC-T3：TCC.db 只读 SQL）

    public struct TCCEntry: Sendable, Equatable, Identifiable {
        public var id: String { "\(service)-\(client)" }
        public let service: String      // kTCCServiceCamera 等
        public let client: String       // bundleId
        public let allowed: Bool
    }

    /// 只读 TCC.db（sqlite3 命令行；无全盘访问时优雅降级返回 nil，基线 POC-T3）。
    public func readTCCEntries() async -> [TCCEntry]? {
        // 用户级 TCC.db（系统级需 Helper/全盘访问——S10 接入）
        let tccPath = NSHomeDirectory() + "/Library/Application Support/com.apple.TCC/TCC.db"
        guard FileManager.default.fileExists(atPath: tccPath) else { return nil }
        let result = try? await runner.run(.init(
            executablePath: "/usr/bin/sqlite3",
            arguments: [tccPath,
                        "SELECT service, client, auth_value FROM access WHERE client != '' LIMIT 500;"],
            timeout: .seconds(15)
        ))
        guard let result, result.succeeded else { return nil }
        return result.stdout.components(separatedBy: "\n").compactMap { line in
            let parts = line.components(separatedBy: "|")
            guard parts.count >= 3 else { return nil }
            return TCCEntry(
                service: parts[0], client: parts[1],
                allowed: Int(parts[2]) ?? 0 > 0)
        }
    }

    /// 重置某应用的指定 TCC 服务（走 Helper resetTCC 逐服务，代码级禁 reset All）。
    public func resetTCC(
        bundleID: String, services: [String], helper: HelperClientProtocol?
    ) async -> (succeeded: [String], failed: [String: String]) {
        guard let helper else {
            return ([], ["tccutil": "需要辅助程序（Helper 未安装）"])
        }
        return await helper.resetTCC(
            bundleID: bundleID, services: services, journalID: UUID().uuidString)
    }

    // MARK: - I7 敏感文件扫描（规则驱动，.report 只报不清理）

    /// 敏感文件扫描（复用 RuleEngine + sensitive-file.json；只报路径与规则名）。
    public func scanSensitiveFiles(ruleEngine: RuleEngine) async -> [SecurityFinding] {
        let hits = await ruleEngine.evaluate(RuleContext(scope: .security, budget: .seconds(20)))
        return hits.flatMap { hit in
            hit.paths.map { path in
                SecurityFinding(
                    path: path, title: hit.rule.title,
                    reason: hit.rule.explain,
                    risk: hit.rule.risk == .high ? .high : .medium)
            }
        }
    }

    // MARK: - I2 隐私痕迹清理

    public struct PrivacyTarget: Sendable, Equatable, Identifiable {
        public var id: String { path }
        public let name: String
        public let path: String
        /// 预览条目数（数据库行数等，只报不落内容）
        public let itemCount: Int?
    }

    /// 隐私痕迹候选（每类独立勾选，基线 I2：不清除未选类别；浏览器缓存与 Cookie 严格分离）。
    public static let privacyTargets: [(name: String, path: String)] = [
        ("Safari 历史", "~/Library/Safari/History.db"),
        ("Safari 最近搜索", "~/Library/Safari/RecentSearches.sqlite"),
        ("最近文档（sharedfilelist）", "~/Library/Application Support/com.apple.sharedfilelist"),
        ("Spotlight 搜索记录", "~/Library/Containers/com.apple.Spotlight"),
        ("快速Look缩略图缓存", "~/Library/Caches/com.apple.QuickLook.thumbnailcache"),
    ]

    /// 预览：存在性与条目数（数据库表行数；不读取内容，基线 I2 边界）。
    public func previewPrivacyTargets() async -> [PrivacyTarget] {
        var targets: [PrivacyTarget] = []
        for (name, template) in Self.privacyTargets {
            let path = (template as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: path) else { continue }
            var itemCount: Int?
            if path.hasSuffix(".db") || path.hasSuffix(".sqlite") {
                // 数据库行数（只读 SELECT COUNT，不读取内容）
                let result = try? await runner.run(.init(
                    executablePath: "/usr/bin/sqlite3",
                    arguments: [path, "SELECT COUNT(*) FROM history_items;"],
                    timeout: .seconds(10)
                ))
                if let result, result.succeeded {
                    itemCount = Int(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            }
            targets.append(PrivacyTarget(name: name, path: path, itemCount: itemCount))
        }
        return targets
    }

    /// 清理勾选的隐私痕迹（trash 可撤销；只清勾选类别，基线 I2 验收）。
    public func cleanPrivacy(
        selectedPaths: [String], journal: OperationJournal
    ) async -> (succeeded: [String], failed: [String: String]) {
        guard !selectedPaths.isEmpty else { return ([], [:]) }
        let id = await journal.begin("隐私痕迹清理（\(selectedPaths.count) 类）")
        try? await journal.append(.trash(paths: selectedPaths), to: id)
        let result = await journal.commit(id)
        logger.info("privacy clean: ok=\(result.succeededCount) failed=\(result.failedCount)")
        return (result.results.first?.succeeded ?? [], result.results.first?.failed ?? [:])
    }


    // MARK: - I6 代理/防火墙状态（只读，基线 I6）

    public struct NetworkSecurityStatus: Sendable, Equatable {
        public let httpProxyEnabled: Bool
        public let httpProxyHost: String?
        public let socksProxyEnabled: Bool
        public let firewallEnabled: Bool?
        public let firewallStealth: Bool?
    }

    /// 代理状态（scutil --proxy 输出解析；只读）。
    public func proxyStatus() async -> (httpEnabled: Bool, httpHost: String?, socksEnabled: Bool) {
        let result = try? await runner.run(.init(
            executablePath: "/usr/sbin/scutil", arguments: ["--proxy"], timeout: .seconds(10)
        ))
        guard let result, result.succeeded else { return (false, nil, false) }
        let text = result.stdout
        func enabled(_ key: String) -> Bool {
            text.contains(key) && text.range(of: key + "\n" + ".*1", options: .regularExpression) != nil
        }
        var host: String?
        if enabled("HTTPEnable"), let range = text.range(of: "HTTPProxy : ") {
            host = String(text[range.upperBound...].prefix(while: { !$0.isNewline }))
        }
        return (enabled("HTTPEnable"), host, enabled("SOCKSEnable"))
    }

    /// 防火墙状态（socketfilterfw；只读）。
    public func firewallStatus() async -> (enabled: Bool?, stealth: Bool?) {
        let result = try? await runner.run(.init(
            executablePath: "/usr/libexec/ApplicationFirewall/socketfilterfw",
            arguments: ["--getglobalstate"], timeout: .seconds(10)
        ))
        guard let result, result.succeeded else { return (nil, nil) }
        let enabled = result.stdout.contains("enabled")
        let stealthResult = try? await runner.run(.init(
            executablePath: "/usr/libexec/ApplicationFirewall/socketfilterfw",
            arguments: ["--getstealthmode"], timeout: .seconds(10)
        ))
        let stealth = stealthResult?.stdout.contains("enabled")
        return (enabled, stealth)
    }

    /// 聚合状态（I6 UI 数据源）。
    public func networkSecurityStatus() async -> NetworkSecurityStatus {
        let proxy = await proxyStatus()
        let fw = await firewallStatus()
        return NetworkSecurityStatus(
            httpProxyEnabled: proxy.httpEnabled, httpProxyHost: proxy.httpHost,
            socksProxyEnabled: proxy.socksEnabled,
            firewallEnabled: fw.enabled, firewallStealth: fw.stealth)
    }
}
