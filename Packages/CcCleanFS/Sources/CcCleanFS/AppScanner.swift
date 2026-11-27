import Foundation
import CcCleanCore

/// 系统环境提供者协议：来源判定与签名解析所需的外部事实（可注入 Fake，基线 13.1）。
public protocol AppEnvironmentProviding: Sendable {
    /// brew list --cask 的全部 token
    func caskTokens() async -> Set<String>
    /// pkgutil --pkgs 的全部 pkgId
    func pkgIds() async -> [String]
    /// pkgutil --files 的文件清单（相对 volume 根；失败 nil）。来源判定一次枚举后内存匹配，
    /// 避免 O(apps×pkgs) 子进程调用（真实环境回归发现的性能失控点）。
    func pkgFiles(pkgId: String) async -> [String]?
    /// 该 pkgId 的文件清单是否包含指定 bundle 路径
    func pkgContains(pkgId: String, bundlePath: String) async -> Bool
    /// 是否带 quarantine 扩展属性
    func hasQuarantine(path: String) async -> Bool
    /// codesign -dv 解析 TeamIdentifier（nil = 无法解析）；adHoc = true 时为 adhoc 签名
    func codeSignature(of path: String) async -> (teamId: String?, isAdHoc: Bool)?
    /// 本机架构（arm64/x86_64）
    func machineArch() async -> String
}

/// 真实实现：全部走 ProcessRunner（唯一命令出口）。
public struct SystemAppEnvironment: AppEnvironmentProviding {

    let runner = ProcessRunner()
    let brewPath: String

    public init(brewPath: String = "/opt/homebrew/bin/brew") {
        self.brewPath = brewPath
    }

    public func caskTokens() async -> Set<String> {
        let result = try? await runner.run(.init(
            executablePath: brewPath,
            arguments: ["list", "--cask"],
            timeout: .seconds(15)
        ))
        guard let result, result.succeeded else { return [] }
        return Set(result.stdout.split(separator: "\n").map(String.init))
    }

    public func pkgIds() async -> [String] {
        let result = try? await runner.run(.init(
            executablePath: "/usr/sbin/pkgutil", arguments: ["--pkgs"], timeout: .seconds(15)
        ))
        guard let result, result.succeeded else { return [] }
        return result.stdout.split(separator: "\n").map(String.init)
    }

    public func pkgFiles(pkgId: String) async -> [String]? {
        let result = try? await runner.run(.init(
            executablePath: "/usr/sbin/pkgutil",
            arguments: ["--files", pkgId],
            timeout: .seconds(15)
        ))
        guard let result, result.succeeded else { return nil }
        return result.stdout.split(separator: "\n").map(String.init)
    }

    public func pkgContains(pkgId: String, bundlePath: String) async -> Bool {
        guard let files = await pkgFiles(pkgId: pkgId) else { return false }
        // bundlePath 以 Volume 根相对形式记录（如 Applications/X.app）
        let relative = bundlePath.hasPrefix("/")
            ? String(bundlePath.dropFirst())
            : bundlePath
        return files.contains { line in
            relative.hasPrefix(line) || line.hasPrefix(relative)
        }
    }

    public func hasQuarantine(path: String) async -> Bool {
        let result = try? await runner.run(.init(
            executablePath: "/usr/bin/xattr", arguments: ["-p", "com.apple.quarantine", path],
            timeout: .seconds(5)
        ))
        return (result?.succeeded) == true
    }

    public func codeSignature(of path: String) async -> (teamId: String?, isAdHoc: Bool)? {
        let result = try? await runner.run(.init(
            executablePath: "/usr/bin/codesign",
            arguments: ["-dv", path],
            timeout: .seconds(10)
        ))
        guard let result else { return nil }
        let lines = result.stdout.split(separator: "\n").map(String.init)
        var teamId: String?
        var adHoc = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("TeamIdentifier=") {
                let value = trimmed.dropFirst("TeamIdentifier=".count)
                teamId = (value == "not set") ? nil : String(value)
            }
            if trimmed.hasPrefix("Signature=adhoc") {
                adHoc = true
            }
            if trimmed.hasPrefix("Authority=Developer ID Application") {
                // 已公证/开发者 ID 由 TeamIdentifier 存在即可区分
            }
        }
        return (teamId, adHoc)
    }

    public func machineArch() async -> String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }
}

