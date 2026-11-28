import SwiftUI
import CcCleanCore
import CcCleanFS

/// 垃圾清理 ViewModel（S3-5 只读预览；S18 开放执行通道走 OperationJournal）。
@Observable
@MainActor
final class JunkPreviewViewModel {

    private let engine: RuleEngine
    private let store: DatabaseStore

    private(set) var hits: [RuleHit] = []
    private(set) var isEvaluating = false
    private(set) var lastEvaluatedAt: Date?

    init(store: DatabaseStore = DatabaseStoreHolder.shared) {
        self.store = store
        // S3-3：内置规则加载（Shared/Resources/rules/**，全量通过校验）
        let rules = Self.loadBundledRules()
        self.engine = RuleEngine(protected: .builtin, logger: Logger(category: .scan))
        Task { [engine] in
            do {
                try await engine.load(rules)
            } catch {
                Logger(category: .scan).error("bundled rules load failed: \(String(describing: error))")
            }
        }
    }

    /// 加载内置规则文件（校验失败的文件跳过并在日志留痕）。
    private static func loadBundledRules() -> [RuleFile] {
        let rulesRoot = Paths.sharedResources.appendingPathComponent("rules", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: rulesRoot, includingPropertiesForKeys: nil
        ) else { return [] }
        var rules: [RuleFile] = []
        for case let url as URL in enumerator where url.pathExtension == "json" {
            guard url.lastPathComponent != "zombie-launchd.json",
                  let data = try? Data(contentsOf: url) else { continue }
            switch RuleValidator.validateJSON(data) {
            case .success(let pack):
                rules.append(contentsOf: pack.rules)
            case .failure(let failure):
                Logger(category: .scan).error(
                    "rule file invalid \(url.lastPathComponent): \(failure.errors.map(\.message).joined(separator: "; "))"
                )
            }
        }
        return rules
    }

    /// 只读评估：cleanup 范围全部规则（不执行任何删除）。
    func evaluateReadOnly() async {
        guard !isEvaluating else { return }
        isEvaluating = true
        defer { isEvaluating = false }
        hits = await engine.evaluate(RuleContext(scope: .cleanup, budget: .seconds(10)))
        lastEvaluatedAt = Date()
    }

    var totalReclaimable: Int64 {
        hits.reduce(0) { $0 + $1.totalBytes }
    }

    // MARK: - S18 G1 执行通道开放（勾选 → trash 可撤销；高危永不自动勾选）

    /// 勾选的规则 id 集合（按规则整体勾选）
    var selectedRuleIds: Set<String> = []
    /// 最近一次执行的 journalID（撤销用）
    private(set) var lastCleanupJournalID: UUID?
    /// 执行中标记
    private(set) var isCleaning = false
    /// 最近一次执行反馈（footer 展示）
    private(set) var lastActionMessage: String?

    /// 勾选切换（高危规则不可勾选，基线 9.4 第 4 条：高危由 Hold to confirm 承担）
    func toggleRule(_ hit: RuleHit) {
        guard hit.rule.risk != .high else { return }
        if selectedRuleIds.contains(hit.rule.id) {
            selectedRuleIds.remove(hit.rule.id)
        } else {
            selectedRuleIds.insert(hit.rule.id)
        }
    }

    /// 执行清理（走 OperationJournal trash 可撤销）。
    func executeCleanup() async -> Bool {
        let paths = hits
            .filter { selectedRuleIds.contains($0.rule.id) }
            .flatMap { $0.paths }
        guard !paths.isEmpty, !isCleaning else { return false }
        let journal = OperationJournalHolder.shared(store: store)

        isCleaning = true
        defer { isCleaning = false }

        let id = await journal.begin("专清执行（G1）")
        try? await journal.append(.trash(paths: paths), to: id)
        let result = await journal.commit(id)
        let cleaned = Set(result.results.first?.succeeded ?? [])
        lastCleanupJournalID = id

        // 从命中清单移除已清理路径（保留未完成项）
        hits = hits.map { hit in
            RuleHit(rule: hit.rule, paths: hit.paths.filter { !cleaned.contains($0) },
                    totalBytes: hit.totalBytes, risk: hit.risk,
                    skippedProtected: hit.skippedProtected, partial: hit.partial)
        }.filter { !$0.paths.isEmpty }
        selectedRuleIds.removeAll()
        return !cleaned.isEmpty
    }

