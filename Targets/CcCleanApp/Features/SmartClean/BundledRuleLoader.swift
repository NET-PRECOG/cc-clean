import Foundation
import CcCleanCore
import CcCleanFS

/// 内置规则加载唯一出口（SmartScan / JunkPreview 共用；校验失败的文件跳过并留痕）。
enum BundledRuleLoader {
    static func load() -> [RuleFile] {
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
}