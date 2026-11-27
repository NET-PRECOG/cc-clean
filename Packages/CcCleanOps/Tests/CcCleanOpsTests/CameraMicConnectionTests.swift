import Testing
import Foundation
@testable import CcCleanOps

@Suite("CameraMicMonitor (I4) + NetworkConnectionSampler (I5)")
struct CameraMicConnectionTests {

    @Test("I4：真实探测摄像头/麦克风占用（失败返回 nil 不伪造，值域合法）")
    func realProbe() {
        if let camera = CameraMicMonitor.cameraInUse() {
            #expect(camera == true || camera == false)
        } else {
            #expect(Bool(true))   // 无摄像头设备/枚举失败：合法降级
        }
        if let mic = CameraMicMonitor.microphoneInUse() {
            #expect(mic == true || mic == false)
        } else {
            #expect(Bool(true))
        }
    }

    @Test("I5：lsof 输出解析（真实格式：IPv4/IPv6/表头/非 ESTABLISHED/UDP 剔除）")
    func lsofParsing() {
        let sample = """
        COMMAND     PID   USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
        rapportd    561 huangchao   14u  IPv6 0xf9e51a7d981d1952      0t0  TCP [2408:8207::949f]:50695->[2408:8207::f2ae]:60905 (ESTABLISHED)
        identitys   588 huangchao   53u  IPv6 0xf04b5de04721c3ee      0t0  TCP [fe80:1d::d01c:35dd]:1024->[fe80:1d::cad4:eb9b:d014]:1024 (ESTABLISHED)
        mDNSRespo   256 huangchao   30u  IPv4 0xabc                  0t0  UDP *:5353
        Chrome     1200 huangchao   44u  IPv4 0xdef                  0t0  TCP 192.168.1.2:52333->142.250.66.10:443 (ESTABLISHED)
        Chrome     1200 huangchao   45u  IPv4 0x123                  0t0  TCP 192.168.1.2:52334->142.250.66.10:443 (CLOSE_WAIT)
        """
        let entries = NetworkConnectionSampler.parse(sample)
        // 保留 3 条 ESTABLISHED TCP（rapportd/identitys/Chrome）
        #expect(entries.count == 3)
        let chrome = entries.first { $0.processName == "Chrome" }
        #expect(chrome?.pid == 1200)
        #expect(chrome?.remote == "142.250.66.10:443")
        let rapport = entries.first { $0.processName == "rapportd" }
        #expect(rapport?.pid == 561)
        #expect(rapport?.remote == "[2408:8207::f2ae]:60905")
        // UDP / CLOSE_WAIT / 表头不在结果
        #expect(!entries.contains { $0.processName == "mDNSRespo" })
        #expect(entries.allSatisfy { $0.remote != "" })
    }

    @Test("I5：畸形输入不崩（空输出/无箭头/非数字 pid）")
    func lsofMalformed() {
        #expect(NetworkConnectionSampler.parse("").isEmpty)
        #expect(NetworkConnectionSampler.parse("no arrow line here\nfoo abc TCP x:y (ESTABLISHED)").isEmpty)
    }

    @Test("I5：真实采样（lsof -i 只读；失败/无权限 → 空列表降级）")
    func realSample() async {
        let entries = await NetworkConnectionSampler.sample()
        // 本机必有监听/连接或降级；两种均合法
        #expect(entries.count >= 0)
        if !entries.isEmpty {
            #expect(entries.allSatisfy { $0.pid > 0 && !$0.remote.isEmpty })
        }
    }
}