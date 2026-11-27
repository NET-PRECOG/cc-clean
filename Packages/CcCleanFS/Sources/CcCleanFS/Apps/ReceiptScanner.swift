import Foundation
import GRDB
import CcCleanCore

/// pkgutil 协议注入（基线 13.1：不依赖真实系统输出）。
public protocol PkgUtilProviding: Sendable {
    /// pkgutil --pkgs 全部 receipt id
    func pkgIds() async -> [String]
    /// pkgutil --files <pkgId> 的相对路径清单
    func files(ofPkg pkgId: String) async -> [String]
}

/// pkgutil 真实实现（唯一命令出口 ProcessRunner）。
public struct SystemPkgUtil: PkgUtilProviding {
    let runner = ProcessRunner()

    public init() {}

    public func pkgIds() async -> [String] {
        let result = try? await runner.run(.init(
            executablePath: "/usr/sbin/pkgutil", arguments: ["--pkgs"], timeout: .seconds(15)
        ))
        guard let result, result.succeeded else { return [] }
        return result.stdout.split(separator: "\n").map(String.init)
    }

    public func files(ofPkg pkgId: String) async -> [String] {
        let result = try? await runner.run(.init(
            executablePath: "/usr/sbin/pkgutil",
            arguments: ["--files", pkgId],
            timeout: .seconds(20)
        ))
        guard let result, result.succeeded else { return [] }
        return result.stdout.split(separator: "\n").map(String.init)
    }
}

/// 系统级 receipts 扫描（C2 前置，基线 7.3 L3）：
/// pkgutil receipt 文件清单含目标 bundle 相对路径 → l3System 残留（requiresRoot、不可撤销）。
/// receipt id 列表缓存 pkg_receipts 表（基线 8.1：200~400 条全量保留）。
public actor ReceiptScanner {

    private let pkgUtil: PkgUtilProviding
    private let logger: Logger

    public init(pkgUtil: PkgUtilProviding = SystemPkgUtil(), logger: Logger) {
        self.pkgUtil = pkgUtil
        self.logger = logger
    }

    /// 扫描目标应用的 receipts。
    /// - Parameters:
    ///   - store: 主库（pkg_receipts 缓存表）
    ///   - refreshCache: 强制刷新 receipt id 列表
    public func scanReceipts(
        target: AppRecord, store: DatabaseStore?, refreshCache: Bool = false
    ) async -> [ResidueItem] {
        let pkgIds = await loadPkgIds(store: store, refresh: refreshCache)
        guard !pkgIds.isEmpty else { return [] }

        // 目标 bundle 的卷相对路径（pkgutil files 为相对卷根，如 "Applications/Demo.app"）
        let relative = target.bundlePath.hasPrefix("/")
            ? String(target.bundlePath.dropFirst())
            : target.bundlePath

        var items: [ResidueItem] = []
        for pkgId in pkgIds {
            // 系统组件 receipt 不碰（基线 10.4 硬拦截：com.apple.*）
            if pkgId.lowercased().hasPrefix("com.apple.") { continue }
            let files = await pkgUtil.files(ofPkg: pkgId)
            let related = files.contains { file in
                file == relative || relative.hasPrefix(file + "/") || file.hasPrefix(relative + "/")
            }
            if related {
                items.append(ResidueItem(
                    path: pkgId, layer: .l3System, confidence: .exact,
                    risk: .high,
                    reason: "pkgutil receipt（\(files.count) 个文件关联本应用）",
                    requiresRoot: true,
                    undoable: false   // pkgutil --forget 不可撤销（基线 C5）
                ))
            }
        }
        logger.info("receipt scan \(target.bundleId): \(items.count) receipts")
        return items
    }

    /// receipt id 列表（pkg_receipts 缓存优先；过期/缺失时刷新）。
    func loadPkgIds(store: DatabaseStore?, refresh: Bool) async -> [String] {
        if !refresh, let store {
            let cached = await cachedPkgIds(store: store)
            if !cached.isEmpty { return cached }
        }
        let ids = await pkgUtil.pkgIds()
        if let store, !ids.isEmpty {
            await persistPkgIds(ids, store: store)
        }
        return ids
    }

    private func cachedPkgIds(store: DatabaseStore) async -> [String] {
        (try? await store.pool.read { db in
            try String.fetchAll(db, sql: "SELECT pkg_id FROM pkg_receipts")
        }) ?? []
    }

    private func persistPkgIds(_ ids: [String], store: DatabaseStore) async {
        let now = Date().timeIntervalSince1970
        _ = try? await store.pool.write { db in
            try db.execute(sql: "DELETE FROM pkg_receipts")
            for id in ids {
                try db.execute(
                    sql: """
                    INSERT OR REPLACE INTO pkg_receipts (pkg_id, install_time, volume, location, fetched_at)
                    VALUES (?, NULL, NULL, NULL, ?)
                    """,
                    arguments: [id, now]
                )
            }
        }
    }
}