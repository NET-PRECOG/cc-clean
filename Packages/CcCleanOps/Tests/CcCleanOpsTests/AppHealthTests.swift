import Testing
import Foundation
import CcCleanCore
import CcCleanFS
@testable import CcCleanOps

@Suite("AppHealthService (A6)")
struct AppHealthServiceTests {

    let service = AppHealthService(logger: Logger(category: .scan, buffer: LogBuffer(capacity: 10)))

    @Test("A6 六类检查：签名失效/ad-hoc/僵尸启动项/来源异常/路径异常/孤儿启动项（OpenClaw 样本）")
    func healthCheckAggregation() async {
        let adHoc = AppRecord(bundleId: "com.a", bundlePath: "/Applications/A.app", displayName: "A",
                              installSource: .homebrewCask, signature: .adHoc)
        let unsigned = AppRecord(bundleId: "com.b", bundlePath: "/Users/x/B.app", displayName: "B",
                                 installSource: .dragAndDrop, signature: .unknown)
        let normal = AppRecord(bundleId: "com.normal", bundlePath: "/Applications/N.app", displayName: "N",
                               installSource: .appStore, signature: .developerID, isProtected: false)
        let system = AppRecord(bundleId: "com.apple.s", bundlePath: "/System/Applications/S.app", displayName: "S",
                               isProtected: true)

        let zombieEntry = LaunchdEntry(
            label: "com.a.helper", plistPath: "~/Library/LaunchAgents/a.plist", domain: "gui/501",
            program: "/nonexistent/helper", args: [],
            runAtLoad: nil, keepAlive: nil, startInterval: nil,
            ownerBundle: "com.a", isSystem: false, healthy: false
        )
        let orphanEntry = LaunchdEntry(
            label: "ai.openclaw.gateway", plistPath: "~/Library/LaunchAgents/oc.plist", domain: "gui/501",
            program: "/Users/x/Library/OpenClaw/gateway", args: [],
            runAtLoad: nil, keepAlive: nil, startInterval: nil,
            ownerBundle: nil, isSystem: false, healthy: false
        )

        let findings = await service.healthCheck(
            records: [adHoc, unsigned, normal, system],
            signatures: [
                "/Applications/A.app": (teamId: nil, isAdHoc: true),
                "/Users/x/B.app": (teamId: nil, isAdHoc: false),
                "/Applications/N.app": (teamId: "TEAM1", isAdHoc: false),
            ],
            launchdEntries: [zombieEntry, orphanEntry])

        // A：ad-hoc + 僵尸启动项
        #expect(findings.contains { $0.bundleId == "com.a" && $0.checkId == "signature-adhoc" })
        #expect(findings.contains { $0.bundleId == "com.a" && $0.checkId == "zombie-launchd" })
        // B：未签名 + 来源异常 + 路径异常
        #expect(findings.contains { $0.bundleId == "com.b" && $0.checkId == "signature-invalid" })
        #expect(findings.contains { $0.bundleId == "com.b" && $0.checkId == "suspicious-source" })
        #expect(findings.contains { $0.bundleId == "com.b" && $0.checkId == "path-anomaly" })
        // 孤儿启动项（OpenClaw：ownerBundle nil + unhealthy）
        #expect(findings.contains { $0.bundleId == "ai.openclaw.gateway" && $0.checkId == "zombie-launchd" })
        // 正常应用与系统应用零发现（零误报语义）
        #expect(!findings.contains { $0.bundleId == "com.normal" })
        #expect(!findings.contains { $0.bundleId == "com.apple.s" })
        // 高危排序在前（僵尸 high > medium）
        if let first = findings.first {
            #expect(first.severity == .high)
        }
    }

    @Test("A6 空台账 + 无异常启动项 → 零发现")
    func emptyRecords() async {
        let findings = await service.healthCheck(records: [], signatures: [:], launchdEntries: [])
        #expect(findings.isEmpty)
    }
}

@Suite("SparkleVersionProvider B6 变更日志")
struct SparkleReleaseNotesTests {

    @Test("B6 releaseNotesLink 提取 → notesUrl（变更日志展示数据源）")
    func releaseNotesExtraction() async throws {
        final class NotesFetcher: NetworkFetching, @unchecked Sendable {
            func fetch(_ url: URL, timeout: TimeInterval, cachePolicy: URLRequest.CachePolicy) async throws -> Data {
                Data("""
                <rss><channel>
                <item>
                <sparkle:shortVersionString>2.5.0</sparkle:shortVersionString>
                <sparkle:releaseNotesLink>https://example.com/notes-2.5.0.html</sparkle:releaseNotesLink>
                <enclosure url="https://example.com/X-2.5.0.dmg" sparkle:version="2500"/>
                </item>
                </channel></rss>
                """.utf8)
            }
        }
        let probe = VersionProbe(
            bundleId: "com.example.app", bundlePath: "/X.app",
            shortVersion: "2.4.0", sparkleFeedURL: "https://example.com/appcast.xml")
        let provider = SparkleVersionProvider(network: NotesFetcher())
        let result = try #require(await provider.check(probe))
        #expect(result.notesUrl == "https://example.com/notes-2.5.0.html")   // B6 ✓
        #expect(result.downloadUrl == "https://example.com/X-2.5.0.dmg")     // 既有语义不回归
    }
}