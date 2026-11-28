import SwiftUI
import AppKit
import CcCleanCore
import CcCleanFS

/// 一键清理页（CleanUp 同款布局）：左侧分类侧栏 + 右侧文件清单逐条罗列勾选 +
/// 底部圆形清理按钮；扫描中 / 失败以覆盖层呈现，无三级页面。
/// 路径级勾选与一键清理共用 SmartScanViewModel（OperationJournal trash 通道，可撤销）。
struct SmartScanView: View {
    @State private var model = SmartScanViewModel()
    @State private var selectedCategoryID: String?
    /// 侧栏分类排序与主区文件排序相互独立。
    @State private var categorySortDescending = true
    @State private var fileSortDescending = true

    private var category: ReviewCategory? {
        model.categories.first { $0.id == selectedCategoryID } ?? model.categories.first
    }

    /// 侧栏分类按大小排序（独立于文件排序）。
    private var sortedCategories: [ReviewCategory] {
        categorySortDescending
            ? model.categories.sorted { $0.bytes > $1.bytes }
            : model.categories.sorted { $0.bytes < $1.bytes }
    }

    /// 当前分类文件按大小排序。
    private var sortedItems: [ReviewItem] {
        guard let category else { return [] }
        return fileSortDescending
            ? category.items.sorted { ($0.size ?? -1) > ($1.size ?? -1) }
            : category.items.sorted { ($0.size ?? -1) < ($1.size ?? -1) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                sidebar
                Divider().overlay(Color.white.opacity(0.10))
                content
            }
            bottomBar
        }
        .background(AmbientBackground())
        .navigationTitle("一键清理")
        .overlay { stateOverlay }
        .task {
            // 每次进入页面都重新扫描（CleanUp 智能扫描同逻辑）
            await model.startScan()
        }
    }

    // MARK: - 覆盖层（idle / 扫描中 / 失败）

    @ViewBuilder
    private var stateOverlay: some View {
        switch model.phase {
        case .idle, .scanning:
            ZStack {
                Color(nsColor: .windowBackgroundColor).opacity(0.85).ignoresSafeArea()
                LoadingOverlay(
                    isLoading: true,
                    title: model.phase == .idle ? "准备扫描…" : "正在扫描",
                    systemImage: "sparkle.magnifyingglass",
                    accent: .scan
                )
            }
        case .failed(let message):
            failedOverlay(message: message)
        case .done:
            EmptyView()
        }
    }

    /// 失败覆盖卡（重新扫描入口）。
    private func failedOverlay(message: String) -> some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor).opacity(0.9).ignoresSafeArea()
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(.yellow)
                Text(message).foregroundStyle(.secondary)
                Button("重新扫描") { Task { await model.startScan() } }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 20)
                    .frame(height: 36)
                    .background(Capsule().fill(CCleanTheme.Accent.scan.gradient))
                    .foregroundStyle(.white)
            }
            .padding(40)
            .background(GlassCardBackground())
        }
    }

    // MARK: - 侧栏（分类列表）

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    model.toggleAllSelection()
                } label: {
                    Text(model.allSelected ? "取消全选" : "全选")
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .background(Capsule().stroke(Color.white.opacity(0.25), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(model.categories.isEmpty)

                Spacer()
                categorySortMenu
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            ScrollView {
                VStack(spacing: 2) {
                    ForEach(sortedCategories) { cat in
                        sidebarRow(cat)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
            }
        }
        .frame(width: 230)
    }

    /// 侧栏排序控件（分类按大小 升/降序，独立于文件排序）。
    private var categorySortMenu: some View {
        Menu {
            Button("从大到小") { categorySortDescending = true }
            Button("从小到大") { categorySortDescending = false }
        } label: {
            Label(categorySortDescending ? "从大到小" : "从小到大",
                  systemImage: "arrow.up.arrow.down")
                .font(.system(size: 11))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    /// 主区排序控件（文件按大小 升/降序，独立于分类排序）。
    private var fileSortMenu: some View {
        Menu {
            Button("从大到小") { fileSortDescending = true }
            Button("从小到大") { fileSortDescending = false }
        } label: {
            Label(fileSortDescending ? "从大到小" : "从小到大",
                  systemImage: "arrow.up.arrow.down")
                .font(.system(size: 11))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    /// 分类徽章配色（按展示分组语义区分）。
    private func accent(for cat: ReviewCategory) -> CCleanTheme.Accent {
        switch cat.id {
        case ReviewCategory.residueID: .fileTree
        case "userLogs": .largeFile
        case "crashReports": .privacy
        case "diskImages": .disk
        case "xcode": .devTools
        case "sysCache": .app
        case "downloads": .duplicate
        case "trash": .inventory
        case "brokenLogins": .loginItem
        case "mail": .loginItem
        case "iosBackup": .app
        case "sysTmp": .devTools
        default: .scan
        }
    }

    /// 侧栏分类行：勾选圈（独立切换）+ 分类卡（点击查看文件清单）；锁定分类显示锁图标。
    private func sidebarRow(_ cat: ReviewCategory) -> some View {
        let selected = cat.id == category?.id
        let checked = model.categoryFullySelected(cat.id)
        return HStack(spacing: 10) {
            if cat.locked {
                Image(systemName: "lock.circle")
                    .font(.system(size: 14))
                    .foregroundStyle(.tertiary)
            } else {
                Button {
                    model.toggleCategory(cat.id)
                } label: {
                    Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 14))
                        .foregroundStyle(checked ? Color.green : Color.secondary)
                }
                .buttonStyle(.plain)
            }
            Button {
                selectedCategoryID = cat.id
            } label: {
                HStack(spacing: 10) {
                    AccentBadge(systemImage: cat.icon, accent: accent(for: cat), size: 24)
                    Text(cat.title)
                        .font(.system(size: 13))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer()
                    Text(CCleanTheme.formatBytes(cat.bytes))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(selected ? Color.white.opacity(0.10) : Color.clear)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - 主区（文件清单）

    @ViewBuilder
    private var content: some View {
        if let category {
            VStack(spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(category.title)
                            .font(.system(size: 18, weight: .bold))
                        Text(category.subtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    fileSortMenu
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 10)

                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(sortedItems) { item in
                            fileRow(item, locked: category.locked)
                        }
                        if sortedItems.isEmpty {
                            Text(category.locked ? "该分类下无可自动清理项" : "该分类下暂无可清理项")
                                .font(.system(size: 12))
                                .foregroundStyle(.tertiary)
                                .padding(.top, 40)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)
                }
            }
            .frame(maxWidth: .infinity)
            .id(category.id)
        } else {
            ContentUnavailableView {
                Label("空间很干净", systemImage: "checkmark.seal.fill")
            } description: {
                Text("未发现可清理的垃圾文件")
            } actions: {
                Button("重新扫描") { Task { await model.startScan() } }
                    .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }


    /// 文件行：勾选圈 + 文件图标 + 文件名/路径 + 大小右对齐（整行可点切换）；
    /// 锁定分类（高危/需辅助程序）显示锁图标且不可勾选。
    private func fileRow(_ item: ReviewItem, locked: Bool) -> some View {
        let checked = model.selectedPaths.contains(item.path)
        return HStack(spacing: 10) {
            if locked {
                Image(systemName: "lock.circle")
                    .font(.system(size: 15))
                    .foregroundStyle(.tertiary)
            } else {
                Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(checked ? Color.green : Color.secondary)
            }
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.path))
                .resizable()
                .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text((item.path as NSString).lastPathComponent)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(item.detail ?? (item.path as NSString).deletingLastPathComponent)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Text(item.size.map { CCleanTheme.formatBytes($0) } ?? "—")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(checked ? Color.white.opacity(0.05) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { model.togglePath(item.path) }
    }

    // MARK: - 底部操作栏

    private var bottomBar: some View {
        ZStack {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("共发现")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text(CCleanTheme.formatBytes(model.totalBytes))
                        .font(.system(size: 15, weight: .semibold))
                        .monospacedDigit()
                }
                Spacer()
                if case .finished(let succeeded, let failed, let bytes) = model.cleanState {
                    HStack(spacing: 8) {
                        Image(systemName: failed > 0
                              ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                            .foregroundStyle(failed > 0 ? Color.orange : Color.green)
                        Text(failed > 0
                             ? "已清理 \(succeeded) 项 · 失败 \(failed) 项"
                             : "已清理 \(succeeded) 项 · 释放 \(CCleanTheme.formatBytes(bytes))")
                            .font(.system(size: 12, weight: .medium))
                        Button("撤销") { Task { await model.undoLastCleanup() } }
                            .buttonStyle(.plain)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(CCleanTheme.Accent.scan.bottom)
                    }
                }
            }

            HStack(spacing: 8) {
                cleanButton
                if case .finished = model.cleanState {
                    EmptyView()
                } else {
                    Text(CCleanTheme.formatBytes(model.selectedBytes))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }

    /// 圆形清理主按钮（CleanUp 同款）。
    private var cleanButton: some View {
        let running = model.cleanState == .running
        return Button {
            Task { await model.cleanSelected() }
        } label: {
            VStack(spacing: 2) {
                if running {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                } else {
                    Image(systemName: "sparkles")
                        .font(.system(size: 17, weight: .semibold))
                }
                Text(running ? "清理中" : "清理")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(.white)
            .frame(width: 56, height: 56)
            .background(
                Circle().fill(
                    running || !model.canClean
                        ? AnyShapeStyle(Color.gray.opacity(0.4))
                        : AnyShapeStyle(CCleanTheme.Accent.scan.gradient)
                )
            )
            .shadow(color: CCleanTheme.Accent.scan.bottom.opacity(0.35), radius: 10, y: 3)
        }
        .buttonStyle(.plain)
        .disabled(!model.canClean || running)
    }
}