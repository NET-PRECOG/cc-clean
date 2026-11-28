import SwiftUI
import CcCleanCore
import CcCleanFS
import CcCleanOps

/// 卸载流程 ViewModel（基线 11.3 ① 的 1~8 步）。
@Observable
@MainActor
final class UninstallPlanViewModel {

    private let store: DatabaseStore
    private var engine: UninstallEngine?
    private var journal: OperationJournal?

    private(set) var apps: [AppRecord] = []
    private(set) var plan: UninstallPlan?
    private(set) var preflight: UninstallEngine.PreflightResult?
    private(set) var report: UninstallReport?
    private(set) var isScanning = false
    private(set) var isExecuting = false

    /// 勾选项（C4 逐项勾选；默认集 = exact 勾/probable 视风险/possible 与 high 不勾）
    var selected: Set<String> = []

    init(store: DatabaseStore = DatabaseStoreHolder.shared) {
        self.store = store
        setup()
    }

    private func setup() {
        let residueScanner = ResidueScanner(
            templates: ResidueScanner.loadTemplates(
                from: Paths.sharedResources.appendingPathComponent("residue-paths.json")
            ),
            logger: Logger(category: .uninstall)
        )
        engine = UninstallEngine(
            residueScanner: residueScanner,
            receiptScanner: ReceiptScanner(logger: Logger(category: .uninstall)),
            store: store,
            logger: Logger(category: .uninstall)
        )
        journal = OperationJournalHolder.shared(store: store)
    }

    func loadApps() async {
        let repo = AppInventoryRepository(
            store: store, scanner: AppScanner(logger: Logger(category: .uninstall))
        )
        apps = await repo.loadCached().filter { !$0.isProtected }
    }

    /// 步骤 1~3：预检 + 扫描残留 + 生成计划（不写盘）。
    func buildPlan(for app: AppRecord) async {
        guard let engine, !isScanning else { return }
        isScanning = true
        defer { isScanning = false }
        report = nil
        preflight = await engine.preflight(target: app, allApps: apps)
        guard preflight?.allowed == true else {
            plan = nil
            return
        }
        plan = await engine.buildPlan(target: app, allApps: apps)
        selected = Set(plan?.defaultSelected.map(\.path) ?? [])
    }

    /// 风险汇总（底部实时更新，基线 C4）。
    var riskSummary: (total: Int, bytes: Int64, highRisk: Int, systemLevel: Int) {
        let items = (plan?.items ?? []).filter { selected.contains($0.path) }
        return plan?.riskSummary(selected: items) ?? (0, 0, 0, 0)
    }

    var containsHighRisk: Bool {
        riskSummary.highRisk > 0
    }

    var selectedItems: [ResidueItem] {
        (plan?.items ?? []).filter { selected.contains($0.path) }
    }

    /// 步骤 5~7：确认 → 执行 → 报告。
    func execute() async {
        guard let engine, let plan, let journal, !isExecuting else { return }
        isExecuting = true
        defer { isExecuting = false }
        report = await engine.execute(plan: plan, selected: selectedItems, journal: journal)
    }

    /// 步骤 8：撤销（仅用户级项，基线 7.3 算法 10）。
    func undoLast() async {
        guard let journal, let report else { return }
        _ = await journal.undo(report.planID)
        await engine?.markUndone(planID: report.planID)
    }

    func toggle(_ item: ResidueItem) {
        if selected.contains(item.path) {
            selected.remove(item.path)
        } else {
            selected.insert(item.path)
        }
    }
}

/// 卸载页（C4 计划预览：四层分组 + 置信度色条 + 风险汇总 + Hold to confirm）。
struct UninstallView: View {
    @State private var model = UninstallPlanViewModel()

    var body: some View {
        VStack(spacing: 0) {
            if let report = model.report {
                ReportView(report: report, onUndo: { Task { await model.undoLast() } })
            } else if let plan = model.plan {
                planPreview(plan)
            } else {
                appSelector
            }
        }
        .navigationTitle("卸载")
        .task { await model.loadApps() }
    }

    // MARK: - 应用选择

