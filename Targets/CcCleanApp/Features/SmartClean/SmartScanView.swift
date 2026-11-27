import SwiftUI
import CcCleanCore
import CcCleanFS

/// 智能扫描页（首页主按钮目标）：一键并行扫描全部可清理类别并汇总展示，
/// 各类别可跳转对应功能页处理。全程只读，不执行删除。
struct SmartScanView: View {
    @State private var model = SmartScanViewModel()
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                switch model.phase {
                case .idle:
                    idlePrompt
                case .scanning(let step):
                    scanningCard(step: step)
                case .failed(let message):
                    failedCard(message: message)
                case .done:
                    summaryCards
                }
            }
            .padding(24)
        }
        .background(ambientBackground)
        .navigationTitle("智能扫描")
        .task {
            if case .idle = model.phase { await model.startScan() }
        }
    }

    // MARK: - 状态视图

    /// 待扫描提示。
    private var idlePrompt: some View {
        VStack(spacing: 16) {
            AccentBadge(systemImage: "sparkle.magnifyingglass", accent: .scan, size: 72)
            Text("点击下方按钮开始扫描").foregroundStyle(.secondary)
            Button("开始扫描") { Task { await model.startScan() } }
                .buttonStyle(.plain)
                .padding(.horizontal, 24)
                .frame(height: 40)
                .background(Capsule().fill(CCleanTheme.Accent.scan.gradient))
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 80)
    }

    /// 扫描进行中（步骤文本 + 进度动画）。
    private func scanningCard(step: String) -> some View {
        VStack(spacing: 16) {
            AccentBadge(systemImage: "sparkle.magnifyingglass", accent: .scan, size: 72)
                .symbolEffect(.pulse)
            Text(step).font(.system(size: 14, weight: .medium))
            ProgressView()
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity)
        .padding(40)
        .background(cardBackground)
    }

    /// 失败卡。
    private func failedCard(message: String) -> some View {
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
        .frame(maxWidth: .infinity)
        .padding(40)
        .background(cardBackground)
    }

    /// 结果汇总（总计卡 + 分类卡）。
    @ViewBuilder
    private var summaryCards: some View {
        // 总计卡（大字可释放量——CleanUp 扫描完成页视觉锚点）
        VStack(spacing: 8) {
            Text(CCleanTheme.formatBytes(model.totalBytes))
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .foregroundStyle(CCleanTheme.Accent.scan.bottom)
            Text("可释放空间")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Text("扫描用时 \(String(format: "%.1f", model.elapsed)) 秒")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(32)
        .background(cardBackground)

        // 分类卡：系统垃圾（跳系统垃圾页处理）
        categoryCard(
            accent: .scan, icon: "trash.fill",
            title: "系统垃圾",
            count: model.junkItemCount,
            bytes: model.junkBytes,
            trailing: {
                NavigationLink(value: "去清理系统垃圾") {
                    Text("去清理")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .frame(height: 30)
                        .background(Capsule().fill(CCleanTheme.Accent.scan.gradient))
                }
                .buttonStyle(.plain)
            })
        // 分类卡：孤儿文件（内嵌前 8 条路径预览）
        categoryCard(
            accent: .fileTree, icon: "folder.badge.questionmark",
            title: "孤儿文件（应用已卸载的残留）",
            count: model.orphans.count,
            bytes: model.orphanBytes,
            trailing: {})
        if !model.orphans.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(model.orphans.prefix(8)) { finding in
                    Text(finding.path)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if model.orphans.count > 8 {
                    Text("… 共 \(model.orphans.count) 项")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(cardBackground)
        }

        // 重新扫描
        Button {
            Task { await model.startScan() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.clockwise")
                Text("重新扫描")
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 22)
            .frame(height: 38)
            .background(Capsule().fill(CCleanTheme.Accent.scan.gradient))
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }

    /// 分类结果卡。
    private func categoryCard(
        accent: CCleanTheme.Accent, icon: String,
        title: String, count: Int, bytes: Int64,
        @ViewBuilder trailing: () -> some View
    ) -> some View {
        HStack(spacing: 14) {
            AccentBadge(systemImage: icon, accent: accent, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text("\(count) 项 · \(CCleanTheme.formatBytes(bytes))")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
            trailing()
        }
        .padding(16)
        .background(cardBackground)
    }

    // MARK: - 复用样式

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: CCleanTheme.cardCornerRadius, style: .continuous)
            .fill(.regularMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: CCleanTheme.cardCornerRadius, style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )
    }

    private var ambientBackground: some View {
        LinearGradient(
            colors: [Color(hex: "F5F3FF"), Color(hex: "F9FAFB")],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
        .overlay {
            Color(nsColor: .windowBackgroundColor).opacity(colorScheme == .dark ? 0.92 : 0)
        }
        .ignoresSafeArea()
    }
}

/// 智能扫描 ViewModel：规则垃圾（.cleanup 范围）+ 孤儿文件（C11）两类快速只读扫描。
@Observable
@MainActor
final class SmartScanViewModel {
    enum Phase: Equatable {
        case idle
        case scanning(step: String)
        case done
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var junkHits: [RuleHit] = []
    private(set) var orphans: [OrphanScanner.OrphanFinding] = []
    private(set) var elapsed: TimeInterval = 0

    private let engine = RuleEngine(protected: .builtin, logger: Logger(category: .scan))
    private let orphanScanner = OrphanScanner()
    private var rulesLoaded = false

    var junkItemCount: Int { junkHits.reduce(0) { $0 + $1.paths.count } }
    var junkBytes: Int64 { junkHits.reduce(0) { $0 + $1.totalBytes } }
    var orphanBytes: Int64 { orphans.reduce(0) { $0 + ($1.sizeBytes ?? 0) } }
    var totalBytes: Int64 { junkBytes + orphanBytes }

    /// 顺序扫描（垃圾 → 孤儿；孤儿扫描为同步重方法，放 detached 避免卡主线程）。
    func startScan() async {
        guard !isScanning else { return }
        isScanning = true
        let start = Date()
        defer { isScanning = false }

        do {
            phase = .scanning(step: "加载清理规则…")
            if !rulesLoaded {
                try await engine.load(Self.loadBundledRules())
                rulesLoaded = true
            }

            phase = .scanning(step: "扫描系统垃圾…")
            junkHits = await engine.evaluate(RuleContext(scope: .cleanup, budget: .seconds(10)))

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

            elapsed = Date().timeIntervalSince(start)
            phase = .done
        } catch {
            phase = .failed("扫描失败：\((error as NSError).localizedDescription)")
        }
    }

    private var isScanning = false

    /// 加载内置规则文件（与 JunkPreviewViewModel 同源模式；校验失败跳过）。
    private static func loadBundledRules() -> [RuleFile] {
        let rulesRoot = Paths.sharedResources.appendingPathComponent("rules", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: rulesRoot, includingPropertiesForKeys: nil
        ) else { return [] }
        var rules: [RuleFile] = []
        for case let url as URL in enumerator where url.pathExtension == "json" {
            guard url.lastPathComponent != "zombie-launchd.json",
                  let data = try? Data(contentsOf: url),
                  let file = try? JSONDecoder().decode(RuleFile.self, from: data) else { continue }
            rules.append(file)
        }
        return rules
    }
}