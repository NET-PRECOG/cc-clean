import Foundation
import Observation
import CcCleanCore
import CcCleanFS
import CcCleanOps

/// 清理分类（侧栏项）：CleanUp 风格大类，规则命中按展示分组归并；孤儿文件归「应用残留」。
/// 固定全量展示——无命中分类显示 0 而不是消失；locked 分类仅展示不可勾选。
struct ReviewCategory: Identifiable, Equatable {
    static let residueID = "residue"

    let id: String
    let title: String
    let subtitle: String
    let icon: String
    let bytes: Int64
    let risk: RiskLevel
    let locked: Bool
    let items: [ReviewItem]
}

/// 审查详情文件行：size 为 nil 表示未知（目录/无统计），UI 显示 "—" 不伪造数据。
struct ReviewItem: Identifiable, Equatable {
    var id: String { path }
    let path: String
    let size: Int64?
    let detail: String?
}

/// 废纸篓条目（扫描统计）。
struct TrashItem: Identifiable, Equatable {
    var id: String { path }
    let path: String
    let size: Int64
}

/// 智能扫描 ViewModel：规则垃圾（.cleanup 范围）+ 孤儿文件 + 废纸篓 + 损坏登录项扫描，
/// 路径级勾选（selectedPaths 为智能扫描页与审查详情页共用唯一状态源），
/// 一键清理按路径类型分区走 OperationJournal（trash / emptyTrash / bootout），trash 可撤销。
@Observable
@MainActor
final class SmartScanViewModel {
    enum Phase: Equatable {
        case idle
        case scanning(step: String)
        case done
        case failed(String)
    }

    /// 一键清理子状态（仅在 phase == .done 后有意义）。
    enum CleanState: Equatable {
        case idle
        case running
        case finished(succeeded: Int, failed: Int, bytesReclaimed: Int64)
    }

    private(set) var phase: Phase = .idle
    private(set) var junkHits: [RuleHit] = []
    private(set) var orphans: [OrphanScanner.OrphanFinding] = []
    private(set) var trashItems: [TrashItem] = []
    private(set) var zombies: [ZombieScanner.Finding] = []
    private(set) var elapsed: TimeInterval = 0

    /// 清理分类（扫描完成后构建；清理后重建；固定全量，0 就 0）。
    private(set) var categories: [ReviewCategory] = []
    /// 路径级勾选集合（默认全选非锁定安全项）。
    private(set) var selectedPaths: Set<String> = []

    private(set) var cleanState: CleanState = .idle
    private(set) var lastCleanupJournalID: UUID?

    private let engine = RuleEngine(protected: .builtin, logger: Logger(category: .scan))
    private let orphanScanner = OrphanScanner()
    private var rulesLoaded = false

    // MARK: - 统计

    var junkItemCount: Int { junkHits.reduce(0) { $0 + $1.paths.count } }
    var junkBytes: Int64 { junkHits.reduce(0) { $0 + $1.totalBytes } }
    var orphanBytes: Int64 { orphans.reduce(0) { $0 + ($1.sizeBytes ?? 0) } }
    var trashBytes: Int64 { trashItems.reduce(0) { $0 + $1.size } }
    var totalBytes: Int64 { junkBytes + orphanBytes + trashBytes }

    /// 可纳入一键清理的规则（低/中风险且非系统级；高危与 requiresRoot 永不自动执行）。
    var cleanableHits: [RuleHit] {
        junkHits.filter { $0.rule.risk != .high && !$0.rule.requiresRoot }
    }

    /// 不纳入一键清理的规则（高危 / 需辅助程序，固定展示锁定原因）。
    var lockedHits: [RuleHit] {
        junkHits.filter { $0.rule.risk == .high || $0.rule.requiresRoot }
    }

    var selectedCount: Int { selectedPaths.count }

    /// 勾选合计（分类全选按规则权威体积计；部分选中按条目体积累加）。
    var selectedBytes: Int64 {
        categories.filter { !$0.locked }.reduce(0) { sum, cat in
            if !cat.items.isEmpty && cat.items.allSatisfy({ selectedPaths.contains($0.path) }) {
                return sum + cat.bytes
            }
            return sum + cat.items
                .filter { selectedPaths.contains($0.path) }
                .reduce(0) { $0 + ($1.size ?? 0) }
        }
    }

    var canClean: Bool { selectedCount > 0 }

