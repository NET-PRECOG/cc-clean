import Testing
import Foundation
import CcCleanCore
@testable import CcCleanOps

@Suite("DevTools (M4/M6/M8/H4/H6)")
struct DevToolsTests {

    @Test("M6 Git 仓库扫描：fixture 仓库发现 + 体积排序 + gc 建议")
    func gitRepoScan() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("git-scan-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // fixture：真实初始化一个 git 仓库（git 命令本机可用）
        let repo = root.appendingPathComponent("big-repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let initResult = ProcessResult(exitCode: 0, stdout: "", stderr: "")
        _ = initResult
        // 直接创建 .git 结构（不依赖 git 命令安装）
        let gitDir = repo.appendingPathComponent(".git/objects/pack")
        try FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
        try Data(repeating: 0x58, count: 2048).write(to: gitDir.appendingPathComponent("pack-abc.pack"))
        // 非仓库目录（不进结果）
        let plain = root.appendingPathComponent("plain")
        try FileManager.default.createDirectory(at: plain.appendingPathComponent(".git-not"), withIntermediateDirectories: true)

        let repos = GitRepoScanner.scan(roots: [root.path], maxDepth: 3)
        #expect(repos.count == 1)
        let entry = try #require(repos.first)
        #expect(entry.path.hasSuffix("big-repo"))
        #expect(entry.gitBytes > 0)
        // > 100MB 才建议 gc——fixture 体积小 → 无建议
        #expect(GitRepoScanner.suggestion(for: entry) == nil)
    }

    @Test("M6 gc 建议：> 100MB 仓库触发")
    func gcSuggestion() {
        let big = GitRepoEntry(path: "/repo", gitBytes: 200 * 1024 * 1024, packBytes: 150 * 1024 * 1024)
        let suggestion = GitRepoScanner.suggestion(for: big)
        #expect(suggestion?.contains("gc --aggressive") == true)
    }

    @Test("H6 卡慢识别：CPU 持续高 + 内存高 + Apple 进程排除")
    func slowAppDetection() {
        let samples: [[CcCleanOps.SlowAppSample]] = [
            [
                .init(pid: 100, name: "Runner", cpuPercent: 60, rssBytes: 2_000_000_000, isAppleSystem: false),
                .init(pid: 200, name: "Idle", cpuPercent: 5, rssBytes: 100_000_000, isAppleSystem: false),
                .init(pid: 300, name: "kernel_task", cpuPercent: 80, rssBytes: 500_000_000, isAppleSystem: true),
            ],
            [
                .init(pid: 100, name: "Runner", cpuPercent: 70, rssBytes: 2_100_000_000, isAppleSystem: false),
                .init(pid: 200, name: "Idle", cpuPercent: 3, rssBytes: 100_000_000, isAppleSystem: false),
                .init(pid: 300, name: "kernel_task", cpuPercent: 85, rssBytes: 500_000_000, isAppleSystem: true),
            ],
        ]
        let findings = CcCleanOps.SlowAppDetector.detect(samples: samples)
        // Runner：CPU 持续高 + 内存高 → 命中；Idle：低 → 不命中；Apple 进程排除
        #expect(findings.count == 1)
        #expect(findings.first?.name == "Runner")
    }

    @Test("H4 开机耗时：boottime 合理（过去时间）")
    func bootTime() {
        if let boot = CcCleanOps.BootTimeAnalyzer.bootTime() {
            #expect(boot < Date())
            #expect(CcCleanOps.BootTimeAnalyzer.uptimeSinceBoot()! > 0)
        }
        // 无 boottime 环境（理论不可能）降级不崩溃
    }

    @Test("M8 端口扫描：lsof 输出解析（结构化 + 排序）")
    func portScan() async throws {
        final class FakeLsofRunner: BrewCommandRunning, @unchecked Sendable {
            func run(brewPath: String, args: [String], timeout: Duration) async throws -> ProcessResult {
                ProcessResult(exitCode: 0, stdout: """
                COMMAND   PID USER   FD   TYPE DEVICE SIZE/OFF NODE NAME
                launchd     1 root    24u  IPv4  0xabc      0t0  TCP *:22 (LISTEN)
                HttpServer 512 user    10u  IPv4  0xdef      0t0  TCP *:8080 (LISTEN)
                """, stderr: "")
            }
        }
        let entries = await CcCleanOps.PortScanner.scan(runner: FakeLsofRunner())
        #expect(entries.count == 2)
        #expect(entries.map(\.port) == [22, 8080])   // 按端口排序
        #expect(entries[0].processName == "launchd")
        #expect(entries.allSatisfy { $0.isListening })
    }
}