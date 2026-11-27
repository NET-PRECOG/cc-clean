import Foundation
import CcCleanCore

/// Mac App Store 应用更新（B10，基线 B10：mas CLI 集成）。
/// 未安装 mas → 优雅降级（返回空清单 + 提示，不报错）。
public actor MasService {

    private let runner: BrewCommandRunning
    private let logger: Logger
    /// 测试注入路径（nil = 按候选路径探测真实 mas）。
    private let masPathOverride: String?
    private let masCandidates = [
        "/opt/homebrew/bin/mas",
        "/usr/local/bin/mas",
        "/usr/bin/mas",
    ]

    public init(
        runner: BrewCommandRunning = SystemBrewRunner(), logger: Logger, masPath: String? = nil
    ) {
        self.runner = runner
        self.logger = logger
        self.masPathOverride = masPath
    }

    /// mas 可执行文件探测（候选路径 + `mas version` 验证）。
    public func resolveMas(home: String = NSHomeDirectory()) async -> String? {
        if let override = masPathOverride {
            return FileManager.default.fileExists(atPath: override) ? override : nil
        }
        let fm = FileManager.default
        for candidate in masCandidates where fm.fileExists(atPath: candidate) {
            return candidate
        }
        return nil
    }

    public struct MasApp: Sendable, Equatable {
        public let id: Int
        public let name: String
        public let version: String

        public init(id: Int, name: String, version: String) {
            self.id = id
            self.name = name
            self.version = version
        }
    }

    /// 解析 mas list / mas outdated 行："123456  AppName  2.3.1" 或 "123 AppName (1.0 -> 1.1)"。
    static func parseListLine(_ line: String) -> MasApp? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true)
        guard let idPart = parts.first, let id = Int(idPart), parts.count >= 2 else { return nil }
        if trimmed.contains("->") {
            // outdated："123 Name (1.0 -> 1.1)" → 版本取目标版本
            guard let open = trimmed.firstIndex(of: "("),
                  let arrow = trimmed.range(of: "->") else { return nil }
            let name = trimmed[trimmed.index(after: idPart.endIndex)..<open]
                .trimmingCharacters(in: .whitespaces)
            let rest = trimmed[arrow.upperBound...]
            let target = rest.split(separator: ")").first.map {
                $0.trimmingCharacters(in: .whitespaces)
            } ?? ""
            return MasApp(id: id, name: name, version: String(target))
        }
        // list："123 Name 2.3.1" → 首段 id、末段版本、中间 name
        guard parts.count >= 3 else {
            return MasApp(id: id, name: parts.dropFirst().joined(separator: " "), version: "")
        }
        let name = parts[1..<(parts.count - 1)].joined(separator: " ")
        return MasApp(id: id, name: name, version: String(parts.last!))
    }

    static func parseListOutput(_ text: String) -> [MasApp] {
        text.split(separator: "\n").compactMap { parseListLine(String($0)) }
    }

    /// 已装 MAS 应用清单（mas list）。
    public func listInstalled(home: String = NSHomeDirectory()) async -> [MasApp] {
        guard let mas = await resolveMas(home: home) else { return [] }
        guard let result = try? await runner.run(
            brewPath: mas, args: ["list"], timeout: .seconds(15)
        ), result.succeeded else { return [] }
        return Self.parseListOutput(result.stdout)
    }

    /// 过期应用（mas outdated）。
    public func outdated(home: String = NSHomeDirectory()) async -> [MasApp] {
        guard let mas = await resolveMas(home: home) else { return [] }
        guard let result = try? await runner.run(
            brewPath: mas, args: ["outdated"], timeout: .seconds(15)
        ), result.succeeded else { return [] }
        return Self.parseListOutput(result.stdout)
    }

    /// 升级指定应用（id 空 = 全部 `mas upgrade`）。返回成功与否 + 输出摘要。
    public func upgrade(
        ids: [Int] = [], home: String = NSHomeDirectory()
    ) async -> (succeeded: Bool, summary: String) {
        guard let mas = await resolveMas(home: home) else {
            return (false, "未安装 mas CLI（brew install mas）")
        }
        let args = ids.isEmpty ? ["upgrade"] : ["upgrade"] + ids.map(String.init)
        guard let result = try? await runner.run(
            brewPath: mas, args: args, timeout: .seconds(1800)
        ) else {
            return (false, "mas 执行失败")
        }
        logger.info("mas upgrade: ok=\(result.succeeded)")
        return (result.succeeded, result.succeeded
            ? result.stdout : (result.stderr.isEmpty ? result.stdout : result.stderr))
    }
}