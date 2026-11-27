import Testing
import Foundation
@testable import CcCleanMetrics

@Suite("PerAppTrafficSampler (E5 分应用流量)")
struct PerAppTrafficTests {

    private let sample = """
    time,,interface,state,bytes_in,bytes_out,rx_dupe,rx_ooo,re-tx,rtt_avg,rcvsize,tx_win,tc_class,tc_mgt,cc_algo,P,C,R,W,arch,
    14:54:52.154582,launchd.1,,,0,0,0,0,0,,,,,,,,,,,,
    14:54:52.154585,configd.117,,,325791,234018,0,0,0,,,,,,,,,,,,
    14:54:52.154589,apsd.147,,,87755,420810,0,0,15939,,,,,,,,,,,,
    14:54:52.154590,mDNSResponder.256,,,10193121,3265990,0,0,0,,,,,,,,,,,,
    14:54:52.154591,badrow,,,:not-a-number,0,0,0,0,,,,,,,,,,,,
    """

    @Test("parseNettop：表头剔除、bytes 列解析、非法行跳过")
    func parsing() {
        let rows = PerAppTrafficSampler.parseNettop(sample)
        #expect(rows.count == 4)   // badrow 跳过
        #expect(rows.contains { $0.process == "mDNSResponder.256" && $0.bytesIn == 10_193_121 })
        #expect(rows.contains { $0.process == "apsd.147" && $0.bytesOut == 420_810 })
        #expect(rows.contains { $0.process == "launchd.1" && $0.bytesIn == 0 })
    }

    @Test("差分：首采样速率 0；第二次差分速率正确；按总速率降序")
    func differRates() {
        let rows1 = PerAppTrafficSampler.parseNettop(sample)
        let t1 = Date()
        let first = PerAppTrafficSampler.differ(rows1, previous: nil, previousAt: nil, at: t1)
        #expect(first.allSatisfy { $0.inRate == 0 && $0.outRate == 0 })

        let rows2: [(process: String, bytesIn: Int64, bytesOut: Int64)] = [
            ("apsd.147", 87_755 + 1000, 420_810 + 2000),
            ("configd.117", 325_791, 234_018),
        ]
        let t2 = t1.addingTimeInterval(10)
        let second = PerAppTrafficSampler.differ(
            rows2, previous: Dictionary(uniqueKeysWithValues: rows1.map {
                ($0.process, (in: $0.bytesIn, out: $0.bytesOut))
            }), previousAt: t1, at: t2)
        let apsd = second.first { $0.process == "apsd.147" }!
        #expect(apsd.inRate == 100)    // 1000 / 10s
        #expect(apsd.outRate == 200)
        let configd = second.first { $0.process == "configd.117" }!
        #expect(configd.inRate == 0 && configd.outRate == 0)
        // 按总速率降序：apsd 在前
        #expect(second.first?.process == "apsd.147")
    }

    @Test("时间过近（<0.1s）→ 速率 0（不伪造突增）")
    func tooClose() {
        let rows: [(process: String, bytesIn: Int64, bytesOut: Int64)] = [("a.1", 100, 100)]
        let prev = ["a.1": (in: Int64(0), out: Int64(0))]
        let t = Date()
        let result = PerAppTrafficSampler.differ(
            rows, previous: prev, previousAt: t.addingTimeInterval(0.05), at: t)
        #expect(result[0].inRate == 0 && result[0].outRate == 0)
    }

    @Test("真实采样：nettop 只读（成功 → 排序结果；失败 → nil 降级）")
    func realSample() async {
        let sampler = PerAppTrafficSampler()
        let result = await sampler.sample()
        if let result {
            #expect(!result.isEmpty)
            #expect(result.allSatisfy { $0.bytesIn >= 0 && $0.inRate >= 0 })
        } else {
            #expect(Bool(true))   // 环境不支持：合法降级
        }
    }
}