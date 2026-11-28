import SwiftUI
import CcCleanCore
import CcCleanFS
import CcCleanOps
import CcCleanMetrics
import CcCleanPrivileged

/// 设置页骨架（基线 6.4 要点 6：能力总览卡——6 项，状态灯 + 一键引导，
/// 让用户在出问题前就知道缺什么）。
struct SettingsView: View {

    @Environment(CapabilityViewModel.self) private var capability

    var body: some View {
        Form {
            Section("权限能力") {
                ForEach(Capability.allCases, id: \.self) { capability in
                    CapabilityRow(capability: capability)
                }
            }
            Section("关于") {
                LabeledContent("版本", value: "0.1.0 (S0)")
                LabeledContent("数据目录", value: Paths.appSupport.path)
                if let probedAt = capability.lastProbedAt {
                    LabeledContent("上次探测", value: probedAt.formatted(date: .abbreviated, time: .standard))
                }
                Button("重新探测") {
                    Task { await capability.refresh(force: true) }
                }
            }
            Section("诊断") {
                Button("导出诊断包") {
                    Task { await exportDiagnostics() }
                }
                Text("诊断包含日志、版本与能力状态，路径已脱敏；发送前内容可见。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("设置")
        .frame(width: 520)
        .glassContainerBackground()   // CleanUp 同款：窗口容器底清空（macOS 15+）
        // CleanUp 同款玻璃窗口：隐藏 Form 系统底色，露出毛玻璃；窗口透明 + 强制暗色
        .scrollContentBackground(.hidden)
        .background(GlassWindowBackground())
        .modifier(GlassWindowSetup())
        .preferredColorScheme(.dark)
        .task { await capability.refresh() }
    }

    private func exportDiagnostics() async {
        let exporter = DiagnosticExporter()
        let context = DiagnosticContext(
            appVersion: "0.1.0",
            moduleVersions: [
                "core": CcCleanCoreInfo.version,
                "fs": CcCleanFSInfo.version,
                "ops": CcCleanOpsInfo.version,
                "metrics": CcCleanMetricsInfo.version,
                "privileged": CcCleanPrivilegedInfo.version,
            ],
            capabilityStates: Dictionary(
                uniqueKeysWithValues: Capability.allCases.map {
                    ($0.rawValue, String(describing: capability.status(for: $0)))
                }
            ),
            ruleVersion: "bundled-2026-11-26"
        )
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "cclean-diagnostics.json"
        if panel.runModal() == .OK, let url = panel.url {
            try? exporter.export(to: url, context: context, minLevel: .info)
        }
    }
}

/// 单项能力行：状态灯 + 名称 + 降级说明 + 引导按钮。
struct CapabilityRow: View {

    let capability: Capability
    @Environment(CapabilityViewModel.self) private var capabilityModel

    private var title: String {
        switch capability {
        case .fullDiskAccess: return "全盘访问"
        case .privilegedHelper: return "辅助程序（特权操作）"
        case .automation: return "自动化（Apple Events）"
        case .accessibility: return "辅助功能"
        case .notification: return "通知"
        case .networkExtension: return "网络扩展"
        }
    }

    private var lightColor: Color {
        switch capabilityModel.status(for: capability) {
        case .granted: return .green
        case .denied: return .red
        case .notDetermined: return .yellow
        case .unsupported: return .gray
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(lightColor)
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body)
                Text(capabilityModel.degradationText(for: capability))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if CapabilityGate.guideURL(for: capability) != nil {
                Button("去授权") {
                    Task { await capabilityModel.request(capability) }
                }
                .controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }
}