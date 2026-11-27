import Foundation

/// 卷类型（基线 6.1 跳过规则）。
public enum VolumeKind: Sendable, Hashable {
    case internalVolume
    case removable
    case network
    case timeMachine
    case optical
}

/// 索引策略（基线 6.1 接口签名）。
public struct IndexPolicy: Sendable {
    public var followSymlinks: Bool = false
    public var skipHidden: Bool = false
    /// .app/.framework 内部是否下探（A2 体积统计需要下探，索引默认 false）
    public var skipPackageDescendants: Bool = true
    public var maxDepth: Int = .max
    public var excludedVolumeKinds: Set<VolumeKind> = [.network, .timeMachine]
    /// getattrlistbulk 每次取条目缓冲大小
    public var bulkBatchSize: Int = 4096

    public init() {}
}

/// 索引结果统计（基线 6.1 FetchStats）。
public struct FetchStats: Sendable, Equatable {
    public var scannedEntries: Int = 0
    public var insertedNodes: Int = 0
    /// 目录 mtime + inode 未变而整棵跳过的子树数
    public var skippedSubtrees: Int = 0
    /// 读失败（缺全盘访问等）路径
    public var deniedPaths: [String] = []
    public var elapsed: Duration = .zero

    public init() {}
}

public enum FSSortKey: String, Sendable, Codable {
    case allocatedSize, logicalSize, mtime, name
}

/// 索引范围说明（供调用方语义区分）。
public enum FSScope: Sendable {
    case appBundle
    case library
    case custom(String)
}

/// 索引查询条件（基线 6.1 FSQuery）。
public struct FSQuery: Sendable {
    public var roots: [String]
    public var minAllocatedSize: Int64?
    public var extensions: Set<String>?
    public var modifiedAfter: Date?
    public var modifiedBefore: Date?
    public var isDirectory: Bool?
    public var sortBy: FSSortKey = .allocatedSize
    public var descending: Bool = true
    public var limit: Int = 500

    public init(roots: [String]) {
        self.roots = roots
    }
}

/// 索引节点（基线 6.1 FSNode）。
public struct FSNode: Sendable, Codable, Equatable {
    public let path: String
    public let parent: String
    public let isDirectory: Bool
    public let logicalSize: Int64
    public let allocatedSize: Int64
    public let mtime: Date
    public let inode: UInt64
    public let depth: Int
    /// getattrlist 返回的 ATTR_CMN_RETURNED_ATTRS 位图（保留审计用）
    public let flags: UInt32

    public init(
        path: String, parent: String, isDirectory: Bool,
        logicalSize: Int64, allocatedSize: Int64,
        mtime: Date, inode: UInt64, depth: Int, flags: UInt32 = 0
    ) {
        self.path = path
        self.parent = parent
        self.isDirectory = isDirectory
        self.logicalSize = logicalSize
        self.allocatedSize = allocatedSize
        self.mtime = mtime
        self.inode = inode
        self.depth = depth
        self.flags = flags
    }
}

/// 索引根元信息（基线 6.1 RootIndexStats）。
public struct RootIndexStats: Sendable, Equatable {
    public let rootPath: String
    public let lastIndexed: Date
    public let nodeCount: Int
    public let stale: Bool
    public let cursor: String?
}

/// 顶层目录分片信息（并发 worker 按 top-level 子目录切分，基线 6.1 要点 1）。
struct Shard: Sendable {
    let rootPath: String
    let rootID: Int64
    let path: String
    let depth: Int
}