    /// 撤销最近一次清理（基线 6.3 要点 4）。
    func undoLastCleanup() async {
        let journal = OperationJournalHolder.shared(store: store)
        guard let id = lastCleanupJournalID else { return }
        _ = await journal.undo(id)
        await evaluateReadOnly()
    }
}

/// 系统垃圾页（S3-5：只读预览骨架，基线 11.3 ④ 流程的 1~2 步）。
struct JunkPreviewView: View {
    @State private var model = JunkPreviewViewModel()

    var body: some View {
        VStack(spacing: 0) {
            header
            if model.isEvaluating {
                LoadingOverlay(
                    isLoading: true,
                    title: "正在评估规则命中…（只读，不执行删除）",
                    systemImage: "trash.fill",
                    accent: .scan
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.hits, id: \.rule.id) { hit in
                    ruleRow(hit)
                }
                .listStyle(.inset)
            }
            footer
        }
        .navigationTitle("系统垃圾（只读预览）")
        .task { await model.evaluateReadOnly() }
    }

    private var header: some View {
        PageHeader(
            caption: "可回收空间估算",
            title: CCleanTheme.formatBytes(model.totalReclaimable)
        ) {
            Button("重新评估") { Task { await model.evaluateReadOnly() } }
        }
    }

    /// 规则行（S18 G1：勾选框 + 可解释性 + 风险色 + 命中数；高危锁定不可勾选）。
    private func ruleRow(_ hit: RuleHit) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                // 勾选框（高危锁定）
                Button {
                    model.toggleRule(hit)
                } label: {
                    Image(systemName: ruleCheckIcon(hit))
                        .foregroundStyle(ruleCheckColor(hit))
                }
                .buttonStyle(.plain)
                .disabled(hit.rule.risk == .high)

                Circle()
                    .fill(riskColor(hit.risk))
                    .frame(width: 8, height: 8)
                Text(hit.rule.title).font(.body.weight(.medium))
                Spacer()
                Text(CCleanTheme.formatBytes(hit.totalBytes))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Text(hit.rule.explain)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Text("命中 \(hit.paths.count) 项")
                    .font(.caption2).foregroundStyle(.secondary)
                if hit.rule.risk == .high {
                    Text("高危（不可自动执行）").font(.caption2).foregroundStyle(.red)
                }
                if hit.partial {
                    Text("扫描未完成，结果可能不全").font(.caption2).foregroundStyle(.orange)
                }
                if !hit.skippedProtected.isEmpty {
                    Text("已拦截受保护路径 \(hit.skippedProtected.count) 项")
                        .font(.caption2).foregroundStyle(.green)
                }
            }
        }
        .padding(.vertical, 4)
    }

    /// 勾选图标（exact/probable ✓；possible 灰勾；high 锁定）。
    private func ruleCheckIcon(_ hit: RuleHit) -> String {
        if model.selectedRuleIds.contains(hit.rule.id) { return "checkmark.circle.fill" }
        return hit.rule.risk == .high ? "lock.circle" : "circle"
    }

    private func ruleCheckColor(_ hit: RuleHit) -> Color {
        if model.selectedRuleIds.contains(hit.rule.id) { return .accentColor }
        return hit.rule.risk == .high ? .gray : .secondary
    }

    private var footer: some View {
        HStack {
            if let last = model.lastEvaluatedAt {
                Text("评估时间 \(last.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            // S18 G1 执行/撤销（trash 可撤销；执行中禁用）
            Button("撤销") { Task { await model.undoLastCleanup() } }
                .disabled(model.lastCleanupJournalID == nil)
            Button(model.isCleaning ? "清理中…" : "清理选中") {
                Task { await model.executeCleanup() }
            }
            .disabled(model.selectedRuleIds.isEmpty || model.isCleaning)
        }
        .padding(8)
        .background(.bar)
    }

    private func riskColor(_ risk: RiskLevel) -> Color {
        switch risk {
        case .low: return .green
        case .medium: return .yellow
        case .high: return .red
        }
    }
}