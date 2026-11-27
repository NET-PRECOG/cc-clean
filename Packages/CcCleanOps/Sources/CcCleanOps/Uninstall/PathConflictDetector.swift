import Foundation
import CcCleanCore

/// PATH 冲突检测结果（M7，基线 7.5 关键算法 6）。
public struct PATHConflict: Sendable, Equatable {
    public enum Kind: String, Sendable {
        case duplicate      // 同目录重复出现
        case shadowed       // 被后续同名可执行覆盖（顺序冲突）
        case missing        // 目录不存在
    }

    public let kind: Kind
    public let directory: String
    /// 发现来源（profile 文件或 /etc/paths）
    public let source: String
    /// 被谁覆盖（shadowed 时）
    public let shadowedBy: String?
}

/// 单个 profile 的 PATH 导出项。
public struct PATHExport: Sendable, Equatable {
    public let source: String          // 文件路径
    public let directories: [String]   // 导出的目录（按声明顺序）
}

/// PATH/环境变量冲突检测器（M7，基线 7.5 关键算法 5）：
/// 解析 zsh/bash profile 链 + /etc/paths + /etc/paths.d，
/// 检测重复/失效/被覆盖三类冲突，`zsh -lic` 校验生效顺序（用户级命令）。
public struct PathConflictDetector: Sendable {

    /// zsh 的 profile 链（加载顺序）。
    public static let zshProfiles = [
        "/etc/zshenv",
        "~/.zshenv",
        "/etc/zprofile",
        "~/.zprofile",
        "/etc/zshrc",
        "~/.zshrc",
    ]

    public init() {}

    // MARK: - profile 解析

    /// 解析全部 profile 的 PATH 导出项（顺序即生效优先级参考）。
    public func parseProfiles(home: String, runner: BrewCommandRunning = SystemBrewRunner()) async -> [PATHExport] {
        var exports: [PATHExport] = []
        let fm = FileManager.default

        // /etc/paths + /etc/paths.d（path_helper）
        let etcPaths = NSHomeDirectory() == "" ? nil : "/etc/paths"
        if let content = fm.contents(atPath: etcPaths ?? "") {
            let dirs = String(data: content, encoding: .utf8)?
                .components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty } ?? []
            if !dirs.isEmpty {
                exports.append(PATHExport(source: "/etc/paths", directories: dirs))
            }
        }
        let pathsD = "/etc/paths.d"
        if let children = try? fm.contentsOfDirectory(atPath: pathsD).sorted() {
            for child in children {
                if let content = fm.contents(atPath: pathsD + "/" + child) {
                    let dirs = String(data: content, encoding: .utf8)?
                        .components(separatedBy: "\n")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty } ?? []
                    if !dirs.isEmpty {
                        exports.append(PATHExport(source: "/etc/paths.d/" + child, directories: dirs))
                    }
                }
            }
        }

        // zsh/bash profile 链（~ 展开到指定 home，支持 fixture 注入）
        let profiles = Self.zshProfiles.map {
            $0.hasPrefix("~") ? home + $0.dropFirst() : $0
        } + [
            home + "/.bash_profile",
            home + "/.bashrc",
        ]
        for profile in profiles {
            guard let content = fm.contents(atPath: profile),
                  let text = String(data: content, encoding: .utf8) else { continue }
            let dirs = Self.extractPATHDirectories(text: text, home: home)
            if !dirs.isEmpty {
                exports.append(PATHExport(source: profile, directories: dirs))
            }
        }
        return exports
    }

    /// 从 profile 文本提取 export PATH=... 中的目录（含 $HOME 展开）。
    static func extractPATHDirectories(text: String, home: String = NSHomeDirectory()) -> [String] {
        var directories: [String] = []
        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            // 匹配 export PATH=... 或 PATH=...: 形式（跳过注释）
            guard line.hasPrefix("export") || line.hasPrefix("PATH="), !line.hasPrefix("#") else { continue }
            guard let eqRange = line.range(of: "PATH=") else { continue }
            let value = String(line[eqRange.upperBound...])
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            // 展开变量：$HOME / ~
            let expanded = value
                .replacingOccurrences(of: "$HOME", with: home)
                .replacingOccurrences(of: "~", with: home)
                .replacingOccurrences(of: "$JAVA_HOME/bin:", with: "")
            for dir in expanded.components(separatedBy: ":") {
                let trimmed = dir.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty, trimmed != "$PATH", trimmed != "${PATH}", trimmed != "$path" {
                    directories.append(trimmed)
                }
            }
        }
        return directories
    }

    // MARK: - 冲突检测

    /// 三类冲突检测（按生效顺序合并后分析）。
    public func detect(exports: [PATHExport]) -> [PATHConflict] {
        var conflicts: [PATHConflict] = []
        var seenDirectories: [String: String] = [:]   // 目录 → 首次来源（生效优先）
        var executables: [String: String] = [:]       // 可执行名 → 首次所在目录

        // 按声明顺序遍历（path_helper 的 /etc/paths 在前 = 低优先级前插，
        // 用户 profile 的 export PATH="x:$PATH" 是高优先级前插——按出现顺序近似）
        for export in exports.reversed() {
            for directory in export.directories {
                // ① 失效目录
                if !FileManager.default.fileExists(atPath: directory) {
                    conflicts.append(PATHConflict(
                        kind: .missing, directory: directory,
                        source: export.source, shadowedBy: nil))
                    continue
                }
                // ② 重复
                if let firstSource = seenDirectories[directory] {
                    conflicts.append(PATHConflict(
                        kind: .duplicate, directory: directory,
                        source: export.source, shadowedBy: firstSource))
                    continue
                }
                seenDirectories[directory] = export.source

                // ③ shadowed：目录中存在与其他目录同名可执行，且本目录优先级更低
                let executablesInDir = ((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? [])
                    .filter { !$0.hasPrefix(".") }
                for exec in executablesInDir {
                    if let owner = executables[exec], owner != directory {
                        conflicts.append(PATHConflict(
                            kind: .shadowed, directory: directory,
                            source: export.source, shadowedBy: owner))
                        break   // 每目录报一条
                    }
                }
                for exec in executablesInDir where executables[exec] == nil {
                    executables[exec] = directory
                }
            }
        }
        return conflicts
    }

    /// `zsh -lic 'echo $PATH'` 校验实际生效顺序（用户级命令；解析失败返回 nil）。
    public func verifyEffectiveOrder(runner: BrewCommandRunning) async -> [String]? {
        let result = try? await runner.run(
            brewPath: "/bin/zsh",
            args: ["-lic", "echo $PATH"],
            timeout: .seconds(15)
        )
        guard let result, result.succeeded else { return nil }
        return result.stdout
            .components(separatedBy: ":")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}