import Foundation
import CcCleanCore

/// 撤销失败原因（可作 Result.Failure）。
public enum TrashRestoreError: Error {
    case reason(String)
}

/// 废纸篓服务：`trashItem` 的唯一出口（与 OperationJournal 同为代码库仅有的写盘通道，
/// scripts/check-redlines.sh 白名单）。
public struct TrashService: Sendable {

    public init() {}

    /// 移入废纸篓。返回废纸篓中的实际位置（供撤销回原路径）。
    /// 原路径在废纸篓重名时由系统自动改名。
    public func trash(paths: [String]) async -> (succeeded: [String: URL], failed: [String: String]) {
        var succeeded: [String: URL] = [:]
        var failed: [String: String] = [:]
        for path in paths {
            let url = URL(fileURLWithPath: path)
            do {
                var resulting: NSURL?
                try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
                succeeded[path] = (resulting as URL?)
                    ?? URL(fileURLWithPath: NSHomeDirectory() + "/.Trash/" + url.lastPathComponent)
            } catch {
                failed[path] = TrashService.describe(error)
            }
        }
        return (succeeded, failed)
    }

    /// 清空废纸篓指定条目（永久删除，不可撤销；条目已在废纸篓内，trashItem 无意义）。
    public func empty(paths: [String]) async -> (succeeded: [String], failed: [String: String]) {
        var succeeded: [String] = []
        var failed: [String: String] = [:]
        for path in paths {
            do {
                try FileManager.default.removeItem(atPath: path)
                succeeded.append(path)
            } catch {
                failed[path] = TrashService.describe(error)
            }
        }
        return (succeeded, failed)
    }

    /// 从废纸篓恢复到原路径（撤销，基线 6.3 要点 4：原路径被占用则加序号后缀不覆盖）。
    public func restore(trashURL: URL, originalPath: String) async -> Result<String, TrashRestoreError> {
        let original = URL(fileURLWithPath: originalPath)
        let fm = FileManager.default
        guard fm.fileExists(atPath: trashURL.path) else {
            return .failure(.reason("废纸篓中的文件已不存在（可能已被清空）"))
        }
        var target = original
        var seq = 1
        while fm.fileExists(atPath: target.path) {
            let name = original.deletingPathExtension().lastPathComponent
            let ext = original.pathExtension
            let suffix = " (cclean-撤销-\(seq))"
            let newName = ext.isEmpty ? name + suffix : name + suffix + "." + ext
            target = original.deletingLastPathComponent().appendingPathComponent(newName)
            seq += 1
            if seq > 100 { return .failure(.reason("原路径存在且重试次数超限")) }
        }
        // 确保父目录存在（撤销可能发生在目录也被删的场景）
        try? fm.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try fm.moveItem(at: trashURL, to: target)
            return .success(target.path)
        } catch {
            return .failure(.reason(TrashService.describe(error)))
        }
    }

    /// 错误转可读描述（不暴露底层堆栈）。
    static func describe(_ error: Error) -> String {
        let ns = error as NSError
        switch (ns.domain, ns.code) {
        case (NSCocoaErrorDomain, 4):
            return "路径不存在"
        case (NSCocoaErrorDomain, 513):
            return "无权限（可能需要全盘访问或辅助程序）"
        case (NSCocoaErrorDomain, 642):
            return "无法移入废纸篓（可能位于外置卷）"
        default:
            return "操作失败（\(ns.code)）"
        }
    }
}