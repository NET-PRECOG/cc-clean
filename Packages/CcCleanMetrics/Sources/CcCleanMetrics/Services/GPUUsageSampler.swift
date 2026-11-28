import Foundation
import Darwin
import CoreFoundation
import CcCleanCore

/// GPU 实时利用率采样器（macOS 26 逆向 libIOReport.dylib 私有通道）。
/// 原理：订阅 "GPU Stats" 组 → CreateSamples 差分 → GPUPH 状态通道 'OFF'（时钟关断）驻留占比 → 利用率 = 1 − OFF%。
/// GPU 无公开 API（官网确认），经 dlsym 调用私有导出符号（与活动监视器 GPU 历史同源口径）。
public final class GPUUsageSampler: @unchecked Sendable {

    public static let shared = GPUUsageSampler()

    // dlsym 函数指针类型（新版 IOReport API，全部经实测破解；CF 对象以 UnsafeRawPointer 传递）
    private typealias FnCopyGroup = @convention(c) (UnsafeRawPointer, UnsafeRawPointer?, UnsafeRawPointer?, UnsafeRawPointer?, UnsafeRawPointer?) -> UnsafeMutableRawPointer?
    private typealias FnCreateSub = @convention(c) (UnsafeRawPointer?, UnsafeRawPointer?, UnsafeRawPointer?, UInt64, UnsafeMutablePointer<UnsafeRawPointer?>) -> UnsafeRawPointer?
    private typealias FnCreateSamples = @convention(c) (UnsafeRawPointer?, UnsafeRawPointer?, UnsafeRawPointer?) -> UnsafeRawPointer?
    private typealias FnDelta = @convention(c) (UnsafeRawPointer?, UnsafeRawPointer?, UnsafeRawPointer?) -> UnsafeRawPointer?
    private typealias FnName = @convention(c) (UnsafeRawPointer?) -> UnsafeRawPointer?
    private typealias FnSubGroup = @convention(c) (UnsafeRawPointer?) -> UnsafeRawPointer?
    private typealias FnStateCount = @convention(c) (UnsafeRawPointer?) -> UInt64
    private typealias FnStateResidency = @convention(c) (UnsafeRawPointer?, UInt64) -> UInt64
    private typealias FnStateName = @convention(c) (UnsafeRawPointer?, UInt64) -> UnsafeRawPointer?

    private var fnCopyGroup: FnCopyGroup?
    private var fnCreateSub: FnCreateSub?
    private var fnCreateSamples: FnCreateSamples?
    private var fnDelta: FnDelta?
    private var fnName: FnName?
    private var fnSubGroup: FnSubGroup?
    private var fnStateCount: FnStateCount?
    private var fnStateResidency: FnStateResidency?
    private var fnStateName: FnStateName?

    private var channels: UnsafeRawPointer?
    private var agg: UnsafeRawPointer?
    private var sub: UnsafeRawPointer?
    private var prevSamples: UnsafeRawPointer?

    private static let kUTF8Encoding = CFStringEncoding(0x08000100)

    private var ready = false
    private var failed = false
    private var lastBusy = -1.0
    private var lastTotal = -1.0

    private init() {
        setup()
    }

    private func setup() {
        guard let h = dlopen("/usr/lib/libIOReport.dylib", RTLD_LAZY) else { failed = true; return }
        guard
            let s1 = dlsym(h, "IOReportCopyChannelsInGroup"),
            let s2 = dlsym(h, "IOReportCreateSubscription"),
            let s3 = dlsym(h, "IOReportCreateSamples"),
            let s4 = dlsym(h, "IOReportCreateSamplesDelta"),
            let s5 = dlsym(h, "IOReportChannelGetChannelName"),
            let s6 = dlsym(h, "IOReportChannelGetSubGroup"),
            let s7 = dlsym(h, "IOReportStateGetCount"),
            let s8 = dlsym(h, "IOReportStateGetResidency"),
            let s9 = dlsym(h, "IOReportStateGetNameForIndex")
        else { failed = true; return }
        fnCopyGroup = unsafeBitCast(s1, to: FnCopyGroup.self)
        fnCreateSub = unsafeBitCast(s2, to: FnCreateSub.self)
        fnCreateSamples = unsafeBitCast(s3, to: FnCreateSamples.self)
        fnDelta = unsafeBitCast(s4, to: FnDelta.self)
        fnName = unsafeBitCast(s5, to: FnName.self)
        fnSubGroup = unsafeBitCast(s6, to: FnSubGroup.self)
        fnStateCount = unsafeBitCast(s7, to: FnStateCount.self)
        fnStateResidency = unsafeBitCast(s8, to: FnStateResidency.self)
        fnStateName = unsafeBitCast(s9, to: FnStateName.self)

        let groupStr = "GPU Stats" as CFString
        let groupPtr = UnsafeRawPointer(Unmanaged.passUnretained(groupStr).toOpaque())
        guard let chans = fnCopyGroup?(groupPtr, nil, nil, nil, nil) else { failed = true; return }
        channels = UnsafeRawPointer(chans)
        var aggPtr: UnsafeRawPointer? = nil
        var errSlot: UnsafeRawPointer? = nil
        sub = withUnsafeMutablePointer(to: &errSlot) { errPtr in
            fnCreateSub?(nil, UnsafeRawPointer(chans), &aggPtr, 0, errPtr)
        }
        guard sub != nil, let aggP = aggPtr else { failed = true; return }
        agg = aggP
        ready = true
    }

