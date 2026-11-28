import CcCleanCore
import CcCleanOps
import CcCleanPrivileged

/// 数据库单例持有者（App 生命周期共享一个主库）。
@MainActor
enum DatabaseStoreHolder {
    static let shared: DatabaseStore = {
        do {
            return try DatabaseStore.open(
                at: Paths.mainDatabase,
                logger: Logger(category: .general)
            )
        } catch {
            fatalError("database open failed: \(error)")
        }
    }()
}

/// OperationJournal 单例（App 生命周期共享；注入 XPCHelperClient 打通系统级通路，S10）。
@MainActor
enum OperationJournalHolder {
    static var cached: OperationJournal?
    static func shared(store: DatabaseStore) -> OperationJournal {
        if let cached { return cached }
        // S10：注入 Helper 客户端——removeSystem/forgetReceipts/resetTCC/bootout
        // 走 Helper XPC（Helper 未注册时 OperationJournal 内部降级为明确失败原因，UI 灰显）
        let journal = OperationJournal(
            store: store,
            helper: XPCHelperClient(),
            logger: Logger(category: .uninstall)
        )
        cached = journal
        return journal
    }
}