import Foundation
import CcCleanCore

/// 网络连接监控（I5，基线：nettop/lsof pid→远端映射 ≥95% 准确率；
/// lsof 进程名 8 字符截断为 lsof 固有行为，如实保留）。
/// 无权限/lsof 失败 → 空列表优雅降级。
public enum NetworkConnectionSampler {

    public struct ConnectionEntry: Sendable, Equatable {
        public let processName: String
        public let pid: Int
        public let remote: String   // host:port

        public init(processName: String, pid: Int, remote: String) {
            self.processName = processName
            self.pid = pid
            self.remote = remote
        }
    }

    /// 解析 `lsof -i -n -P` 输出（只保留 TCP ESTABLISHED 行）。
    static func parse(_ text: String) -> [ConnectionEntry] {
        var out: [ConnectionEntry] = []
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2, let pid = Int(parts[1]) else { continue }
            guard parts.contains("TCP"), line.contains("->"),
                  line.contains("(ESTABLISHED)") else { continue }
            guard let arrow = line.range(of: "->") else { continue }
            let remoteRaw = String(line[arrow.upperBound...])
            // 剥离尾部 " (ESTABLISHED)"
            guard let paren = remoteRaw.range(of: " (") else { continue }
            let remote = String(remoteRaw[..<paren.lowerBound])
            guard !remote.isEmpty else { continue }
            out.append(ConnectionEntry(
                processName: String(parts[0]), pid: pid, remote: remote))
        }
        return out
    }

    /// 实时采样（lsof -i -n -P；DNS 不解析保证速度）。
    public static func sample() async -> [ConnectionEntry] {
        let runner = ProcessRunner()
        guard let result = try? await runner.run(.init(
            executablePath: "/usr/sbin/lsof",
            arguments: ["-i", "-n", "-P"], timeout: .seconds(10)
        )), result.succeeded else { return [] }
        return parse(result.stdout)
    }
}