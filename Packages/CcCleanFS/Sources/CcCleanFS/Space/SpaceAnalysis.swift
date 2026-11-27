import Foundation
import CryptoKit
import CcCleanCore

/// 大文件分类（F2，基线 7.6 算法 1）。
public enum LargeFileCategory: String, Codable, Sendable, CaseIterable {
    case video, diskImage, archive, developer, other

    /// 按扩展名分类。
    public static func classify(path: String) -> LargeFileCategory {
        let ext = ((path as NSString).pathExtension).lowercased()
        switch ext {
        case "mp4", "mov", "mkv", "avi", "wmv", "m4v", "webm":
            return .video
        case "dmg", "iso", "img", "vhd", "vmdk":
            return .diskImage
        case "zip", "tar", "gz", "bz2", "xz", "7z", "rar":
            return .archive
        case "xcarchive", "o", "a", "dylib", "framework", "xcframework":
            return .developer
        default:
            return .other
        }
    }
}

/// 大文件条目（F2：> 50MB，基线 F2 验收）。
public struct LargeFileEntry: Sendable, Equatable, Identifiable {
    public var id: String { path }
    public let path: String
    public let bytes: Int64
    public let category: LargeFileCategory
    public let modifiedAt: Date

    public init(path: String, bytes: Int64, category: LargeFileCategory, modifiedAt: Date) {
        self.path = path
        self.bytes = bytes
        self.category = category
        self.modifiedAt = modifiedAt
    }
}

/// 大文件扫描服务（F2：基于 FSIndex 查询 + 分类，50MB 阈值可调）。
public actor LargeFileScanner {

    private let thresholdBytes: Int64

    public init(thresholdBytes: Int64 = 50 * 1024 * 1024) {
        self.thresholdBytes = thresholdBytes
    }

    /// 扫描大文件（FSIndex 查询 alloc_size 阈值 + 扩展名分类）。
    /// - Parameter roots: 扫描根（已索引卷）
    public func scan(index: FSIndex, roots: [String]) async -> [LargeFileEntry] {
        var query = FSQuery(roots: roots)
        query.minAllocatedSize = thresholdBytes
        query.limit = 500
        query.sortBy = .allocatedSize
        query.descending = true

        let nodes = await index.query(query)
        return nodes.filter { !$0.isDirectory }.map { node in
            LargeFileEntry(
                path: node.path, bytes: node.allocatedSize,
                category: LargeFileCategory.classify(path: node.path),
                modifiedAt: node.mtime
            )
        }
    }

    /// 分类汇总（体积降序）。
    public static func summarize(_ entries: [LargeFileEntry]) -> [(category: LargeFileCategory, bytes: Int64, count: Int)] {
        let byCategory = Dictionary(grouping: entries, by: \.category)
        return byCategory.map { (category: $0.key, bytes: $0.value.reduce(0) { $0 + $1.bytes }, count: $0.value.count) }
            .sorted { $0.bytes > $1.bytes }
    }
}

/// 旧文件条目（F5：mtime 依据，基线 7.6 算法 1）。
public struct OldFileEntry: Sendable, Equatable, Identifiable {
    public var id: String { path }
    public let path: String
    public let bytes: Int64
    public let lastModified: Date
    public let daysUnused: Int

    public init(path: String, bytes: Int64, lastModified: Date, daysUnused: Int) {
        self.path = path
        self.bytes = bytes
        self.lastModified = lastModified
        self.daysUnused = daysUnused
    }
}

extension LargeFileScanner {

    /// F5 旧文件筛选：按 lastModified 天数过滤（atime 在 APFS 默认关闭，基线以 mtime 为准）。
    public static func filterOldFiles(
        _ entries: [LargeFileEntry], olderThanDays: Int
    ) -> [LargeFileEntry] {
        let cutoff = Date().addingTimeInterval(-Double(olderThanDays) * 86400)
        return entries.filter { $0.modifiedAt < cutoff }
    }

    /// F6 安装包归类：30 天前的 dmg/pkg/iso 安装包（基线 F6：归类默认只列不删）。
    public static func staleInstallers(
        from entries: [LargeFileEntry], olderThanDays: Int = 30
    ) -> [LargeFileEntry] {
        let cutoff = Date().addingTimeInterval(-Double(olderThanDays) * 86400)
        return entries
            .filter { $0.category == .diskImage || $0.category == .archive }
            .filter { $0.modifiedAt < cutoff }
            .sorted { $0.modifiedAt < $1.modifiedAt }
    }
}

