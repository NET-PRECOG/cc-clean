import Foundation

/// plist 变更记录（editPlist 旧值 → 可撤销，基线 6.3）。
public struct PlistMutation: Codable, Sendable, Equatable {
    /// 点分 keypath，如 "RunAtLoad"
    public let key: String
    public let oldValue: PlistValue?
    public let newValue: PlistValue?

    public init(key: String, oldValue: PlistValue?, newValue: PlistValue?) {
        self.key = key
        self.oldValue = oldValue
        self.newValue = newValue
    }
}

/// plist 值类型（可 Codable 落库）。
public enum PlistValue: Codable, Sendable, Equatable {
    case string(String)
    case integer(Int)
    case boolean(Bool)
    case data(Data)

    enum Kind: String, Codable {
        case string, integer, boolean, data
    }

    enum CodingKeys: String, CodingKey {
        case kind, value
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .string: self = .string(try c.decode(String.self, forKey: .value))
        case .integer: self = .integer(try c.decode(Int.self, forKey: .value))
        case .boolean: self = .boolean(try c.decode(Bool.self, forKey: .value))
        case .data: self = .data(try c.decode(Data.self, forKey: .value))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .string(let v):
            try c.encode(Kind.string, forKey: .kind)
            try c.encode(v, forKey: .value)
        case .integer(let v):
            try c.encode(Kind.integer, forKey: .kind)
            try c.encode(v, forKey: .value)
        case .boolean(let v):
            try c.encode(Kind.boolean, forKey: .kind)
            try c.encode(v, forKey: .value)
        case .data(let v):
            try c.encode(Kind.data, forKey: .kind)
            try c.encode(v, forKey: .value)
        }
    }
}

/// 写操作类型（基线 6.3 Operation，10 种）。
public enum Operation: Codable, Sendable, Equatable {
    /// 移入废纸篓（可撤销）
    case trash(paths: [String])
    /// 系统级删除（Helper，不可撤销）
    case removeSystem(paths: [String])
    /// 备份后删除（可从备份恢复）
    case backupAndRemove(paths: [String], backupRoot: String)
    /// 停止并取消 launchd 登记（可重新 bootstrap）
    case bootout(plist: String)
    /// 重新登记 launchd
    case bootstrap(plist: String)
    /// pkgutil --forget
    case forgetReceipt(pkgID: String)
    /// tccutil 逐服务重置（禁止 reset All）
    case resetTCC(bundleID: String, services: [String])
    /// plist 编辑（记录旧值 → 可撤销）
    case editPlist(path: String, mutations: [PlistMutation])
    /// 白名单可执行命令
    case runWhitelistedCommand(executable: String, args: [String])
    /// 架构瘦身（G4，需备份）
    case thinBinaries(paths: [String], keepArch: String)
    /// 清空废纸篓指定条目（永久删除，不可撤销）
    case emptyTrash(paths: [String])

    enum Kind: String, Codable {
        case trash, removeSystem, backupAndRemove, bootout, bootstrap
        case forgetReceipt, resetTCC, editPlist, runWhitelistedCommand, thinBinaries
        case emptyTrash
    }

