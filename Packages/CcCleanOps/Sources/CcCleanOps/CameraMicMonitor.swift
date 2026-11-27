import Foundation
import CoreMediaIO
import CoreAudio

/// 摄像头/麦克风占用检测（I4，基线：2 秒内提示、可关——轮询开关由 UI 层控制，
/// 关闭后 UI 停止轮询即不常驻监听）。
/// 检测语义：任一设备正在被系统内某进程使用（DeviceIsRunningSomewhere）；
/// 枚举失败 → nil（不伪造，UI 显示「无法检测」）。
public enum CameraMicMonitor {

    /// 摄像头是否被占用（CMIO 枚举全部视频设备）。
    public static func cameraInUse() -> Bool? {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        let system = CMIOObjectID(kCMIOObjectSystemObject)
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0
        else { return nil }
        var devices = [CMIOObjectID](
            repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.stride)
        guard CMIOObjectGetPropertyData(system, &address, 0, nil, size, &size, &devices) == noErr
        else { return nil }
        for device in devices {
            if isRunning(deviceCMIO: device) { return true }
        }
        return false
    }

    /// 麦克风是否被占用（默认输入设备的 IsRunningSomewhere）。
    public static func microphoneInUse() -> Bool? {
        var defaultAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var deviceID = AudioObjectID(0)
        var deviceSize = UInt32(MemoryLayout<AudioObjectID>.size)
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyData(
            system, &defaultAddress, 0, nil, &deviceSize, &deviceID) == noErr,
            deviceID != 0 else { return nil }

        var runningAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var running: UInt32 = 0
        var runningSize = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(
            deviceID, &runningAddress, 0, nil, &runningSize, &running) == noErr else { return nil }
        return running != 0
    }

    private static func isRunning(deviceCMIO: CMIOObjectID) -> Bool {
        var runningAddress = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var running: UInt32 = 0
        var runningSize = UInt32(MemoryLayout<UInt32>.size)
        guard CMIOObjectGetPropertyData(
            deviceCMIO, &runningAddress, 0, nil, runningSize, &runningSize, &running) == noErr
        else {
            return false
        }
        return running != 0
    }
}