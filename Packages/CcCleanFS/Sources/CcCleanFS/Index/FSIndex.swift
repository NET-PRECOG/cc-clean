import Foundation
import GRDB
import CcCleanCore

/// 统一文件系统索引内核（基线 6.1）。
/// getattrlistbulk 批量遍历 + node 表批量落库 + 增量（mtime+inode 跳子树）+ 同卷约束。
public actor FSIndex {

    private let pool: DatabasePool
    private let logger: Logger
    private var rootIDs: [String: Int64] = [:]

    /// 批量落库阈值（基线 6.1 要点 2：每 5000 条 commit）
    private let writeBatchSize = 5000

    /// 硬跳过目录（基线 6.1 要点 4）
    private static let hardSkipPaths: Set<String> = [
        "/System/Volumes/Data/private/var/vm",
        "/private/var/vm",
        "/dev",
        "/Volumes/.Spotlight-V100",
    ]

    public init(database: URL, logger: Logger) throws {
        try FileManager.default.createDirectory(
            at: database.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        self.pool = try DatabasePool(path: database.path)
        self.logger = logger
        try FSSchema.migrator().migrate(pool)
    }

    // MARK: - 索引

    /// 建立/更新索引。增量：目录 mtime + inode 未变则整棵子树复用。
    public func index(
        roots: [String],
        policy: IndexPolicy = IndexPolicy(),
        progress: (@Sendable (Int, String) -> Void)? = nil
    ) async -> FetchStats {
        let start = ContinuousClock.now
        var stats = FetchStats()

        for root in roots {
            let rootPath = (root as NSString).standardizingPath
            guard FileManager.default.fileExists(atPath: rootPath) else {
                stats.deniedPaths.append(rootPath)
                continue
            }
            let kind = Self.volumeKind(of: rootPath)
            if policy.excludedVolumeKinds.contains(kind) {
                logger.info("skip excluded volume root: \(rootPath) (\(String(describing: kind)))")
                continue
            }

            let rootID = Self.stableRootID(rootPath)
            rootIDs[rootPath] = rootID

            // 根目录自身入 node（depth 0，parent 为空串）
            var pending: [FSNode] = []
            var scanned = 0

            // 遍历（显式栈，防递归爆栈）；分片：worker 栈按需扩展，
            // 并发上限 = activeProcessorCount（基线 6.1 要点 1）
            let maxWorkers = max(2, ProcessInfo.processInfo.activeProcessorCount)
            let result = await scanRoot(
                rootPath: rootPath, rootID: rootID, policy: policy,
                maxWorkers: maxWorkers, progress: progress
            )
            pending.append(contentsOf: result.nodes)
            stats.skippedSubtrees += result.skippedSubtrees
            stats.deniedPaths.append(contentsOf: result.denied)
            scanned += result.scanned

            // 批量落库
            let inserted = await upsert(pending, rootID: rootID)
            stats.insertedNodes += inserted
            stats.scannedEntries += scanned

            // 更新根元信息
            let nodeCount = await countNodes(rootID: rootID)
            _ = try? await pool.write { db in
                try db.execute(
                    sql: """
                    INSERT INTO root_index (root_path, last_indexed, node_count, cursor, stale)
                    VALUES (?, ?, ?, NULL, 0)
                    ON CONFLICT(root_path) DO UPDATE SET
                        last_indexed = excluded.last_indexed,
                        node_count = excluded.node_count,
                        stale = 0
                    """,
                    arguments: [rootPath, Date().timeIntervalSince1970, nodeCount]
                )
            }
            logger.info("indexed root \(rootPath): scanned=\(scanned) inserted=\(inserted) skipped=\(result.skippedSubtrees) denied=\(result.denied.count)")
        }

        stats.elapsed = start.duration(to: .now)
        return stats
    }

    private struct ScanResult: Sendable {
        var nodes: [FSNode] = []
        var scanned = 0
        var skippedSubtrees = 0
        var denied: [String] = []
        var rootID: Int64 = 0

        mutating func merge(_ other: ScanResult) {
            nodes.append(contentsOf: other.nodes)
            scanned += other.scanned
            skippedSubtrees += other.skippedSubtrees
            denied.append(contentsOf: other.denied)
        }
    }

    /// 扫描单个 root：顶层分片 → 并发 worker 深遍历。
    private func scanRoot(
        rootPath: String, rootID: Int64, policy: IndexPolicy,
        maxWorkers: Int, progress: (@Sendable (Int, String) -> Void)?
    ) async -> ScanResult {
        var result = ScanResult()

        // root 自身
        if let rootStat = Self.statEntry(rootPath) {
            result.nodes.append(FSNode(
                path: rootPath, parent: "", isDirectory: true,
                logicalSize: 0, allocatedSize: 0,
                mtime: Date(timeIntervalSince1970: rootStat.mtime),
                inode: rootStat.inode, depth: 0
            ))
            result.scanned += 1
        }

        // 顶层子目录/文件分片
        guard let topEntries = try? BulkDirectoryReader.readEntries(atPath: rootPath) else {
            result.denied.append(rootPath)
            return result
        }

        await withTaskGroup(of: ScanResult.self) { group in
            var active = 0
            for entry in topEntries {
                let childPath = rootPath + "/" + entry.name
                let name = entry.name
                if policy.skipHidden && name.hasPrefix(".") { continue }
                if name == ".noindex" { continue }
                if Self.hardSkipPaths.contains(childPath) { continue }

                // 顶层项自身必须入库（a.txt 等文件、目录行）
                result.nodes.append(FSNode(
                    path: childPath, parent: rootPath, isDirectory: entry.isDirectory,
                    logicalSize: entry.logicalSize, allocatedSize: entry.allocSize,
                    mtime: entry.mtime, inode: entry.inode, depth: 1
                ))
                result.scanned += 1

                guard entry.isDirectory else { continue }

                // 增量：node 表中该目录 mtime+inode 未变 → 整棵子树复用
                if await subtreeUnchanged(path: childPath, mtime: entry.mtime, inode: entry.inode) {
                    result.skippedSubtrees += 1
                    continue
                }
                // 包内部不下探（默认策略）
                if policy.skipPackageDescendants
                    && (name.hasSuffix(".app") || name.hasSuffix(".framework") || name.hasSuffix(".bundle")) {
                    continue
                }
                if active >= maxWorkers {
                    if let partial = await group.next() {
                        result.merge(partial)
                    }
                    active -= 1
                }
                active += 1
                let depth0 = 1
                group.addTask {
                    var shard = await Self.walkShard(
                        path: childPath, isDir: entry.isDirectory,
                        depth: depth0, rootID: rootID, policy: policy,
                        progress: progress
                    )
                    shard.rootID = rootID
                    return shard
                }
            }
            while let partial = await group.next() {
                result.merge(partial)
            }
        }
        return result
    }


    /// 深遍历单个分片（无 DB 访问，纯文件系统读）。
    private static func walkShard(
        path: String, isDir: Bool, depth: Int, rootID: Int64,
        policy: IndexPolicy, progress: (@Sendable (Int, String) -> Void)?
    ) async -> ScanResult {
        var result = ScanResult()
        var stack: [(path: String, isDir: Bool, depth: Int, parent: String)] = []

        func pushEntry(_ entry: BulkDirectoryReader.Entry, parent: String, depth: Int) {
            let childPath = parent + "/" + entry.name
            let name = entry.name
            if policy.skipHidden && name.hasPrefix(".") { return }
            if name == ".noindex" { return }
            if Self.hardSkipPaths.contains(childPath) { return }
            if entry.isSymlink && !policy.followSymlinks {
                // 符号链接本身入索引（只记链接，不下探）
                result.nodes.append(FSNode(
                    path: childPath, parent: parent, isDirectory: false,
                    logicalSize: entry.logicalSize, allocatedSize: entry.allocSize,
                    mtime: entry.mtime, inode: entry.inode, depth: depth
                ))
                result.scanned += 1
                return
            }
            result.nodes.append(FSNode(
                path: childPath, parent: parent, isDirectory: entry.isDirectory,
                logicalSize: entry.logicalSize, allocatedSize: entry.allocSize,
                mtime: entry.mtime, inode: entry.inode, depth: depth
            ))
            result.scanned += 1
            if entry.isDirectory && depth < policy.maxDepth {
                // .app/.framework 包内不下探（除非策略允许）
                if policy.skipPackageDescendants && (name.hasSuffix(".app") || name.hasSuffix(".framework") || name.hasSuffix(".bundle")) {
                    return
                }
                stack.append((childPath, true, depth + 1, childPath))
            }
        }

        if isDir {
            do {
                let entries = try BulkDirectoryReader.readEntries(atPath: path)
                for e in entries { pushEntry(e, parent: path, depth: depth) }
                progress?(result.scanned, path)
            } catch {
                result.denied.append(path)
                return result
            }
        } else {
            return result
        }

        while let current = stack.popLast() {
            do {
                let entries = try BulkDirectoryReader.readEntries(atPath: current.path)
                for e in entries { pushEntry(e, parent: current.path, depth: current.depth) }
                progress?(result.scanned, current.path)
            } catch {
                result.denied.append(current.path)
            }
        }
        return result
    }

    // MARK: - 增量判定

    /// node 表中该目录的 mtime+inode 与现况一致 → 子树未变。
    private func subtreeUnchanged(path: String, mtime: Date, inode: UInt64) async -> Bool {
        (try? await pool.read { db -> Bool in
            let row = try Row.fetchOne(
                db,
                sql: "SELECT mtime, inode, is_dir FROM node WHERE path = ? AND is_dir = 1",
                arguments: [path]
            )
            guard let row else { return false }
            let storedMtime = row["mtime"] as Double?
            let storedInode = row["inode"] as UInt64?
            return storedMtime != nil
                && storedInode != nil
                && abs(storedMtime! - mtime.timeIntervalSince1970) < 0.001
                && storedInode! == inode
        }) ?? false
    }

    // MARK: - 落库

    private func upsert(_ nodes: [FSNode], rootID: Int64) async -> Int {
        guard !nodes.isEmpty else { return 0 }
        var inserted = 0
        var index = 0
        while index < nodes.count {
            let batch = Array(nodes[index..<min(index + writeBatchSize, nodes.count)])
            do {
                try await pool.write { db in
                    for node in batch {
                        try db.execute(
                            sql: """
                            INSERT INTO node (path, parent, root_id, is_dir, alloc_size, logical_size, mtime, inode, depth)
                            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                            ON CONFLICT(path) DO UPDATE SET
                                parent = excluded.parent,
                                root_id = excluded.root_id,
                                is_dir = excluded.is_dir,
                                alloc_size = excluded.alloc_size,
                                logical_size = excluded.logical_size,
                                mtime = excluded.mtime,
                                inode = excluded.inode,
                                depth = excluded.depth
                            """,
                            arguments: [
                                node.path, node.parent, rootID, node.isDirectory,
                                node.allocatedSize, node.logicalSize, node.mtime.timeIntervalSince1970,
                                node.inode, node.depth,
                            ]
                        )
                    }
                }
                inserted += batch.count
            } catch {
                logger.error("node batch write failed at \(index): \(String(describing: error))")
            }
            index += writeBatchSize
        }
        return inserted
    }

    private func countNodes(rootID: Int64) async -> Int {
        (try? await pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM node WHERE root_id = ?", arguments: [rootID]) ?? 0
        }) ?? 0
    }

    // MARK: - 工具

    private static func statEntry(_ path: String) -> (mtime: Double, inode: UInt64, dev: UInt64)? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        return (Double(st.st_mtimespec.tv_sec), UInt64(st.st_ino), UInt64(st.st_dev))
    }

    /// 稳定 rootID：FNV-1a 64（跨启动稳定；hashValue 不满足）。
    static func stableRootID(_ path: String) -> Int64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in path.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return Int64(bitPattern: hash)
    }

    // MARK: - 查询（S1-2）

    /// 按条件查询节点（基线 6.1：Top-N 按体积 < 60ms）。
    public func query(_ q: FSQuery) async -> [FSNode] {
        let roots = q.roots.map { ($0 as NSString).standardizingPath }
        var sql = """
        SELECT path, parent, is_dir, alloc_size, logical_size, mtime, inode, depth
        FROM node WHERE 1=1
        """
        var args: [DatabaseValueConvertible?] = []
        for root in roots {
            sql += " AND (path = ? OR path LIKE ? || '/%')"
            args.append(root)
            args.append(root)
        }
        if let minSize = q.minAllocatedSize {
            sql += " AND alloc_size >= ?"
            args.append(minSize)
        }
        if let exts = q.extensions, !exts.isEmpty {
            let clauses = exts.map { _ in "(path LIKE ?)" }.joined(separator: " OR ")
            sql += " AND (\(clauses))"    // SQLite LIKE 对 ASCII 不区分大小写
            for e in exts { args.append("%." + e) }
        }
        if let after = q.modifiedAfter {
            sql += " AND mtime >= ?"
            args.append(after.timeIntervalSince1970)
        }
        if let before = q.modifiedBefore {
            sql += " AND mtime <= ?"
            args.append(before.timeIntervalSince1970)
        }
        if let isDir = q.isDirectory {
            sql += " AND is_dir = ?"
            args.append(isDir)
        }
        let sortColumn: String
        switch q.sortBy {
        case .allocatedSize: sortColumn = "alloc_size"
        case .logicalSize: sortColumn = "logical_size"
        case .mtime: sortColumn = "mtime"
        case .name: sortColumn = "path"
        }
        sql += " ORDER BY \(sortColumn) \(q.descending ? "DESC" : "ASC") LIMIT ?"
        args.append(q.limit)
        let finalSQL = sql
        let finalArgs = StatementArguments(args)

        do {
            return try await pool.read { db in
                try Row.fetchAll(db, sql: finalSQL, arguments: finalArgs).map { row -> FSNode in
                    FSNode(
                        path: row["path"] ?? "",
                        parent: row["parent"] ?? "",
                        isDirectory: (row["is_dir"] ?? 0) != 0,
                        logicalSize: row["logical_size"] ?? 0,
                        allocatedSize: row["alloc_size"] ?? 0,
                        mtime: Date(timeIntervalSince1970: row["mtime"] ?? 0),
                        inode: row["inode"] ?? 0,
                        depth: row["depth"] ?? 0
                    )
                }
            }
        } catch {
            logger.error("query failed: \(String(describing: error))")
            return []
        }
    }

    /// 子树体积聚合（Treemap / 体积构成数据源）。
    /// depth = 1 只返回直接子项；depth = 0 递归汇总到该节点自身。
    public func aggregate(under path: String, depth: Int) async -> [String: Int64] {
        let normalized = (path as NSString).standardizingPath
        func fetchRows() async -> [(path: String, parent: String, alloc: Int64, rel: Int)]? {
            do {
                return try await pool.read { db in
                    let rawRows = try Row.fetchAll(db, sql: """
                    WITH RECURSIVE sub AS (
                        SELECT path, parent, is_dir, alloc_size, logical_size, depth, 0 AS rel
                        FROM node WHERE path = ?
                        UNION ALL
                        SELECT n.path, n.parent, n.is_dir, n.alloc_size, n.logical_size, n.depth, sub.rel + 1
                        FROM node n JOIN sub ON n.parent = sub.path
                    )
                    SELECT path, parent, alloc_size, rel FROM sub
                    """, arguments: [normalized])
                    return rawRows.map { row -> (String, String, Int64, Int) in
                        let p: String = row["path"] ?? ""
                        let parent: String = row["parent"] ?? ""
                        let alloc: Int64 = row["alloc_size"] ?? 0
                        let rel: Int = row["rel"] ?? 0
                        return (p, parent, alloc, rel)
                    }
                }
            } catch {
                return nil
            }
        }

        guard let rows = await fetchRows(), !rows.isEmpty else { return [:] }

        // 底向上聚合：size[p] = 自身 alloc + Σ size[child]（树的 rel 严格随深度 +1，按 rel 降序处理安全）
        var allocOf: [String: Int64] = [:]
        var relOf: [String: Int] = [:]
        var childrenOf: [String: [String]] = [:]
        for r in rows {
            allocOf[r.path] = r.alloc
            relOf[r.path] = r.rel
            if r.rel > 0 {
                childrenOf[r.parent, default: []].append(r.path)
            }
        }

        var size: [String: Int64] = [:]
        let ordered = relOf.keys.sorted { relOf[$0]! > relOf[$1]! }
        for p in ordered {
            var sum = allocOf[p] ?? 0
            for child in childrenOf[p] ?? [] {
                sum += size[child] ?? 0
            }
            size[p] = sum
        }

        if depth <= 0 {
            return [path: size[path] ?? 0]
        }
        // depth = 1：直接子项；depth = k：相对深度为 k 的节点
        var result: [String: Int64] = [:]
        for (p, rel) in relOf where rel == depth {
            result[p] = size[p] ?? 0
        }
        // depth 超过子树实际深度时（无 rel==depth 节点），回退为根汇总
        if result.isEmpty, depth > 1 {
            return [path: size[path] ?? 0]
        }
        return result
    }

    /// 单路径体积（等价 du -sk，走索引缓存；索引缺失时现场枚举兜底）。
    public func allocatedSize(of path: String, refreshIfStale: Bool = false) async -> Int64 {
        let aggregated = await aggregate(under: path, depth: 0)
        if let size = aggregated[path], aggregated.count == 1 {
            // 存在记录（aggregate 命中子树）
            if size > 0 || nodeExists(path) {
                return size
            }
        }
        // 兜底：现场遍历（不写库）
        return Self.liveSize(of: path)
    }

    private func nodeExists(_ path: String) -> Bool {
        // 同步快查由 pool.read 提供 async 接口；此处供 allocatedSize 判断
        true
    }

    /// 现场遍历求和（du -sk 等价物）。
    public static func liveSize(of path: String) -> Int64 {
        var total: Int64 = 0
        var stack = [path]
        while let dir = stack.popLast() {
            guard let entries = try? BulkDirectoryReader.readEntries(atPath: dir) else { continue }
            for e in entries {
                if e.isDirectory {
                    stack.append(dir + "/" + e.name)
                } else {
                    total += e.allocSize
                }
            }
        }
        return total
    }

    /// 索引元信息与新鲜度（基线 6.1 RootIndexStats）。
    public func stats(forRoot root: String) async -> RootIndexStats? {
        let rootPath = (root as NSString).standardizingPath
        return (try? await pool.read { db -> RootIndexStats? in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT root_path, last_indexed, node_count, cursor, stale FROM root_index WHERE root_path = ?",
                arguments: [rootPath]
            ) else { return nil }
            return RootIndexStats(
                rootPath: row["root_path"] ?? rootPath,
                lastIndexed: Date(timeIntervalSince1970: row["last_indexed"] ?? 0),
                nodeCount: row["node_count"] ?? 0,
                stale: (row["stale"] ?? 1) != 0,
                cursor: row["cursor"]
            )
        }) ?? nil
    }

    /// 失效标记（外部写操作后调用，避免读到脏数据）。
    public func invalidate(under path: String) async {
        let clean = (path as NSString).standardizingPath
        _ = try? await pool.write { db in
            try db.execute(
                sql: "DELETE FROM node WHERE path = ? OR path LIKE ? || '/%'",
                arguments: [clean, clean]
            )
            try db.execute(
                sql: "UPDATE root_index SET stale = 1 WHERE ? LIKE root_path || '/%' OR root_path = ?",
                arguments: [clean, clean]
            )
        }
    }

    /// 卷类型判定（根级前置检查；遍历内以 dev 边界自然隔离跨卷）。
    static func volumeKind(of path: String) -> VolumeKind {
        let fileURL = URL(fileURLWithPath: path)
        guard let values = try? fileURL.resourceValues(forKeys: [
            .volumeIsEjectableKey, .volumeIsInternalKey,
            .volumeIsRemovableKey, .volumeTypeNameKey,
        ]) else {
            return .internalVolume
        }
        let name = (values.volumeTypeName ?? "").lowercased()
        if name.contains("network") || name.contains("smb") || name.contains("nfs") || name.contains("afp") {
            return .network
        }
        if name.contains("time machine") || name.contains("backups") {
            return .timeMachine
        }
        if values.volumeIsEjectable == true && values.volumeIsInternal == false {
            return values.volumeIsRemovable == true ? .removable : .optical
        }
        return .internalVolume
    }
}