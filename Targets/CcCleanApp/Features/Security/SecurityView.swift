import SwiftUI
import CcCleanCore
import CcCleanFS
import CcCleanOps

/// 安全与隐私页（I 组，基线 7.7）：I1 可疑签名 / I3 TCC 总览 / I6 代理防火墙 / I7 敏感文件 / I2 隐私痕迹。
@Observable
@MainActor
final class SecurityViewModel {
    private let suite = SecuritySuite(
        appEnvironment: SystemAppEnvironment(), logger: Logger(category: .scan))
    private let scanner = AppScanner(logger: Logger(category: .scan))
    // I7：内置规则驱动（与 JunkPreview 同源）
    private let engine = RuleEngine(protected: .builtin, logger: Logger(category: .scan))

    private(set) var suspiciousApps: [SecuritySuite.SuspiciousApp] = []
    private(set) var tccEntries: [SecuritySuite.TCCEntry]?
    private(set) var networkStatus: SecuritySuite.NetworkSecurityStatus?
    private(set) var sensitiveFindings: [SecurityFinding] = []
    private(set) var privacyTargets: [SecuritySuite.PrivacyTarget] = []
    private(set) var message: String?

    var selectedPrivacy: Set<String> = []

    func loadBundledRules() async {
        do {
            try await engine.load(Self.loadBundledRules())
        } catch {
            Logger(category: .scan).error("rules load failed: \(String(describing: error))")
        }
    }

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

    func refresh() async {
        await loadBundledRules()
        var records = await scanner.scan()
        await scanner.resolveSignatures(&records)
        var sigs: [String: (teamId: String?, isAdHoc: Bool)] = [:]
        for r in records {
            sigs[r.bundlePath] = switch r.signature {
            case .adHoc: (r.teamIdentifier, true)
            case .unsigned: (r.teamIdentifier, false)
            case .developerID, .developerIDNotarized: (r.teamIdentifier, false)
            default: (nil, false)   // unknown 不判（零误报）
            }
        }
        suspiciousApps = await suite.scanSuspiciousApps(records: records, signatures: sigs)
        tccEntries = await suite.readTCCEntries()
        networkStatus = await suite.networkSecurityStatus()
        sensitiveFindings = await suite.scanSensitiveFiles(ruleEngine: engine)
        privacyTargets = await suite.previewPrivacyTargets()
    }

    /// I2：清理勾选的隐私痕迹（trash 可撤销；只清勾选类别）。
    func cleanSelectedPrivacy(store: DatabaseStore) async {
        let journal = OperationJournalHolder.shared(store: store)
        let result = await suite.cleanPrivacy(
            selectedPaths: Array(selectedPrivacy), journal: journal)
        message = "隐私清理：成功 \(result.succeeded.count) 项，失败 \(result.failed.count) 项"
        selectedPrivacy = []
        privacyTargets = await suite.previewPrivacyTargets()
    }
}

/// 安全与隐私页（I1/I2/I3/I6/I7）。
struct SecurityView: View {
    @State private var model = SecurityViewModel()

    var body: some View {
        List {
            if let message = model.message {
                Text(message).font(.footnote).foregroundStyle(.orange)
            }

            Section("代理与防火墙（I6）") {
                if let status = model.networkStatus {
                    LabeledContent("HTTP 代理",
                        value: status.httpProxyEnabled
                            ? "开启（\(status.httpProxyHost ?? "--")）" : "关闭")
                    LabeledContent("SOCKS 代理", value: status.socksProxyEnabled ? "开启" : "关闭")
                    LabeledContent("防火墙",
                        value: status.firewallEnabled.map { $0 ? "开启" : "关闭" } ?? "无法检测")
                    LabeledContent("隐身模式",
                        value: status.firewallStealth.map { $0 ? "开启" : "关闭" } ?? "无法检测")
                } else {
                    Text("网络状态检测中…").foregroundStyle(.secondary)
                }
            }

            Section("可疑签名应用（I1，零高危误报）") {
                if model.suspiciousApps.isEmpty {
                    Text("无可疑应用").foregroundStyle(.secondary)
                }
                ForEach(model.suspiciousApps, id: \.bundlePath) { app in
                    VStack(alignment: .leading) {
                        Text(app.name).font(.headline)
                        Text(app.reasons.joined(separator: "；"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            Section("TCC 权限总览（I3，只读）") {
                if let entries = model.tccEntries {
                    ForEach(entries) { entry in
                        LabeledContent(entry.service, value: entry.client)
                    }
                } else {
                    Text("TCC.db 无法读取（需全盘访问权限）").foregroundStyle(.secondary)
                }
            }

            Section("敏感文件（I7，只报路径不展示内容）") {
                if model.sensitiveFindings.isEmpty {
                    Text("未发现敏感文件").foregroundStyle(.secondary)
                }
                ForEach(model.sensitiveFindings) { finding in
                    Text(finding.path).font(.caption)
                }
            }

            Section("隐私痕迹清理（I2，只清勾选类别）") {
                ForEach(model.privacyTargets) { target in
                    HStack {
                        Toggle("", isOn: Binding(
                            get: { model.selectedPrivacy.contains(target.path) },
                            set: { on in
                                if on { model.selectedPrivacy.insert(target.path) }
                                else { model.selectedPrivacy.remove(target.path) }
                            }))
                        .labelsHidden()
                        VStack(alignment: .leading) {
                            Text(target.name).font(.headline)
                            Text("\(target.path) · \(target.itemCount) 项")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Button("清理勾选（可撤销）") {
                    Task { await model.cleanSelectedPrivacy(store: DatabaseStoreHolder.shared) }
                }
                .disabled(model.selectedPrivacy.isEmpty)
            }
        }
        .navigationTitle("隐私与安全")
        .task { await model.refresh() }
    }
}