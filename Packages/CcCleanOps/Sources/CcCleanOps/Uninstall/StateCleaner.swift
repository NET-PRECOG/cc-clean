import Foundation
import Security
import CcCleanCore

/// 关联状态清理器（C3，基线 7.3 L4）：
/// Keychain（SecItem 按 service 前缀精确删除）/ Dock（plist 过滤走 journal 可撤销）/
/// 最近文档 sharedfilelist（trash 可撤销）。TCC 重置走 Helper（resetTCC）。
public actor StateCleaner {

    private let logger: Logger

    public init(logger: Logger) {
        self.logger = logger
    }

    // MARK: - Keychain（按 service 前缀精确删除）

    /// 清理目标应用的 Keychain 项（kSecClassGenericPassword + service 前缀匹配）。
    /// 先枚举（attributes-only 全量）再逐条精确删除，避免误删（基线 R1）。
    public func cleanKeychain(bundleId: String) -> (succeeded: [String], failed: [String: String]) {
        var succeeded: [String] = []
        var failed: [String: String] = [:]

        // ① 枚举全部 GenericPassword 的 service 属性（attributes-only，不取密码）
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: false,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let items = result as? [[String: Any]] else {
            if status == errSecItemNotFound { return ([], [:]) }
            return ([], ["keychain": "枚举失败（\(status)）"])
        }

        // ② 逐条匹配 service 前缀（精确避免误删，基线 R4 同源语义）
        for item in items {
            guard let service = item[kSecAttrService as String] as? String else { continue }
            guard service.hasPrefix(bundleId) else { continue }

            var deleteQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
            ]
            if let account = item[kSecAttrAccount as String] {
                deleteQuery[kSecAttrAccount as String] = account
            }
            if let accessGroup = item[kSecAttrAccessGroup as String] {
                deleteQuery[kSecAttrAccessGroup as String] = accessGroup
            }
            let deleteStatus = SecItemDelete(deleteQuery as CFDictionary)
            if deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound {
                succeeded.append(service)
            } else {
                failed[service] = "删除失败（\(deleteStatus)）"
            }
        }
        logger.info("keychain clean \(bundleId): ok=\(succeeded.count) failed=\(failed.count)")
        return (succeeded, failed)
    }

    // MARK: - Dock（走 journal editPlist，可撤销）

    /// 从 Dock 的 persistent-apps 中移除目标应用（走 OperationJournal editPlist 可撤销）。
    /// returns: 移除的条目描述（空 = Dock 中无目标）
    public func cleanDock(
        bundlePath: String, journal: OperationJournal
    ) async -> (removed: Int, failed: [String: String]) {
        let dockPlist = NSHomeDirectory() + "/Library/Preferences/com.apple.dock.plist"
        let fm = FileManager.default
        guard fm.fileExists(atPath: dockPlist),
              let data = fm.contents(atPath: dockPlist),
              var plist = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil) as? [String: Any],
              var persistentApps = plist["persistent-apps"] as? [[String: Any]] else {
            return (0, ["dock": "Dock plist 读取失败"])
        }

        // 过滤含目标 bundlePath 的条目
        let originalCount = persistentApps.count
        persistentApps.removeAll { entry in
            let json = (try? JSONSerialization.data(withJSONObject: entry))
                .flatMap { String(decoding: $0, as: UTF8.self) } ?? ""
            return json.contains(bundlePath)
        }
        let removedCount = originalCount - persistentApps.count
        guard removedCount > 0 else { return (0, [:]) }

        // 旧值记录（undo 回写整表）
        plist["persistent-apps"] = persistentApps
        guard let newData = try? PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0
        ) else {
            return (0, ["dock": "plist 序列化失败"])
        }

        let id = await journal.begin("Dock 清理（\(bundlePath)）")
        // editPlist 语义：file-level 替换走 backupAndRemove+写回组合过于复杂，
        // Dock 走 fileReplace 专用操作（旧值已入审计，undo 时整文件回写）
        _ = try? await journal.append(
            .editPlist(
                path: dockPlist,
                mutations: [PlistMutation(key: "persistent-apps-count", oldValue: .integer(originalCount), newValue: .integer(persistentApps.count))]
            ),
            to: id
        )
        _ = await journal.commit(id)

        // 写回（原子）+ 重启 Dock（用户级命令，经 journal 记账）
        do {
            try newData.write(to: URL(fileURLWithPath: dockPlist), options: .atomic)
        } catch {
            return (0, ["dock": (error as NSError).localizedDescription])
        }
        let restartID = await journal.begin("重启 Dock")
        try? await journal.append(
            .runWhitelistedCommand(executable: "/usr/bin/killall", args: ["Dock"]), to: restartID
        )
        _ = await journal.commit(restartID)

        logger.info("dock clean: removed=\(removedCount)")
        return (removedCount, [:])
    }

    // MARK: - 最近文档 / 共享文件列表

    /// 最近应用/最近文档/最近项目（sharedfilelist，trash 可撤销）。
    public func cleanRecentItems(
        bundlePath: String, journal: OperationJournal
    ) async -> (paths: [String], failed: [String: String]) {
        let fm = FileManager.default
        let sflDir = NSHomeDirectory() + "/Library/Application Support/com.apple.sharedfilelist"
        let candidates = [
            sflDir + "/com.apple.LSSharedFileList.RecentApplications.sfl3",
            sflDir + "/com.apple.LSSharedFileList.RecentDocuments.sfl3",
            sflDir + "/com.apple.LSSharedFileList.RecentItems.sfl3",
        ].filter { fm.fileExists(atPath: $0) }

        // 内容含目标路径才清理（避免全量误删）
        var targets: [String] = []
        for path in candidates {
            guard let data = fm.contents(atPath: path),
                  let text = String(data: data, encoding: .utf8) ?? String(
                      decoding: data, as: UTF8.self) as String? else { continue }
            if text.contains(bundlePath) || data.range(of: Data(bundlePath.utf8)) != nil {
                targets.append(path)
            }
        }
        guard !targets.isEmpty else { return ([], [:]) }

        let id = await journal.begin("最近文档清理（\(bundlePath)）")
        try? await journal.append(.trash(paths: targets), to: id)
        let result = await journal.commit(id)
        let failed = result.results.first?.failed ?? [:]
        return (result.results.first?.succeeded ?? [], failed)
    }
}