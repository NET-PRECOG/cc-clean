import Foundation
import CcCleanCore

/// 分应用网络流量（E5，基线 E 组：nettop 快照 + 差分速率）。
/// nettop -L 1 输出为 CSV（实测：time,进程.pid,,state,bytes_in,bytes_out,...）。
/// nettop 失败 → nil 优雅降级（UI 显示「无法采样」而非伪造）。
public final class PerAppTrafficSampler: @unchecked Sendable {

    private let lock = NSLock()
    private var last: [String: (in: Int64, out: Int64)]?
    private var lastAt: Date?

    public struct AppTraffic: Sendable, Equatable {
        public let process: String    // "name.pid"
        public let bytesIn: Int64     // 累计
        public let bytesOut: Int64
        public let inRate: Double     // B/s（两次采样差分）
        public let outRate: Double
    }

    public init() {}

    /// 解析 nettop -P -n -L 1 CSV（跳过表头；bytes 列非法行跳过）。
    static func parseNettop(
        _ text: String
    ) -> [(process: String, bytesIn: Int64, bytesOut: Int64)] {
        var out: [(process: String, bytesIn: Int64, bytesOut: Int64)] = []
        for line in text.split(separator: "\n") {
            let cols = line.split(separator: ",", omittingEmptySubsequences: false)
            guard cols.count >= 6, !cols[0].hasPrefix("time") else { continue }
            let process = String(cols[1])
            guard !process.isEmpty, process.contains("."),
                  let bytesIn = Int64(cols[4]), let bytesOut = Int64(cols[5]) else { continue }
            out.append((process, bytesIn, bytesOut))
        }
        return out
    }

    /// 差分（首采样速率 0；时间回退/过近 → 速率 0 不伪造）。
    static func differ(
        _ rows: [(process: String, bytesIn: Int64, bytesOut: Int64)],
        previous: [String: (in: Int64, out: Int64)]?, previousAt: Date?, at: Date
    ) -> [AppTraffic] {
        rows.map { row in
            var inRate: Double = 0, outRate: Double = 0
            if let previous, let previousAt,
               let prev = previous[row.process] {
                let elapsed = at.timeIntervalSince(previousAt)
                if elapsed > 0.1 {
                    inRate = Double(max(row.bytesIn - prev.in, 0)) / elapsed
                    outRate = Double(max(row.bytesOut - prev.out, 0)) / elapsed
                }
            }
            return AppTraffic(
                process: row.process, bytesIn: row.bytesIn, bytesOut: row.bytesOut,
                inRate: inRate, outRate: outRate)
        }
        .sorted { ($0.inRate + $0.outRate) > ($1.inRate + $1.outRate) }
    }

    /// 采样（nettop；失败 → nil）。
    public func sample() async -> [AppTraffic]? {
        let runner = ProcessRunner()
        guard let result = try? await runner.run(.init(
            executablePath: "/usr/bin/nettop",
            arguments: ["-P", "-n", "-L", "1"], timeout: .seconds(20)
        )), result.succeeded else { return nil }
        // 同步方法内持锁（async 上下文禁 NSLock，Swift 6）
        return updateState(rows: Self.parseNettop(result.stdout))
    }

    private func updateState(
        rows: [(process: String, bytesIn: Int64, bytesOut: Int64)]
    ) -> [AppTraffic] {
        lock.lock(); defer { lock.unlock() }
        let previous = last
        let previousAt = lastAt
        let now = Date()
        last = Dictionary(uniqueKeysWithValues: rows.map {
            ($0.process, (in: $0.bytesIn, out: $0.bytesOut))
        })
        lastAt = now
        return Self.differ(rows, previous: previous, previousAt: previousAt, at: now)
    }
}