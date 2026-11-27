import Testing
import Foundation
@testable import CcCleanMetrics

/// 临时诊断：SMC 两步协议实测（跑完即删）。
@Suite("SMC Diagnostics")
struct SMCDiagnosticsTests {

    @Test("SMC 键值分步实测")
    func keys() {
        let results = SystemInfoService.smcDiagnostic(["#NUMFAN", "F0Ac", "F1Ac", "F0ID"])
        for r in results {
            print("SMC_DIAG: key=\(r.key) size=\(r.dataSize) type='\(r.dataType)' bytes=\(r.bytes)")
        }
    }

    @Test("风扇读数最终验证")
    func fans() {
        let fans = SystemInfoService.fanReadings()
        print("FAN_FINAL: \(fans.count) 个风扇")
        for fan in fans {
            print("FAN_FINAL: idx=\(fan.index) rpm=\(fan.rpm) name=\(fan.name ?? "nil")")
        }
    }

    @Test("电池循环/健康度最终验证")
    func battery() {
        guard let d = SystemInfoService.batteryDetail() else {
            print("BATT_FINAL: nil")
            return
        }
        print("BATT_FINAL: cycles=\(d.cycles) health=\(d.healthPercent)%")
    }
}