    /// 是否全选（侧栏「全选」按钮态；锁定分类不参与）。
    var allSelected: Bool {
        let all = categories.filter { !$0.locked }.flatMap { $0.items.map(\.path) }
        return !all.isEmpty && all.allSatisfy { selectedPaths.contains($0) }
    }

    /// 全选 / 全不选（侧栏「全选」按钮；锁定分类不参与）。
    func toggleAllSelection() {
        if allSelected {
            selectedPaths.removeAll()
        } else {
            selectedPaths = Set(categories.filter { !$0.locked }.flatMap { $0.items.map(\.path) })
        }
    }

    // MARK: - 扫描

    /// 顺序扫描（垃圾 → 孤儿 → 废纸篓 → 损坏登录项；同步重方法放 detached 避免卡主线程）。
    /// 规则评估在引擎内并行（预算 60s，CleanUp 式全量扫描不因 10s 截断）。
    func startScan() async {
        guard cleanState != .running else { return }
        isScanning = true
        let start = Date()
        defer { isScanning = false }

        do {
            phase = .scanning(step: "加载清理规则…")
            if !rulesLoaded {
                try await engine.load(BundledRuleLoader.load())
                rulesLoaded = true
            }

            phase = .scanning(step: "扫描系统垃圾…")
            junkHits = await engine.evaluate(RuleContext(scope: .cleanup, budget: .seconds(60)))

            phase = .scanning(step: "扫描孤儿文件（应用已卸载的残留）…")
            let installed = Set(
                AppScanner.enumerateApps(under: "/Applications").map {
                    (($0 as NSString).lastPathComponent as NSString).deletingPathExtension
                })
            let home = NSHomeDirectory()
            let scanner = orphanScanner
            orphans = await Task.detached {
                scanner.scan(home: home, installedBundleIds: installed)
            }.value

            phase = .scanning(step: "统计废纸篓…")
            trashItems = await Task.detached { Self.scanTrash() }.value

            phase = .scanning(step: "检查损坏的登录项…")
            let zombieScanner = ZombieScanner()
            zombies = await Task.detached {
                zombieScanner.scan(home: home, knownBundles: [])
            }.value

            elapsed = Date().timeIntervalSince(start)
            rebuildCategories()
            resetSelection()
            phase = .done
        } catch {
            phase = .failed("扫描失败：\((error as NSError).localizedDescription)")
        }
    }

    private var isScanning = false

    /// 扫描完成后的默认勾选：非锁定安全项全部选中；清理子状态复位。
    private func resetSelection() {
        selectedPaths = Set(categories.filter { !$0.locked }.flatMap { $0.items.map(\.path) })
        cleanState = .idle
        lastCleanupJournalID = nil
    }

    /// 构建清理分类：固定全量展示（CleanUp 同款——无命中分类显示 0，清理完不消失）。
    private func rebuildCategories() {
        // 规则命中按展示分组归桶（路径去重，防规则间包含关系重复计费）
        var buckets: [String: (paths: Set<String>, bytes: Int64)] = [:]
        for hit in junkHits {
            let key = Self.groupKey(forRuleID: hit.rule.id)
            var bucket = buckets[key] ?? ([], 0)
            hit.paths.forEach { bucket.paths.insert($0) }
            bucket.bytes += hit.totalBytes
            buckets[key] = bucket
        }

        // 固定分类（含锁定组：无命中也显示 0，锁定项不可勾选）
        var list: [ReviewCategory] = Self.displayGroups.map { group in
            let bucket = buckets[group.key]
            let items = (bucket?.paths ?? []).sorted().map {
                ReviewItem(path: $0, size: Self.fileSize($0), detail: nil)
            }
            return ReviewCategory(
                id: group.key, title: group.title, subtitle: group.subtitle,
                icon: group.icon, bytes: bucket?.bytes ?? 0,
                risk: group.locked ? .high : .low, locked: group.locked, items: items
            )
        }
        // 兜底桶（意外命中才显示）
        if let other = buckets["other"], !other.paths.isEmpty {
            let items = other.paths.sorted().map {
                ReviewItem(path: $0, size: Self.fileSize($0), detail: nil)
            }
            list.append(ReviewCategory(
                id: "other", title: "其他可清理项",
                subtitle: "扫描发现的可清理文件", icon: "ellipsis.circle.fill",
                bytes: other.bytes, risk: .low, locked: false, items: items
            ))
        }

        // 动态分类固定展示（0 就 0）
        list.append(ReviewCategory(
            id: "trash", title: "废纸篓",
            subtitle: "废纸篓中的全部文件；清空后不可撤销",
            icon: "trash.slash.fill", bytes: trashBytes, risk: .medium, locked: false,
            items: trashItems.map { ReviewItem(path: $0.path, size: $0.size, detail: nil) }
        ))
        list.append(ReviewCategory(
            id: "brokenLogins", title: "损坏的登录项",
            subtitle: "指向已不存在程序的启动项，禁用后可重新启用（需辅助程序）",
            icon: "link.badge.plus", bytes: 0, risk: .medium, locked: false,
            items: zombies.map {
                ReviewItem(path: $0.entry.plistPath, size: nil,
                           detail: $0.reasons.joined(separator: "；"))
            }
        ))
        list.append(ReviewCategory(
            id: ReviewCategory.residueID, title: "应用残留",
            subtitle: "已卸载应用遗留的用户库文件，可撤销恢复",
            icon: "folder.badge.questionmark", bytes: orphanBytes, risk: .low, locked: false,
            items: orphans.map {
                ReviewItem(path: $0.path, size: $0.sizeBytes, detail: $0.bundleIdCandidate)
            }
        ))
        categories = list
    }