    enum CodingKeys: String, CodingKey {
        case kind, paths, backupRoot, plist, pkgID, bundleID, services
        case mutations, executable, args, keepArch
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .trash: self = .trash(paths: try c.decode([String].self, forKey: .paths))
        case .removeSystem: self = .removeSystem(paths: try c.decode([String].self, forKey: .paths))
        case .backupAndRemove:
            self = .backupAndRemove(
                paths: try c.decode([String].self, forKey: .paths),
                backupRoot: try c.decode(String.self, forKey: .backupRoot)
            )
        case .bootout: self = .bootout(plist: try c.decode(String.self, forKey: .plist))
        case .bootstrap: self = .bootstrap(plist: try c.decode(String.self, forKey: .plist))
        case .forgetReceipt: self = .forgetReceipt(pkgID: try c.decode(String.self, forKey: .pkgID))
        case .resetTCC:
            self = .resetTCC(
                bundleID: try c.decode(String.self, forKey: .bundleID),
                services: try c.decode([String].self, forKey: .services)
            )
        case .editPlist:
            self = .editPlist(
                path: try c.decode(String.self, forKey: .plist),
                mutations: try c.decode([PlistMutation].self, forKey: .mutations)
            )
        case .runWhitelistedCommand:
            self = .runWhitelistedCommand(
                executable: try c.decode(String.self, forKey: .executable),
                args: try c.decode([String].self, forKey: .args)
            )
        case .thinBinaries:
            self = .thinBinaries(
                paths: try c.decode([String].self, forKey: .paths),
                keepArch: try c.decode(String.self, forKey: .keepArch)
            )
        case .emptyTrash:
            self = .emptyTrash(paths: try c.decode([String].self, forKey: .paths))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .trash(let paths):
            try c.encode(Kind.trash, forKey: .kind)
            try c.encode(paths, forKey: .paths)
        case .removeSystem(let paths):
            try c.encode(Kind.removeSystem, forKey: .kind)
            try c.encode(paths, forKey: .paths)
        case .backupAndRemove(let paths, let backupRoot):
            try c.encode(Kind.backupAndRemove, forKey: .kind)
            try c.encode(paths, forKey: .paths)
            try c.encode(backupRoot, forKey: .backupRoot)
        case .bootout(let plist):
            try c.encode(Kind.bootout, forKey: .kind)
            try c.encode(plist, forKey: .plist)
        case .bootstrap(let plist):
            try c.encode(Kind.bootstrap, forKey: .kind)
            try c.encode(plist, forKey: .plist)
        case .forgetReceipt(let pkgID):
            try c.encode(Kind.forgetReceipt, forKey: .kind)
            try c.encode(pkgID, forKey: .pkgID)
        case .resetTCC(let bundleID, let services):
            try c.encode(Kind.resetTCC, forKey: .kind)
            try c.encode(bundleID, forKey: .bundleID)
            try c.encode(services, forKey: .services)
        case .editPlist(let path, let mutations):
            try c.encode(Kind.editPlist, forKey: .kind)
            try c.encode(path, forKey: .plist)
            try c.encode(mutations, forKey: .mutations)
        case .runWhitelistedCommand(let exec, let args):
            try c.encode(Kind.runWhitelistedCommand, forKey: .kind)
            try c.encode(exec, forKey: .executable)
            try c.encode(args, forKey: .args)
        case .thinBinaries(let paths, let keepArch):
            try c.encode(Kind.thinBinaries, forKey: .kind)
            try c.encode(paths, forKey: .paths)
            try c.encode(keepArch, forKey: .keepArch)
        case .emptyTrash(let paths):
            try c.encode(Kind.emptyTrash, forKey: .kind)
            try c.encode(paths, forKey: .paths)
        }
    }

    /// 撤销能力分级（基线 6.3 要点 4）。
    public var undoable: Bool {
        switch self {
        case .trash, .editPlist: return true
        case .backupAndRemove, .bootout: return true
        case .removeSystem, .bootstrap, .forgetReceipt, .emptyTrash,
             .resetTCC, .runWhitelistedCommand, .thinBinaries: return false
        }
    }

    /// 影响的路径（审计与进度展示）。
    public var affectedPaths: [String] {
        switch self {
        case .trash(let p), .removeSystem(let p), .backupAndRemove(let p, _),
             .thinBinaries(let p, _), .emptyTrash(let p):
            return p
        case .bootout(let plistPath), .editPlist(let plistPath, _):
            return [plistPath]
        case .bootstrap(let plistPath):
            return [plistPath]
        case .forgetReceipt(let pkgID): return [pkgID]
        case .resetTCC(let bundleID, _): return [bundleID]
        case .runWhitelistedCommand(let exec, _): return [exec]
        }
    }
}

/// 单条操作执行结果（基线 6.3 OperationResult）。
public struct OperationResult: Codable, Sendable {
    public let operation: Operation
    public let succeeded: [String]
    public let failed: [String: String]
    public let bytesReclaimed: Int64
    public let startedAt: Date
    public let finishedAt: Date

    public init(
        operation: Operation, succeeded: [String], failed: [String: String],
        bytesReclaimed: Int64, startedAt: Date, finishedAt: Date
    ) {
        self.operation = operation
        self.succeeded = succeeded
        self.failed = failed
        self.bytesReclaimed = bytesReclaimed
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }
}

/// 事务提交结果（基线 6.3 JournalResult；commit 永不抛错，失败用返回值表达）。
public struct JournalResult: Codable, Sendable {
    public let journalID: UUID
    public let results: [OperationResult]

    public var succeededCount: Int {
        results.reduce(0) { $0 + $1.succeeded.count }
    }

    public var failedCount: Int {
        results.reduce(0) { $0 + $1.failed.count }
    }

    public var undoable: Bool {
        results.contains { $0.operation.undoable }
    }

    public init(journalID: UUID, results: [OperationResult]) {
        self.journalID = journalID
        self.results = results
    }
}

/// 撤销结果（基线 6.3 UndoResult）。
public struct UndoResult: Codable, Sendable {
    public let restored: [String]
    public let unrestorable: [String: String]
    public let passed: Bool

    public init(restored: [String], unrestorable: [String: String], passed: Bool) {
        self.restored = restored
        self.unrestorable = unrestorable
        self.passed = passed
    }
}

/// 事务记录（operation_journal 表的内存形态）。
public struct JournalRecord: Codable, Sendable {
    public var journalID: UUID
    public var title: String
    public var ops: [Operation]
    public var results: [OperationResult]?
    public var status: String        // planned/committed/interrupted/undone
    public var createdAt: Date
    public var committedAt: Date?
    public var undoneAt: Date?
}