/// 应用扫描器（基线 7.1 AppScanner）：
/// 三根目录浅层枚举（下探覆盖嵌套 .app）+ Info.plist 解析 + 来源四级判定。
/// 元数据阶段不统计体积（体积由 SizeCache 异步增量推送，首屏 < 300ms）。
public actor AppScanner {

    /// 默认扫描根（基线 7.1 关键算法 1）。
    public static let defaultRoots = [
        "/Applications",
        "/Applications/Utilities",
        "~/Applications",
    ]

    private let environment: AppEnvironmentProviding
    private let logger: Logger

    public init(environment: AppEnvironmentProviding = SystemAppEnvironment(), logger: Logger) {
        self.environment = environment
        self.logger = logger
    }

    /// 扫描全部应用。systemRoot 用于系统应用标记（默认 /System/Applications）。
    public func scan(roots: [String]? = nil, homeDirectory: String? = nil) async -> [AppRecord] {
        let now = Date()
        let home = homeDirectory ?? FileManager.default.homeDirectoryForCurrentUser.path
        let scanRoots = (roots ?? Self.defaultRoots).map {
            ($0 as NSString).expandingTildeInPath.replacingOccurrences(of: "^~", with: home)
        }

        // 1. 枚举全部 .app 路径（浅层 + 嵌套一层覆盖 Adobe/X.app）
        var appPaths: [String] = []
        for root in scanRoots {
            appPaths.append(contentsOf: Self.enumerateApps(under: root))
        }

        // 2. 并发解析（元数据阶段）
        let records = await withTaskGroup(of: AppRecord?.self) { group in
            for path in appPaths {
                group.addTask {
                    await self.resolveApp(at: path, home: home, now: now)
                }
            }
            var collected: [AppRecord] = []
            for await record in group {
                if let record { collected.append(record) }
            }
            return collected
        }

        // 3. 来源判定需要全局事实（cask/pkg 集合）
        let enriched = await enrichSources(records, home: home)

        logger.info("scanned \(enriched.count) apps from \(scanRoots.count) roots")
        return enriched
    }

    // MARK: - 枚举

    /// 浅层枚举 .app；非 .app 目录下探一层（覆盖 Adobe/X.app、Utilities 内嵌套）。
    public static func enumerateApps(under root: String) -> [String] {
        guard FileManager.default.fileExists(atPath: root) else { return [] }
        var apps: [String] = []
        var queue: [(String, Int)] = [(root, 0)]
        let fm = FileManager.default
        while let (dir, depth) = queue.popLast() {
            guard let children = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for child in children {
                let full = dir + "/" + child
                if child.hasSuffix(".app") {
                    var isDir: ObjCBool = false
                    if fm.fileExists(atPath: full, isDirectory: &isDir), isDir.boolValue {
                        apps.append(full)
                    }
                } else if depth < 1 {
                    var isDir: ObjCBool = false
                    if fm.fileExists(atPath: full, isDirectory: &isDir), isDir.boolValue {
                        queue.append((full, depth + 1))
                    }
                }
            }
        }
        return apps
    }

    // MARK: - 单应用解析

    private func resolveApp(at path: String, home: String, now: Date) async -> AppRecord? {
        let bundle = Bundle(url: URL(fileURLWithPath: path))
        let dirName = (path as NSString).lastPathComponent
        let displayName = dirName.replacingOccurrences(of: ".app", with: "")

        guard let bundle, let info = bundle.infoDictionary else {
            // Info.plist 损坏/缺失：fallback 记录，signature unknown（基线 7.1 边界表）
            return AppRecord(
                bundleId: "path:\(abs(path.hashValue))",
                bundlePath: path,
                displayName: displayName,
                signature: .unknown,
                scannedAt: now
            )
        }

        let bundleId = (info["CFBundleIdentifier"] as? String) ?? "path:\(abs(path.hashValue))"
        let isSystem = path.hasPrefix("/System/")
        let appleOwned = bundleId.hasPrefix("com.apple.")

        return AppRecord(
            bundleId: bundleId,
            bundlePath: path,
            displayName: (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? displayName,
            bundleName: info["CFBundleName"] as? String,
            executableName: info["CFBundleExecutable"] as? String,
            shortVersion: info["CFBundleShortVersionString"] as? String,
            buildVersion: info["CFBundleVersion"] as? String,
            minimumSystem: info["LSMinimumSystemVersion"] as? String,
            installSource: isSystem ? .system : .unknown,
            signature: (isSystem || appleOwned) ? .appleSystem : .unknown,
            isProtected: isSystem,
            scannedAt: now
        )
    }

    // MARK: - 来源判定（A7 优先级：MAS → cask → pkg → 拖拽 → unknown）

    private func enrichSources(_ records: [AppRecord], home: String) async -> [AppRecord] {
        let casks = await environment.caskTokens()
        let pkgs = await environment.pkgIds()

        // ③ pkgutil 事实收集：并发拉取各 pkg 文件清单（限并发 8，每 pkg 一次子进程），
        // 之后内存匹配——真实环境回归发现逐 app×pkg 子进程调用为 O(apps×pkgs) 失控点。
        let usablePkgs = pkgs.filter { $0.hasPrefix("com.") || !$0.hasPrefix("system.") }
        var pkgAppNames: [String: Set<String>] = [:]
        await withTaskGroup(of: (String, Set<String>)?.self) { group in
            var inFlight = 0
            for pkgId in usablePkgs {
                group.addTask {
                    guard let files = await self.environment.pkgFiles(pkgId: pkgId) else {
                        return nil
                    }
                    var names = Set<String>()
                    for line in files {
                        for segment in line.split(separator: "/") where segment.hasSuffix(".app") {
                            names.insert(String(segment))
                            break
                        }
                    }
                    return names.isEmpty ? nil : (pkgId, names)
                }
                inFlight += 1
                if inFlight >= 8 {
                    if let done = await group.next(), let done {
                        pkgAppNames[done.0] = done.1
                    }
                    inFlight -= 1
                }
            }
            for await done in group {
                if let done { pkgAppNames[done.0] = done.1 }
            }
        }

        var results: [AppRecord] = []
        for var record in records {
            if record.installSource == .system || record.isProtected {
                results.append(record)
                continue
            }

            // ① MAS
            let receiptPath = record.bundlePath + "/Contents/_MASReceipt/receipt"
            if FileManager.default.fileExists(atPath: receiptPath) {
                record.installSource = .appStore
                results.append(record)
                continue
            }

            // ② Homebrew cask：token = 应用名去 .app 小写归一
            let token = ((record.bundlePath as NSString).lastPathComponent as NSString)
                .deletingPathExtension.lowercased()
            if casks.contains(token) {
                record.installSource = .homebrewCask
                results.append(record)
                continue
            }

            // ③ pkgutil：内存匹配（pkg 覆盖的 .app 名与目标应用一致）
            if pkgAppNames.values.contains(
                where: { $0.contains((record.bundlePath as NSString).lastPathComponent) }) {
                record.installSource = .pkgInstaller
                results.append(record)
                continue
            }

            // ④ 拖拽：quarantine 属性存在
            if await environment.hasQuarantine(path: record.bundlePath) {
                record.installSource = .dragAndDrop
                results.append(record)
                continue
            }

            record.installSource = .unknown
            results.append(record)
        }
        return results
    }

    /// 签名判定（独立方法：并发调用成本高，由调用方按需触发）。
    public func resolveSignatures(_ records: inout [AppRecord], concurrency: Int = 6) async {
        let arch = await environment.machineArch()
        var updates: [(Int, String?, Bool)] = []
        await withTaskGroup(of: (Int, String?, Bool).self) { group in
            var inFlight = 0
            for (idx, record) in records.enumerated() {
                if record.signature == .appleSystem { continue }
                group.addTask {
                    guard let sig = await self.environment.codeSignature(of: record.bundlePath) else {
                        return (idx, nil, false)
                    }
                    return (idx, sig.teamId, sig.isAdHoc)
                }
                inFlight += 1
                if inFlight >= concurrency {
                    // 限流：等待并收集一个结果（不可丢弃）
                    if let done = await group.next() { updates.append(done) }
                    inFlight -= 1
                }
            }
            for await up in group { updates.append(up) }
        }
        for (idx, teamId, adHoc) in updates {
            records[idx].teamIdentifier = teamId
            records[idx].architecture = arch
            if adHoc {
                records[idx].signature = .adHoc
            } else if teamId != nil {
                records[idx].signature = .developerID
            } else {
                records[idx].signature = .unsigned
            }
        }
    }
}