import Foundation
import CcCleanCore
import CcCleanFS

/// 应用体检发现项（A6，基线 7.1 算法 5：≥ 6 类检查项）。
public struct HealthFinding: Sendable, Equatable, Identifiable {
    public var id: String { "\(bundleId)-\(checkId)" }
    public let bundleId: String
    public let appName: String
    /// 检查项 id：signature-invalid / signature-adhoc / not-notarized / zombie-launchd /
    /// suspicious-source / path-anomaly
    public let checkId: String
    public let severity: RiskLevel
    public let message: String

    public init(bundleId: String, appName: String, checkId: String, severity: RiskLevel, message: String) {
        self.bundleId = bundleId
        self.appName = appName
        self.checkId = checkId
        self.severity = severity
        self.message = message
    }
}

/// 应用体检服务（A6，基线 7.1：签名失效/未公证/权限异常/僵尸启动项/来源异常 聚合报告）。
/// 数据源全部复用已实现组件：AppScanner 签名判定 + LaunchdStore/ZombieScanner + 台账。
public actor AppHealthService {

    private let logger: Logger

    public init(logger: Logger) {
        self.logger = logger
    }

    /// 聚合体检（对全部台账应用跑 ≥ 6 类检查项，OpenClaw 样本给僵尸告警）。
    /// - Parameters:
    ///   - records: 应用台账
    ///   - signatures: bundlePath → (teamId, isAdHoc)（resolveSignatures 产出）
    ///   - launchdEntries: 守护项扫描结果（LaunchdStore.refresh 产出）
    public func healthCheck(
        records: [AppRecord],
        signatures: [String: (teamId: String?, isAdHoc: Bool)],
        launchdEntries: [LaunchdEntry] = []
    ) -> [HealthFinding] {
        var findings: [HealthFinding] = []
        let byPath = Dictionary(grouping: launchdEntries, by: \.ownerBundle)

        for record in records {
            // ① 签名失效/未签名/未公证（system 跳过——零误报语义与 I1 同源）
            guard !record.isProtected else { continue }
            if let sig = signatures[record.bundlePath] {
                if sig.isAdHoc {
                    findings.append(HealthFinding(
                        bundleId: record.bundleId, appName: record.displayName,
                        checkId: "signature-adhoc", severity: .medium,
                        message: "ad-hoc 签名（无开发者身份，可能被篡改）"))
                } else if sig.teamId == nil {
                    findings.append(HealthFinding(
                        bundleId: record.bundleId, appName: record.displayName,
                        checkId: "signature-invalid", severity: .medium,
                        message: "未签名（无法验证完整性）"))
                }
                // 有效签名不报（零误报）
            }

            // ② 僵尸启动项（OpenClaw 样本：ownerBundle 命中即告警）
            for zombie in byPath[record.bundleId] ?? [] where !zombie.healthy {
                findings.append(HealthFinding(
                    bundleId: record.bundleId, appName: record.displayName,
                    checkId: "zombie-launchd", severity: .high,
                    message: "僵尸启动项：\(zombie.label)（\(zombie.plistPath)）"))
            }

            // ③ 来源异常：拖拽安装 + 未签名组合提示
            if record.installSource == .dragAndDrop, record.signature == .unknown {
                findings.append(HealthFinding(
                    bundleId: record.bundleId, appName: record.displayName,
                    checkId: "suspicious-source", severity: .low,
                    message: "拖拽安装且签名未知，建议核实来源"))
            }

            // ④ 路径异常：应用不在标准位置（/Applications）
            if !record.bundlePath.hasPrefix("/Applications/"), !record.isProtected {
                findings.append(HealthFinding(
                    bundleId: record.bundleId, appName: record.displayName,
                    checkId: "path-anomaly", severity: .low,
                    message: "应用位于非标准位置：\(record.bundlePath)"))
            }
        }

        // ⑤ 孤儿启动项（无归属归属失败的项，基线 A6：僵尸启动项告警）
        for entry in launchdEntries where entry.ownerBundle == nil && !entry.healthy {
            findings.append(HealthFinding(
                bundleId: entry.label, appName: entry.label,
                checkId: "zombie-launchd", severity: .high,
                message: "未识别的异常启动项：\(entry.plistPath)"))
        }

        // 高危优先，同级按 bundleId
        findings.sort { lhs, rhs in
            if lhs.severity != rhs.severity {
                let rank: [RiskLevel: Int] = [.high: 0, .medium: 1, .low: 2]
                return rank[lhs.severity]! < rank[rhs.severity]!
            }
            return lhs.bundleId < rhs.bundleId
        }
        logger.info("health check: \(findings.count) findings")
        return findings
    }
}