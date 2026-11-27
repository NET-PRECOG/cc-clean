import Testing
import Foundation
import Security
import CcCleanCore
@testable import CcCleanOps

@Suite("StateCleaner (C3/S10)")
struct StateCleanerTests {

    let cleaner = StateCleaner(logger: Logger(category: .uninstall, buffer: LogBuffer(capacity: 10)))

    func makeJournal() throws -> (OperationJournal, URL) {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("state-db-\(UUID().uuidString).sqlite")
        let store = try DatabaseStore.open(
            at: dbURL, logger: Logger(category: .uninstall, buffer: LogBuffer(capacity: 10)))
        let journal = OperationJournal(
            store: store, logger: Logger(category: .uninstall, buffer: LogBuffer(capacity: 10)))
        return (journal, dbURL)
    }

    // MARK: - Keychain

    /// 创建测试 Keychain 项（幂等：先删后加，避免跨运行残留导致重复失败）。
    func addKeychainItem(service: String, account: String = "tester") -> Bool {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ] as CFDictionary)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: "secret".data(using: .utf8)!,
        ]
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    func keychainExists(service: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    @Test("Keychain：按 service 前缀精确删除，其他前缀不受影响（R4 语义）")
    func keychainCleanup() async throws {
        let bundleId = "com.stateclean.test.\(Int.random(in: 1000...9999))"
        defer {
            // 清场：无论测试结果都移除测试项
            for s in ["\(bundleId).a", "\(bundleId).b"] {
                SecItemDelete([
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: s,
                ] as CFDictionary)
            }
        }

        #expect(addKeychainItem(service: "\(bundleId).a"))
        #expect(addKeychainItem(service: "\(bundleId).b"))
        #expect(addKeychainItem(service: "com.other.app.entry"))   // 其他应用，不得误删
        #expect(keychainExists(service: "com.other.app.entry"))

        let (succeeded, failed) = await cleaner.cleanKeychain(bundleId: bundleId)
        #expect(failed.isEmpty)
        #expect(succeeded.contains("\(bundleId).a"))
        #expect(succeeded.contains("\(bundleId).b"))
        #expect(!keychainExists(service: "\(bundleId).a"))
        #expect(!keychainExists(service: "\(bundleId).b"))
        // R4：其他应用条目完好
        #expect(keychainExists(service: "com.other.app.entry"))
    }

    @Test("Keychain：无匹配项 → 空成功（不报错）")
    func keychainNoMatch() async {
        let (succeeded, failed) = await cleaner.cleanKeychain(
            bundleId: "com.nonexistent.\(Int.random(in: 1000...9999))"
        )
        #expect(succeeded.isEmpty)
        #expect(failed.isEmpty)
    }

    // MARK: - 最近文档

    @Test("最近文档：sfl 内容含目标路径 → trash（走 journal 可撤销）")
    func recentItemsTrash() async throws {
        let (journal, dbURL) = try makeJournal()
        defer { try? FileManager.default.removeItem(at: dbURL) }

        // 构造内容含目标路径的 sfl 伪装文件
        let bundlePath = "/Applications/FakeTarget.app"
        let sflDir = NSHomeDirectory() + "/Library/Application Support/com.apple.sharedfilelist"
        try FileManager.default.createDirectory(
            atPath: sflDir, withIntermediateDirectories: true)
        let fake = sflDir + "/com.apple.LSSharedFileList.RecentApplications.sfl3"
        try "binary-content \(bundlePath) marker".data(using: .utf8)!.write(to: URL(fileURLWithPath: fake))
        defer { try? FileManager.default.removeItem(atPath: fake) }

        let (paths, failed) = await cleaner.cleanRecentItems(
            bundlePath: bundlePath, journal: journal
        )
        #expect(failed.isEmpty)
        #expect(paths.contains(fake))
        #expect(!FileManager.default.fileExists(atPath: fake))   // 已进废纸篓
    }

    @Test("最近文档：内容不含目标 → 不清理")
    func recentItemsNoMatch() async throws {
        let (journal, dbURL) = try makeJournal()
        defer { try? FileManager.default.removeItem(at: dbURL) }

        let sflDir = NSHomeDirectory() + "/Library/Application Support/com.apple.sharedfilelist"
        try FileManager.default.createDirectory(
            atPath: sflDir, withIntermediateDirectories: true)
        let fake = sflDir + "/com.apple.LSSharedFileList.RecentDocuments.sfl3"
        try "unrelated content".data(using: .utf8)!.write(to: URL(fileURLWithPath: fake))
        defer { try? FileManager.default.removeItem(atPath: fake) }

        let (paths, failed) = await cleaner.cleanRecentItems(
            bundlePath: "/Applications/Unrelated.app", journal: journal
        )
        #expect(paths.isEmpty)
        #expect(failed.isEmpty)
        #expect(FileManager.default.fileExists(atPath: fake))   // 未清理
    }
}