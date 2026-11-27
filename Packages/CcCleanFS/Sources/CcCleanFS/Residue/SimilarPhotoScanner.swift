import Foundation
import Vision
import CoreGraphics
import ImageIO
import CcCleanCore

/// 相似照片检测（F4，基线：VNGenerateImageFeaturePrint、余弦距离 0.28 聚类、
/// 簇内保留最佳、永不默认勾选——UI 层对 similar 项默认不勾选，仅建议）。
public struct SimilarPhotoScanner: Sendable {

    /// 特征距离提供者（注入：测试用 Fake 距离矩阵；生产用 Vision 真实计算）。
    public protocol FeatureDistanceProviding: Sendable {
        /// nil = 任一侧特征提取失败（该对不参与并簇）。
        func distance(_ pathA: String, _ pathB: String) async -> Double?
    }

    /// Vision 真实实现（macOS 15+ 新 Vision API；旧系统 → nil 优雅降级）。
    public struct VisionFeatureProvider: FeatureDistanceProviding {
        public init() {}

        public func distance(_ pathA: String, _ pathB: String) async -> Double? {
            guard #available(macOS 15.0, *) else { return nil }
            guard let a = await Self.observation(path: pathA),
                  let b = await Self.observation(path: pathB) else { return nil }
            return try? a.distance(to: b)
        }

        @available(macOS 15.0, *)
        static func observation(path: String) async -> FeaturePrintObservation? {
            try? await GenerateImageFeaturePrintRequest()
                .perform(on: URL(fileURLWithPath: path))
        }
    }

    public struct PhotoItem: Sendable, Equatable {
        public let path: String
        public let sizeBytes: Int64
        public let pixelCount: Int
    }

    /// 聚类结果：keep = 建议保留（像素最高，平局取文件更大）；similar = 其余候选。
    public struct PhotoCluster: Sendable, Equatable {
        public let keep: PhotoItem
        public let similar: [PhotoItem]
    }

    private let provider: any FeatureDistanceProviding
    private let threshold: Double

    public init(
        provider: any FeatureDistanceProviding = VisionFeatureProvider(),
        threshold: Double = 0.28
    ) {
        self.provider = provider
        self.threshold = threshold
    }

    /// 扫描并聚类（≥2 成员才成簇；孤立文件不报）。
    public func scan(paths: [String]) async -> [PhotoCluster] {
        await cluster(paths: paths, itemOverride: nil)
    }

    /// 测试注入入口：绕过真实文件系统构造条目（生产路径不经此）。
    func scanForTesting(
        paths: [String], overrideItems: [String: PhotoItem]
    ) async -> [PhotoCluster] {
        await cluster(paths: paths, itemOverride: overrideItems)
    }

    private func cluster(
        paths: [String], itemOverride: [String: PhotoItem]?
    ) async -> [PhotoCluster] {
        let items: [PhotoItem]
        if let itemOverride {
            items = paths.compactMap { itemOverride[$0] }
        } else {
            items = paths.compactMap { Self.item(path: $0) }
        }
        guard items.count >= 2 else { return [] }

        var parent = Array(0..<items.count)
        func find(_ i: Int) -> Int {
            var root = i
            while parent[root] != root { root = parent[root] }
            var cursor = i
            while parent[cursor] != cursor {
                parent[cursor] = root
                cursor = parent[cursor]
            }
            return root
        }
        for i in 0..<items.count {
            for j in (i + 1)..<items.count where i != j {
                if let d = await provider.distance(items[i].path, items[j].path), d <= threshold {
                    parent[find(j)] = find(i)
                }
            }
        }

        var groups: [Int: [PhotoItem]] = [:]
        for (index, item) in items.enumerated() {
            groups[find(index), default: []].append(item)
        }
        return groups.values
            .filter { $0.count >= 2 }
            .map(Self.makeCluster)
            .sorted { $0.keep.path < $1.keep.path }
    }

    /// 簇内保留最佳：像素最高优先，平局取文件更大。
    static func makeCluster(_ group: [PhotoItem]) -> PhotoCluster {
        let sorted = group.sorted {
            ($0.pixelCount, $0.sizeBytes) > ($1.pixelCount, $1.sizeBytes)
        }
        return PhotoCluster(keep: sorted[0], similar: Array(sorted[1...]))
    }

    /// 构造条目（文件大小 + 像素数；图像不可解析 → pixelCount 0，仍可按大小比较）。
    static func item(path: String) -> PhotoItem? {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: path),
              let size = (attrs[.size] as? NSNumber)?.int64Value else { return nil }
        var pixelCount = 0
        if let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
            let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
            pixelCount = w * h
        }
        return PhotoItem(path: path, sizeBytes: size, pixelCount: pixelCount)
    }
}