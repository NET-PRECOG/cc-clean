import Foundation
import CcCleanCore

/// 僵尸残留扫描器（C10/H5，基线 7.8 算法 3）：
/// program 路径不存在或 last exit code 非 0 的启动项合并为「健康问题」列表；
/// OpenClaw 的 ai.openclaw.gateway（exit 127）为固定回归样本（基线 R2）。
public struct ZombieScanner: Sendable {

    public struct Finding: Sendable, Equatable {
        public let entry: LaunchdEntry
        /// program 缺失 / exit 非 0 / 两者
        public let reasons: [String]
        /// 修复建议：禁用（bootout + 移出 plist）或删除 plist
        public let suggestedFixes: [String]
    }

    private let protected: ProtectedPaths
    private let home: String

    public init(protected: ProtectedPaths = .builtin, home: String? = nil) {
        self.protected = protected
        self.home = home ?? FileManager.default.homeDirectoryForCurrentUser.path
    }

    /// 扫描健康问题项（只读侦察，scope=healthCheck 允许探测系统目录）。
    /// 系统组件（isSystem）不参与僵尸判定——基线 H 边界：只读展示禁止操作，
    /// 且系统目录 program 路径不可靠（dyld 缓存/框架形式），避免误报。
    public func scan(
        home: String, knownBundles: [AppRecord], lastExitOverrides: [String: Int] = [:]
    ) -> [Finding] {
        let entries = LaunchdParser.scan(home: home, knownBundles: knownBundles)
        return entries.compactMap { entry in
            guard !entry.isSystem else { return nil }   // 系统组件只读展示，不进僵尸列表
            var diagnosed = LaunchdParser.diagnose(entry)
            // lastExit 覆盖（launchctl print 结果由调用方注入；S10 接入真实读取）
            if let exit = lastExitOverrides[entry.label] {
                diagnosed = LaunchdEntry(
                    label: diagnosed.label, plistPath: diagnosed.plistPath,
                    domain: diagnosed.domain, program: diagnosed.program, args: diagnosed.args,
                    runAtLoad: diagnosed.runAtLoad, keepAlive: diagnosed.keepAlive,
                    startInterval: diagnosed.startInterval, ownerBundle: diagnosed.ownerBundle,
                    isSystem: diagnosed.isSystem,
                    healthy: diagnosed.healthy && exit == 0,   // 两者都健康才健康
                    lastExit: exit, scannedAt: diagnosed.scannedAt
                )
            }
            guard !diagnosed.healthy else { return nil }

            var reasons: [String] = []
            let executable = diagnosed.program ?? diagnosed.args.first
            if let executable, !FileManager.default.fileExists(atPath: executable) {
                reasons.append("Program 路径不存在：\(executable)")
            }
            if let exit = diagnosed.lastExit, exit != 0 {
                reasons.append("上次退出码非 0（\(exit)）")
            }

            // 修复建议（系统组件只读提示）
            var fixes: [String] = []
            if diagnosed.isSystem {
                fixes.append("系统组件：只读展示，建议保持")
            } else {
                fixes.append("禁用（bootout 并移出 plist）")
                fixes.append("删除 plist：\(diagnosed.plistPath)")
            }
            return Finding(entry: diagnosed, reasons: reasons, suggestedFixes: fixes)
        }
    }
}