    /// UnsafeRawPointer?（CFString）→ Swift String。
    private static func str(_ ptr: UnsafeRawPointer?) -> String? {
        guard let ptr else { return nil }
        let cf = unsafeBitCast(ptr, to: CFString.self)
        var buf = [CChar](repeating: 0, count: 256)
        guard CFStringGetCString(cf, &buf, 256, Self.kUTF8Encoding) else { return nil }
        return buf.cStringDecoded()
    }

    /// 采样 GPU 利用率（0~1）。首次调用（无差分基线）或链路不可用返回 nil。
    public func sample() -> Double? {
        guard ready, !failed,
              let fnCS = fnCreateSamples, let fnD = fnDelta,
              let fnSubG = fnSubGroup, let fnRes = fnStateResidency,
              let fnSC = fnStateCount, let fnSN = fnStateName,
              channels != nil, let ag = agg, let sb = sub,
              let cur = fnCS(sb, ag, nil)
        else { return nil }

        // 所有权管理（Create/Delta 返回按 +1 retained 规则）：
        // delta 与旧 prev 用完即释放；cur 保留所有权，本轮结束时接管 prevSamples。
        let oldPrev = prevSamples
        var deltaDict: UnsafeRawPointer? = nil
        if let prev = oldPrev {
            deltaDict = fnD(prev, cur, nil)
        }
        defer {
            if let dd = deltaDict {
                Unmanaged.passUnretained(unsafeBitCast(dd, to: CFTypeRef.self)).release()
            }
            if let prev = oldPrev {
                Unmanaged.passUnretained(unsafeBitCast(prev, to: CFTypeRef.self)).release()
            }
        }

        var busy = 0.0
        var total = 0.0
        var found = false
        if let dd = deltaDict {
            let dict = unsafeBitCast(dd, to: CFDictionary.self)
            let keyStr = "IOReportChannels" as CFString
            let keyPtr = UnsafeRawPointer(Unmanaged.passUnretained(keyStr).toOpaque())
            guard let arrRef = CFDictionaryGetValue(dict, keyPtr) else {
                prevSamples = UnsafeRawPointer(cur)
                return nil
            }
            let arr = unsafeBitCast(arrRef, to: CFArray.self)
            let n = CFArrayGetCount(arr)
            for i in 0..<n {
                guard let el = CFArrayGetValueAtIndex(arr, i) else { continue }
                guard let sg = fnSubG(el), let subName = Self.str(sg) else { continue }
                guard subName == "GPU Performance States" else { continue }
                found = true
                let sc = Int(fnSC(el))
                for s in 0..<max(sc, 0) {
                    let res = fnRes(el, UInt64(s))
                    total += Double(res)
                    // OFF = 时钟关断（空闲）；其余 P1..P15 为活动驻留
                    if let nm = fnSN(el, UInt64(s)), let name = Self.str(nm), name != "OFF" {
                        busy += Double(res)
                    }
                }
                break
            }
        }

        // cur 保留所有权接管 prevSamples（旧 prev 已由 defer 释放）
        prevSamples = UnsafeRawPointer(cur)

        // delta 内的驻留已是 1 秒差分值（total≈24M tick = 100% 时间），
        // 利用率直接取 delta 内占比（1 − OFF%）；不可再做二次差分（会失真恒 100%）
        guard found, total > 0 else { return nil }
        let util = busy / total
        return max(min(util, 1), 0)
    }
}