import CcCleanCore

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