    private var appSelector: some View {
        VStack(spacing: 0) {
            if model.isScanning {
                LoadingOverlay(
                    isLoading: true,
                    title: "正在扫描应用与残留…（已发现项实时统计）",
                    systemImage: "trash.fill",
                    accent: .app
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.apps, id: \.bundleId) { app in
                    Button {
                        Task { await model.buildPlan(for: app) }
                    } label: {
                        HStack {
                            Text(app.displayName).fontWeight(.medium)
                            Spacer()
                            Text(app.shortVersion ?? "—").foregroundStyle(.secondary)
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    // MARK: - 计划预览（C4）

    private func planPreview(_ plan: UninstallPlan) -> some View {
        VStack(spacing: 0) {
            List {
                ForEach([ResidueLayer.l1Body, .l2User, .l4State, .l3System], id: \.self) { layer in
                    let items = plan.items.filter { $0.layer == layer }
                    if !items.isEmpty {
                        Section(layerTitle(layer)) {
                            ForEach(items) { item in
                                residueRow(item)
                            }
                        }
                    }
                }
                if !plan.skippedConflicts.isEmpty {
                    Section("C12 同厂剔除（透明展示）") {
                        ForEach(plan.skippedConflicts, id: \.path) { conflict in
                            VStack(alignment: .leading) {
                                Text(conflict.path).font(.caption).lineLimit(1)
                                Text("属于 \(conflict.owner)，已从计划剔除")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .listStyle(.inset)
            bottomBar
        }
    }

    private func residueRow(_ item: ResidueItem) -> some View {
        Button { model.toggle(item) } label: {
            HStack(spacing: 10) {
                Image(systemName: model.selected.contains(item.path) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(model.selected.contains(item.path) ? Color.accentColor : Color.secondary)
                // 置信度色条（绿=exact 黄=probable 灰=possible）
                RoundedRectangle(cornerRadius: 2)
                    .fill(confidenceColor(item.confidence))
                    .frame(width: 4, height: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.path)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                    Text(item.reason).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                if item.risk == .high {
                    Text("高危").font(.caption2).padding(3)
                        .background(.red.opacity(0.15), in: Capsule())
                        .frame(minWidth: 44)
                }
                if !item.undoable {
                    Text("不可撤销").font(.caption2).foregroundStyle(.red)
                }
                Text(CCleanTheme.formatBytes(item.bytes))
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
    }

    /// 底部风险汇总（与勾选项实时一致）+ Hold to confirm。
    private var bottomBar: some View {
        HStack(spacing: 16) {
            let summary = model.riskSummary
            Text("已选 \(summary.total) 项 · \(CCleanTheme.formatBytes(summary.bytes))")
            if summary.highRisk > 0 {
                Text("⚠ 高危 \(summary.highRisk) 项").foregroundStyle(.red).font(.caption)
            }
            if summary.systemLevel > 0 {
                Text("系统级 \(summary.systemLevel) 项（不可撤销）").foregroundStyle(.red).font(.caption)
            }
            Spacer()
            HoldToConfirmButton(
                label: model.containsHighRisk ? "我已了解不可恢复，继续卸载" : "继续",
                disabled: model.selectedItems.isEmpty || model.isExecuting
            ) {
                Task { await model.execute() }
            }
        }
        .padding(12)
        .background(.bar)
    }

    private func layerTitle(_ layer: ResidueLayer) -> String {
        switch layer {
        case .l1Body: return "应用本体（可撤销）"
        case .l2User: return "用户级残留（可撤销）"
        case .l3System: return "系统级残留（需辅助程序，不可撤销）"
        case .l4State: return "关联状态（launchd 等）"
        }
    }

    private func confidenceColor(_ confidence: ResidueConfidence) -> Color {
        switch confidence {
        case .exact: return .green
        case .probable: return .yellow
        case .possible: return .gray
        }
    }
}

/// 高危确认按钮（基线 10.4：Hold to confirm 1.5s，高危项强制；普通项单击确认）。
struct HoldToConfirmButton: View {
    let label: String
    let disabled: Bool
    let action: () -> Void

    @State private var progress: CGFloat = 0
    @State private var holding = false

    var body: some View {
        if holding {
            progressView
        } else {
            Button {
                if !disabled { holding = true; animateHold() }
            } label: {
                Text(label)
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red)
            .disabled(disabled)
        }
    }

    /// Hold to confirm（1.5s，基线 10.4 二次确认规格）。
    private var progressView: some View {
        Button {} label: {
            Text("按住确认…")
                .padding(.horizontal, 14).padding(.vertical, 6)
                .background(
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 8).fill(.red.opacity(0.15))
                            RoundedRectangle(cornerRadius: 8)
                                .fill(.red.opacity(0.55))
                                .frame(width: geo.size.width * progress)
                        }
                    }
                )
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .onLongPressGesture(minimumDuration: 1.5) {
            holding = false
            progress = 0
            action()
        } onPressingChanged: { pressing in
            if !pressing && progress < 1 {
                holding = false
                progress = 0
            }
        }
    }

    private func animateHold() {
        // 长按由 onLongPressGesture(minimumDuration: 1.5) 承担；此处仅进入按住态
        progress = 0.15
    }
}

/// 报告页（基线 11.3 ① 第 7~8 步：结果卡片 + 复检状态灯 + 撤销 + 导出）。
struct ReportView: View {
    let report: UninstallReport
    let onUndo: () -> Void

    @State private var exportText: String?

    var body: some View {
        VStack(spacing: 0) {
            List {
                Section("结果") {
                    LabeledContent("成功", value: "\(report.journalResult.succeededCount)")
                    LabeledContent("失败", value: "\(report.journalResult.failedCount)")
                    LabeledContent("模式", value: report.wasDryRun ? "演练" : "执行")
                }
                Section("四项复检") {
                    checkRow("进程清零", report.verification.processesCleared)
                    checkRow("launchd 无条目", report.verification.launchdCleared)
                    checkRow("路径已清除", report.verification.pathsCleared)
                    checkRow("凭据为空", report.verification.credentialsCleared)
                    Text(report.verification.allPassed ? "结论：已清理" : "结论：存在遗留项")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(report.verification.allPassed ? .green : .orange)
                }
                Section {
                    Button("撤销（仅用户级项）") { onUndo() }
                        .disabled(!report.journalResult.undoable)
                    Button("导出 Markdown 报告") { exportMarkdown() }
                }
            }
            .listStyle(.inset)
            if let exportText {
                ScrollView {
                    Text(exportText)
                        .font(.system(.caption2, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(maxHeight: 180)
            }
        }
        .navigationTitle("卸载报告")
    }

    private func checkRow(_ label: String, _ ok: Bool) -> some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(ok ? .green : .red)
            Text(label)
        }
    }

    private func exportMarkdown() {
        let md = report.exportMarkdown()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("uninstall-\(report.planID.uuidString.prefix(8)).md")
        try? report.exportMarkdown().data(using: .utf8)!.write(to: url, options: .atomic)
        exportText = "已导出：\(url.path)\n\n\(md)"
    }
}