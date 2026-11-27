import Foundation
import CcCleanCore

/// 安装时间四级回退解析（基线 7.1 关键算法 4）：
/// ① pkgutil install-time（exact=3）→ ② mdls kMDItemDateAdded（spotlight=2）
/// → ③ stat btime of Info.plist（fileSystem=1）→ ④ bundle 目录创建时间（fileSystem=1）
/// 全部失败 → unknown=0，UI 显示「未知」不伪造。
public actor InstallTimeResolver {

    public enum Confidence: Int, Sendable {
        case unknown = 0
        case fileSystem = 1
        case spotlight = 2
        case exact = 3
    }

    public struct Result: Sendable, Equatable {
        public let date: Date?
        public let confidence: Confidence
    }

    let runner: ProcessRunner

    public init(runner: ProcessRunner = ProcessRunner()) {
        self.runner = runner
    }

    /// 解析安装时间。
    public func resolve(bundlePath: String, pkgIds: [String]? = nil) async -> Result {
        // ① pkgutil --pkg-info-plist <pkgid> 的 install-time（需要先找到匹配 pkgId）
        let candidates = pkgIds ?? Self.defaultPkgIds()
        for pkgId in candidates {
            if let date = await installTimeFromPkgutil(pkgId: pkgId) {
                return Result(date: date, confidence: .exact)
            }
        }

        // ② mdls kMDItemDateAdded
        if let date = await installTimeFromSpotlight(bundlePath: bundlePath) {
            return Result(date: date, confidence: .spotlight)
        }

        // ③ Info.plist 的 birthtime
        let plistPath = bundlePath + "/Contents/Info.plist"
        if let birth = Self.birthtime(of: plistPath) {
            return Result(date: birth, confidence: .fileSystem)
        }

        // ④ bundle 目录创建时间
        if let birth = Self.birthtime(of: bundlePath) {
            return Result(date: birth, confidence: .fileSystem)
        }

        return Result(date: nil, confidence: .unknown)
    }

    /// 默认 pkgIds：由调用方传入避免全量枚举成本；骨架提供空实现。
    static func defaultPkgIds() -> [String] { [] }

    /// pkgutil --pkg-info-plist <pkgid> → install-time（Unix 秒）。
    func installTimeFromPkgutil(pkgId: String) async -> Date? {
        let result = try? await runner.run(.init(
            executablePath: "/usr/sbin/pkgutil",
            arguments: ["--pkg-info-plist", pkgId],
            timeout: .seconds(10)
        ))
        guard let result, result.succeeded, let data = result.stdout.data(using: .utf8) else {
            return nil
        }
        guard let plist = try? PropertyListSerialization.propertyList(
            from: data, options: [], format: nil
        ) as? [String: Any] else {
            return nil
        }
        guard let seconds = plist["install-time"] as? TimeInterval else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// mdls -name kMDItemDateAdded <path>。
    func installTimeFromSpotlight(bundlePath: String) async -> Date? {
        let result = try? await runner.run(.init(
            executablePath: "/usr/bin/mdls",
            arguments: ["-name", "kMDItemDateAdded", "-raw", bundlePath],
            timeout: .seconds(10)
        ))
        guard let result, result.succeeded else { return nil }
        let output = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty, output != "(null)" else { return nil }
        // mdls -raw 输出 ISO8601：2024-01-02 03:04:05 +0000
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss ZZZ"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.date(from: output)
    }

    /// birthtime（stat st_birthtimespec）。
    static func birthtime(of path: String) -> Date? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        let seconds = TimeInterval(st.st_birthtimespec.tv_sec)
        let nanos = TimeInterval(st.st_birthtimespec.tv_nsec) / 1_000_000_000
        guard seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds + nanos)
    }
}