/// 重复文件组（F3，基线 7.6 算法 2：三级策略）。
public struct DuplicateGroup: Sendable, Equatable {
    /// 全部同内容文件（按 mtime 升序，最早的为默认保留项）
    public let paths: [String]
    public let bytesPerFile: Int64
    /// 默认保留最早文件，其余为待清理候选
    public var keepPath: String { paths.first ?? "" }
    public var removablePaths: [String] { Array(paths.dropFirst()) }
    public var reclaimableBytes: Int64 { Int64(paths.count - 1) * bytesPerFile }
    /// 是否存在硬链接组（inode 相同的成员不重复计费）
    public let hasHardlinks: Bool
}

/// 重复文件检测器（F3，基线 7.6 算法 2 三级策略）：
/// ① 尺寸分组 → ② 首/尾 4KB 粗筛（避免全量哈希）→ ③ 全量 SHA256 确认；
/// inode 硬链接不重复计费（F3 验收：硬链接标注）。
public actor DuplicateFileDetector {

    private let logger: Logger

    public init(logger: Logger) {
        self.logger = logger
    }

    /// 检测重复文件。
    /// - Parameters:
    ///   - candidates: 候选文件路径（通常来自 FSQuery 大文件或指定目录）
    public func detect(candidates: [String]) async -> [DuplicateGroup] {
        // ① 尺寸分组（同尺寸才可能同内容）
        var bySize: [Int64: [String]] = [:]
        for path in candidates {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                  let size = (attrs[.size] as? NSNumber)?.int64Value, size > 0 else { continue }
            bySize[size, default: []].append(path)
        }
        let sizeGroups = bySize.filter { $0.value.count > 1 }
        logger.info("duplicate: \(sizeGroups.count) size groups from \(candidates.count) candidates")

        // inode 硬链接判定（同 dev+ino → 同一文件，排除出重复组）
        var results: [DuplicateGroup] = []

        for (size, paths) in sizeGroups {
            // 硬链接过滤：同 inode 的成员只保留一个代表
            var uniquePaths: [String] = []
            var seenInodes = Set<UInt64>()
            var hasHardlinks = false
            for path in paths {
                if let inode = Self.inode(of: path) {
                    if seenInodes.contains(inode) {
                        hasHardlinks = true
                        continue   // 硬链接成员跳过（不重复计费）
                    }
                    seenInodes.insert(inode)
                }
                uniquePaths.append(path)
            }
            guard uniquePaths.count > 1 else {
                if hasHardlinks {
                    // 全部为硬链接组：标注但无清理候选
                    results.append(DuplicateGroup(
                        paths: [paths[0]], bytesPerFile: size, hasHardlinks: true))
                }
                continue
            }

            // ② 首/尾 4KB 粗筛
            let coarseFiltered = Self.coarseFilter(paths: uniquePaths, size: size)
            guard coarseFiltered.count > 1 else { continue }

            // ③ 全量 SHA256 确认
            let byHash = Self.groupByHash(paths: coarseFiltered)
            for (_, sameHashPaths) in byHash where sameHashPaths.count > 1 {
                // 按文件 mtime 升序（默认保留最早）
                let sorted = sameHashPaths.sorted {
                    (Self.mtime(of: $0) ?? .distantPast) < (Self.mtime(of: $1) ?? .distantPast)
                }
                results.append(DuplicateGroup(
                    paths: sorted, bytesPerFile: size, hasHardlinks: hasHardlinks))
            }
        }

        results.sort { $0.reclaimableBytes > $1.reclaimableBytes }
        logger.info("duplicate groups: \(results.count)")
        return results
    }

    // MARK: - 工具

    static func inode(of path: String) -> UInt64? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        return UInt64(st.st_ino)
    }

    static func mtime(of path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? nil
    }

    /// 首/尾 4KB 粗筛：同组内首尾块一致的文件聚簇。
    static func coarseFilter(paths: [String], size: Int64) -> [String] {
        guard size > 8192 else { return paths }   // 小文件直接进全量哈希
        var groups: [String: [String]] = [:]
        for path in paths {
            guard let handle = FileHandle(forReadingAtPath: path) else { continue }
            defer { try? handle.close() }
            let head = handle.readData(ofLength: 4096)
            try? handle.seek(toOffset: UInt64(max(0, size - 4096)))
            let tail = handle.readData(ofLength: 4096)
            let key = "\(head.hashValue)-\(tail.hashValue)"
            groups[key, default: []].append(path)
        }
        return groups.values.filter { $0.count > 1 }.flatMap { $0 }
    }

    /// 全量 SHA256 分组（上限 512MB/文件防呆）。
    static func groupByHash(paths: [String]) -> [String: [String]] {
        var byHash: [String: [String]] = [:]
        for path in paths {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                  let size = (attrs[.size] as? NSNumber)?.int64Value,
                  size <= 512 * 1024 * 1024,
                  let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { continue }
            let digest = SHA256.hash(data: data)
            let hex = digest.map { String(format: "%02x", $0) }.joined()
            byHash[hex, default: []].append(path)
        }
        return byHash
    }
}
