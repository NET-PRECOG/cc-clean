import Foundation
import CcCleanCore
import CcCleanFS
import CcCleanOps
import CcCleanMetrics
import CcCleanPrivileged

/// CcCleanCLI：回归与 dry-run 工具（不对外分发，基线 5.3）。
@main
struct CcCleanCLI {
    static func main() async {
        let args = CommandLine.arguments
        let command = args.count > 1 ? args[1] : "status"

        switch command {
        case "status":
            print("CcClean CLI v0.1.0")
            print("modules:")
            print("  core       \(CcCleanCoreInfo.version)")
            print("  fs         \(CcCleanFSInfo.version)")
            print("  ops        \(CcCleanOpsInfo.version)")
            print("  metrics    \(CcCleanMetricsInfo.version)")
            print("  privileged \(CcCleanPrivilegedInfo.version)")
            print("data dir:   \(Paths.appSupport.path)")
        case "version":
            print("0.1.0")
        case "smoke":
            await runSmoke()
        default:
            FileHandle.standardError.write("unknown command: \(command)\n".data(using: .utf8)!)
            print("usage: cclean-cli [status|version|smoke]")
            exit(2)
        }
    }

    /// 真实环境功能冒烟（全部只读服务，无写盘无删除；绕过签名的功能回归通道）。
    static func runSmoke() async {
        // 立即刷新 stdout（管道/文件重定向时默认全缓冲，便于长跑时观察进度）
        setvbuf(stdout, nil, _IONBF, 0)
        let logger = Logger(category: .general)
        let home = NSHomeDirectory()
        print("=== CcClean 真实环境功能冒烟（只读） ===")

        func step<T>(_ name: String, _ body: () async -> T) async -> T? {
            let start = Date()
            let result = await body()
            print("   [\(name) 用时 \(String(format: "%.1f", Date().timeIntervalSince(start)))s]")
            return result
        }

        // ① 应用枚举（真实 /Applications；纯 FS 枚举秒级，
        // 全量 scan 含 enrichSources 在真实环境存在并发卡死问题——已知问题单独跟踪）
        await step("AppScanner") {
            let apps = AppScanner.enumerateApps(under: "/Applications")
            print("① AppScanner.enumerateApps: \(apps.count) 个应用（前 3：\(apps.prefix(3).map { ($0 as NSString).lastPathComponent }.joined(separator: "、"))）")
        }

        // ② 孤儿文件（C11：真实 ~/Library；已装集合以枚举到的 .app 名近似，
        // bundleId 候选含应用名即视为已装——只统计不删除）
        await step("OrphanScanner") {
            let installed = Set(AppScanner.enumerateApps(under: "/Applications").map {
                (($0 as NSString).lastPathComponent as NSString).deletingPathExtension
            })
            let orphans = OrphanScanner().scan(
                home: home, installedBundleIds: installed)
            print("② OrphanScanner(C11): \(orphans.count) 个孤儿候选（前 3：\(orphans.prefix(3).map(\.bundleIdCandidate).joined(separator: "、"))）")
        }

        // ③ JDK（M3）
        do {
            let jdk = JDKService(logger: logger)
            let entries = await jdk.list()
            let current = await jdk.currentJavaHome()
            print("③ JDKService(M3): \(entries.count) 个 JDK，JAVA_HOME=\(current ?? "未设置")")
        }

        // ④ PATH 冲突（M5）
        do {
            let detector = PathConflictDetector()
            let exports = await detector.parseProfiles(home: home)
            let conflicts = detector.detect(exports: exports)
            print("④ PathConflictDetector(M5): \(exports.count) 个 profile，\(conflicts.count) 个冲突")
        }

        // ⑤ Android SDK（M1）
        do {
            let sdk = AndroidSdkService().resolveSdkHome()
            print("⑤ AndroidSdkService(M1): \(sdk ?? "未探测到 ANDROID_HOME")")
        }

        // ⑥ 网络连接（I5）
        do {
            let connections = await NetworkConnectionSampler.sample()
            print("⑥ NetworkConnectionSampler(I5): \(connections.count) 条 ESTABLISHED")
        }

        // ⑦ 摄像头/麦克风（I4）
        do {
            let camera = CameraMicMonitor.cameraInUse()
            let mic = CameraMicMonitor.microphoneInUse()
            print("⑦ CameraMicMonitor(I4): 摄像头=\(camera.map { $0 ? "占用" : "空闲" } ?? "无法检测")，麦克风=\(mic.map { $0 ? "占用" : "空闲" } ?? "无法检测")")
        }

        // ⑧ 代理/防火墙（I6）
        do {
            let suite = SecuritySuite(appEnvironment: SystemAppEnvironment(), logger: logger)
            let status = await suite.networkSecurityStatus()
            print("⑧ SecuritySuite(I6): HTTP代理=\(status.httpProxyEnabled ? "开" : "关")，防火墙=\(status.firewallEnabled.map { $0 ? "开" : "关" } ?? "无法检测")")
        }

        // ⑨ 分应用流量（E5）
        do {
            let sampler = PerAppTrafficSampler()
            if let traffic = await sampler.sample() {
                let top = traffic.prefix(3).map { "\($0.process)" }.joined(separator: "、")
                print("⑨ PerAppTrafficSampler(E5): \(traffic.count) 个进程（Top3：\(top)）")
            } else {
                print("⑨ PerAppTrafficSampler(E5): nettop 不可用（降级）")
            }
        }

        // ⑪ mas（B10：只探测不升级）
        do {
            let mas = MasService(logger: logger)
            let path = await mas.resolveMas()
            print("⑪ MasService(B10): \(path ?? "未安装 mas CLI（降级）")")
        }

        // ⑫ BTM 后台项（H3）
        do {
            let exists = BackgroundItemsService.btmExists(home: home)
            print("⑫ BackgroundItemsService(H3): BTM 数据库\(exists ? "存在" : "不存在")")
        }

        // ⑬ 监控最新值（E14 数据源）
        do {
            let store: DatabaseStore
            do {
                store = try DatabaseStore.open(at: Paths.mainDatabase, logger: logger)
            } catch {
                print("⑬ latestMetricValue(E14): 数据库打开失败（降级）")
                print("=== 冒烟完成（全部只读，无副作用） ===")
                return
            }
            async let cpu = store.latestMetricValue(kind: "cpuUsage")
            async let swap = store.latestMetricValue(kind: "swapUsed")
            print("⑬ latestMetricValue(E14): cpuUsage=\(await cpu.map { String(format: "%.1f%%", $0) } ?? "无记录")，swapUsed=\(await swap.map { "\(Int($0 / 1024 / 1024))MB" } ?? "无记录")")
        }

        // ⑭ 多包管理器（D11）——放最后：conda 大环境 list 极慢，
        // 且 ProcessRunner 超时 kill 后存在 waitUntilExit 卡死已知问题（单独跟踪）
        do {
            let multi = MultiPackageManager(logger: logger)
            let packages = await multi.listAll()
            let byManager = Dictionary(grouping: packages, by: \.manager)
                .map { "\($0.key): \($0.value.count)" }
                .sorted().joined(separator: "，")
            print("⑭ MultiPackageManager(D11): \(packages.isEmpty ? "无全局包" : byManager)")
        }

        print("=== 冒烟完成（全部只读，无副作用） ===")
    }
}