    /// 展示分组表（CleanUp 风格大类，用户可读；locked = true 仅展示不可勾选）。
    private static let displayGroups: [(key: String, title: String, subtitle: String, icon: String, locked: Bool)] = [
        ("userCache", "用户缓存", "应用、浏览器与聊天工具产生的缓存文件", "folder.fill", false),
        ("diskImages", "不使用的磁盘镜像", "下载与桌面中 30 天前的 dmg / pkg 安装包", "archivebox.fill", false),
        ("xcode", "Xcode 垃圾", "Xcode 编译产物、模拟器缓存与历史归档", "hammer.fill", false),
        ("sysCache", "系统缓存", "系统级缓存目录（/Library/Caches）", "gearshape.2.fill", false),
        ("downloads", "下载", "下载文件夹中 30 天未使用的文件", "arrow.down.circle.fill", false),
        ("userLogs", "用户日志", "应用写入的日志文件", "doc.text.fill", false),
        ("crashReports", "崩溃报告", "应用崩溃生成的诊断报告", "ladybug.fill", false),
        ("mail", "邮件附件", "高危：删除后需从服务器重新下载，请手动确认", "envelope.open.fill", true),
        ("iosBackup", "iOS 设备备份", "高危：本地备份删除后不可恢复，请先确认云端备份", "iphone.gen3", true),
        ("sysTmp", "系统临时文件", "系统目录，需辅助程序（Helper）清理", "key.fill", true),
    ]

    /// 规则 id → 展示分组 key（浏览器 / IM / 照片缓存并入「用户缓存」）。
    private static func groupKey(forRuleID ruleID: String) -> String {
        switch ruleID {
        case "cleanup.system.user-cache", "cleanup.photos.cache",
             "cleanup.browser.safari-cache", "cleanup.browser.chrome-cache",
             "cleanup.browser.edge-cache",
             "cleanup.im.wechat-cache", "cleanup.im.qq-cache":
            return "userCache"
        case "cleanup.system.user-logs":
            return "userLogs"
        case "cleanup.system.crash-reports":
            return "crashReports"
        case "cleanup.installer.dmg":
            return "diskImages"
        case "cleanup.xcode.derived-data":
            return "xcode"
        case "cleanup.system.sys-cache":
            return "sysCache"
        case "cleanup.misc.downloads":
            return "downloads"
        case "cleanup.mail.attachments":
            return "mail"
        case "cleanup.ios.backup":
            return "iosBackup"
        case "cleanup.system.tmp":
            return "sysTmp"
        default:
            return "other"
        }
    }

