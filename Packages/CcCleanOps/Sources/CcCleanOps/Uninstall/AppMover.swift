import Foundation
import CoreServices
import CcCleanCore

/// 应用搬家（C14，基线：失败可回滚）。
/// 同卷：moveItem 原子改名；跨卷：copy → 内容校验 → 旧位置进废纸篓（journal 可撤销）→ 暂存改名。
/// 任何失败点：原位置不动（或可从废纸篓恢复）+ 半成品暂存清理。
public actor AppMover {

    private let logger: Logger

    public init(logger: Logger) {
        self.logger = logger
    }

    public struct MoveOutcome: Sendable, Equatable {
        public let newPath: String?
        public let rolledBack: Bool
        public let message: String

        public init(newPath: String?, rolledBack: Bool, message: String) {
            self.newPath = newPath
            self.rolledBack = rolledBack
            self.message = message
        }
    }

    /// 搬家 .app 到目标目录（失败可回滚，基线 C14 DoD）。
    public func move(
        bundlePath: String, toDirectory: String, journal: OperationJournal
    ) async -> MoveOutcome {
        let fm = FileManager.default
        let bundleName = (bundlePath as NSString).lastPathComponent
        guard bundleName.hasSuffix(".app") else {
            return .init(newPath: nil, rolledBack: false, message: "仅支持 .app 搬家")
        }
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: bundlePath, isDirectory: &isDir), isDir.boolValue else {
            return .init(newPath: nil, rolledBack: false, message: "源应用不存在")
        }
        guard fm.fileExists(atPath: toDirectory, isDirectory: &isDir), isDir.boolValue else {
            return .init(newPath: nil, rolledBack: false, message: "目标目录不存在")
        }
        let target = (toDirectory as NSString).appendingPathComponent(bundleName)
        guard !fm.fileExists(atPath: target) else {
            return .init(newPath: nil, rolledBack: false, message: "目标已存在同名应用")
        }

        // 同卷：moveItem 原子改名
        do {
            try fm.moveItem(atPath: bundlePath, toPath: target)
        } catch {
            // 跨卷：copy → 校验 → trash 旧 → 暂存改名
            let staging = target + ".cclean-moving"
            do {
                try fm.copyItem(atPath: bundlePath, toPath: staging)
                guard Self.contentsConsistent(from: bundlePath, to: staging) else {
                    try? fm.removeItem(atPath: staging)
                    return .init(newPath: nil, rolledBack: false,
                                 message: "复制校验失败，原位置未动")
                }
                let id = await journal.begin("应用搬家 \(bundleName)")
                try? await journal.append(.trash(paths: [bundlePath]), to: id)
                _ = await journal.commit(id)
                if fm.fileExists(atPath: bundlePath) {
                    // 旧位置移除失败 → 清暂存、原地不动（可从废纸篓恢复）
                    try? fm.removeItem(atPath: staging)
                    return .init(newPath: nil, rolledBack: true,
                                 message: "旧位置移除失败，已回滚（可从废纸篓恢复）")
                }
                try fm.moveItem(atPath: staging, toPath: target)
            } catch {
                try? fm.removeItem(atPath: staging)
                return .init(newPath: nil, rolledBack: true,
                             message: "搬家失败，已回滚：\((error as NSError).localizedDescription)")
            }
        }
        Self.registerApp(at: target)
        logger.info("app moved: \(bundleName) → \(toDirectory)")
        return .init(newPath: target, rolledBack: false, message: "搬家完成")
    }

    /// 内容一致性校验（文件数 + 字节总量；上限 5000 项防失控）。
    static func contentsConsistent(from: String, to: String) -> Bool {
        guard let src = Self.tally(at: from), let dst = Self.tally(at: to) else { return false }
        return src == dst
    }

    /// (文件数, 字节总量)。
    static func tally(at path: String) -> (files: Int, bytes: Int64)? {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir) else { return nil }
        if !isDir.boolValue {
            guard let attrs = try? fm.attributesOfItem(atPath: path),
                  let size = (attrs[.size] as? NSNumber)?.int64Value else { return nil }
            return (1, size)
        }
        let enumerator = fm.enumerator(
            at: URL(fileURLWithPath: path),
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [], errorHandler: { _, _ in true })
        var files = 0
        var bytes: Int64 = 0
        while let url = enumerator?.nextObject() as? URL {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true {
                files += 1
                bytes += Int64(values?.fileSize ?? 0)
            }
        }
        return (files, bytes)
    }

    /// 搬家后重注册 LaunchServices（Finder/Spotlight/关联打开识别新路径）。
    static func registerApp(at path: String) {
        let url = URL(fileURLWithPath: path)
        _ = try? url.resourceValues(forKeys: [.isApplicationKey])
        LSRegisterURL(url as CFURL, true)
    }
}