import Foundation
import CcCleanCore

/// 孤儿文件扫描（C11，基线 4 章 C11）：应用已卸载但其用户库残留仍在。
/// 扫描已知模板目录（卸载残留同源 9.1 层级）→ 提取 reverse-DNS bundleId 候选
/// → 对照已装集合 → 未命中即孤儿候选（只报路径与归属候选，不自动删除）。
public struct OrphanScanner: Sendable {

    public init() {}

    public struct OrphanFinding: Sendable, Equatable, Identifiable {
        public var id: String { path }
        public let path: String
        public let bundleIdCandidate: String
        public let sizeBytes: Int64?
        public let confidence: String   // probable（强模板）/ possible（弱模板）

        public init(
            path: String, bundleIdCandidate: String,
            sizeBytes: Int64?, confidence: String
        ) {
            self.path = path
            self.bundleIdCandidate = bundleIdCandidate
            self.sizeBytes = sizeBytes
            self.confidence = confidence
        }
    }

    /// 扫描模板（相对 home；probable = 目录名即 bundleId 的强信号层）。
    static let scanTemplates: [(subpath: String, confidence: String)] = [
        ("Library/Caches", "probable"),
        ("Library/Application Support", "probable"),
        ("Library/Containers", "probable"),
        ("Library/HTTPStorages", "possible"),
        ("Library/Saved Application State", "possible"),
        ("Library/Preferences", "possible"),   // com.*.plist 文件名
    ]

    /// reverse-DNS bundleId 提取：≥2 段、合法字符、排除 com.apple.*（系统项永不报）。
    static func bundleIdCandidate(from name: String) -> String? {
        var text = name
        if text.hasSuffix(".plist") { text = String(text.dropLast(6)) }
        let segments = text.split(separator: ".")
        guard segments.count >= 2 else { return nil }
        let valid = segments.allSatisfy { !$0.isEmpty && !$0.contains(where: { c in
            !(c.isLetter || c.isNumber || c == "-" || c == "_")
        }) }
        guard valid else { return nil }
        guard text != "com.apple" else { return nil }
        if segments[0] == "com" || segments[0] == "cn" || segments[0] == "net" || segments[0] == "org",
           segments.count >= 2, segments[1] == "apple" {
            return nil   // com.apple.* 系统项
        }
        return text
    }

    /// 目录体积（浅层快速估算：一层文件累加 + 子目录递归计数上限 2000 项）。
    static func directorySize(_ path: String) -> Int64? {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir) else { return nil }
        if !isDir.boolValue {
            let attrs = try? fm.attributesOfItem(atPath: path)
            return (attrs?[.size] as? NSNumber)?.int64Value
        }
        var total: Int64 = 0
        let enumerator = fm.enumerator(
            at: URL(fileURLWithPath: path),
            includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsPackageDescendants], errorHandler: { _, _ in true })
        var visited = 0
        while let url = enumerator?.nextObject() as? URL, visited < 2000 {
            visited += 1
            // 符号链接跳过（真实 ~/Library 存在符号链接环，防体积估算失控）
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
                continue
            }
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    /// 扫描孤儿候选。installedBundleIds 由调用方提供（AppScanner 已装清单）。
    public func scan(
        home: String, installedBundleIds: Set<String>
    ) -> [OrphanFinding] {
        let fm = FileManager.default
        var findings: [OrphanFinding] = []
        for template in Self.scanTemplates {
            let dirPath = home + "/" + template.subpath
            guard let entries = try? fm.contentsOfDirectory(atPath: dirPath) else { continue }
            for entry in entries.sorted() {
                guard let bundleId = Self.bundleIdCandidate(from: entry) else { continue }
                guard !installedBundleIds.contains(bundleId) else { continue }
                let full = dirPath + "/" + entry
                let size = Self.directorySize(full)
                findings.append(OrphanFinding(
                    path: full, bundleIdCandidate: bundleId,
                    sizeBytes: size, confidence: template.confidence))
            }
        }
        return findings.sorted { ($0.confidence, $0.path) < ($1.confidence, $1.path) }
    }
}