    /// 单路径即时体积（不可得返回 nil）。
    nonisolated private static func fileSize(_ path: String) -> Int64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (attrs[.size] as? NSNumber)?.int64Value, size > 0 else { return nil }
        return size
    }

    /// 废纸篓条目统计（depth 1 + 逐项递归体积）。
    nonisolated private static func scanTrash() -> [TrashItem] {
        let trash = NSHomeDirectory() + "/.Trash"
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: trash) else { return [] }
        return names.map { name in
            let path = trash + "/" + name
            return TrashItem(path: path, size: recursiveSize(path))
        }
    }

    /// 递归统计路径大小（限深 12 防符号链接循环）。
    nonisolated private static func recursiveSize(_ path: String, depth: Int = 0) -> Int64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir) else { return 0 }
        guard isDir.boolValue else { return fileSize(path) ?? 0 }
        guard depth < 12, let children = try? fm.contentsOfDirectory(atPath: path) else { return 0 }
        return children.reduce(Int64(0)) { $0 + recursiveSize(path + "/" + $1, depth: depth + 1) }
    }

    // MARK: - 勾选（分类级 / 路径级，两层共用 selectedPaths）

    /// 分类是否全选。
    func categoryFullySelected(_ id: String) -> Bool {
        guard let cat = categories.first(where: { $0.id == id }), !cat.locked else { return false }
        return !cat.items.isEmpty && cat.items.allSatisfy { selectedPaths.contains($0.path) }
    }

    /// 分类级切换（全选 ↔ 全不选；锁定分类不可切换）。
    func toggleCategory(_ id: String) {
        guard let cat = categories.first(where: { $0.id == id }), !cat.locked else { return }
        let paths = cat.items.map(\.path)
        if categoryFullySelected(id) {
            selectedPaths.subtract(paths)
        } else {
            selectedPaths.formUnion(paths)
        }
    }

    /// 路径级切换（审查详情文件行；锁定分类路径不可勾）。
    func togglePath(_ path: String) {
        guard !isLockedPath(path) else { return }
        if selectedPaths.contains(path) {
            selectedPaths.remove(path)
        } else {
            selectedPaths.insert(path)
        }
    }

    /// 路径是否属于锁定分类。
    private func isLockedPath(_ path: String) -> Bool {
        categories.contains { $0.locked && $0.items.contains(where: { $0.path == path }) }
    }

    // MARK: - 一键清理

    /// 一键清理：按路径类型分区走不同 Operation（同一事务）：
    /// 普通垃圾 / 孤儿 → trash（可撤销）；废纸篓条目 → emptyTrash（不可撤销）；
    /// 损坏登录项 → bootout（Helper 缺席时失败原因明确）。
    func cleanSelected() async {
        let selected = selectedPaths
        guard !selected.isEmpty, cleanState != .running else { return }

        cleanState = .running
        let journal = OperationJournalHolder.shared(store: DatabaseStoreHolder.shared)

        let trashPrefix = NSHomeDirectory() + "/.Trash/"
        let zombieSet = Set(zombies.map { $0.entry.plistPath })
        let trashBinPaths = selected.filter { $0.hasPrefix(trashPrefix) }
        let zombiePaths = selected.filter { zombieSet.contains($0) }
        let generalPaths = selected.filter { !trashBinPaths.contains($0) && !zombieSet.contains($0) }

        let id = await journal.begin("一键清理")
        if !generalPaths.isEmpty {
            try? await journal.append(.trash(paths: Array(generalPaths)), to: id)
        }
        if !trashBinPaths.isEmpty {
            try? await journal.append(.emptyTrash(paths: Array(trashBinPaths)), to: id)
        }
        for plist in zombiePaths {
            try? await journal.append(.bootout(plist: plist), to: id)
        }
        let result = await journal.commit(id)
        lastCleanupJournalID = id

        let cleaned = Set(result.results.flatMap { $0.succeeded })
        let failed = result.results.reduce(into: [String: String]()) {
            $0.merge($1.failed) { _, new in new }
        }
        let bytes = result.results.reduce(Int64(0)) { $0 + $1.bytesReclaimed }

        // 从命中清单移除已清理项（保留未完成项）
        junkHits = junkHits.map { hit in
            RuleHit(rule: hit.rule, paths: hit.paths.filter { !cleaned.contains($0) },
                    totalBytes: hit.totalBytes, risk: hit.risk,
                    skippedProtected: hit.skippedProtected, partial: hit.partial)
        }.filter { !$0.paths.isEmpty }
        orphans.removeAll { cleaned.contains($0.path) }
        trashItems.removeAll { cleaned.contains($0.path) }
        zombies.removeAll { cleaned.contains($0.entry.plistPath) }
        selectedPaths.subtract(cleaned)
        rebuildCategories()

        cleanState = .finished(succeeded: cleaned.count, failed: failed.count, bytesReclaimed: bytes)
    }

    /// 撤销最近一次一键清理（trash 可撤销；emptyTrash / bootout 由 journal 标记不可撤销；撤销后重扫恢复清单）。
    func undoLastCleanup() async {
        guard let id = lastCleanupJournalID, cleanState != .running else { return }
        let journal = OperationJournalHolder.shared(store: DatabaseStoreHolder.shared)
        _ = await journal.undo(id)
        cleanState = .idle
        lastCleanupJournalID = nil
        await startScan()
    }
}