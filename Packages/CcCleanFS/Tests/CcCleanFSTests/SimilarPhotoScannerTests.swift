import Testing
import Foundation
@testable import CcCleanFS

@Suite("SimilarPhotoScanner (F4 相似照片聚类)")
struct SimilarPhotoScannerTests {

    /// 注入距离矩阵的 Fake（nil = 提取失败路径）。
    struct FakeProvider: SimilarPhotoScanner.FeatureDistanceProviding {
        let matrix: [String: [String: Double]]
        func distance(_ pathA: String, _ pathB: String) async -> Double? {
            matrix[pathA]?[pathB] ?? matrix[pathB]?[pathA]
        }
    }

    func item(_ name: String, pixels: Int, size: Int64) -> String {
        name   // Fake 场景路径即 key；条目属性由注入 item() 控制
    }

    @Test("聚类：A-B 距离 0.1 同簇（≤0.28），C 孤立不成簇；keep 取像素最高")
    func clustering() async {
        let a = "/photos/a.jpg", b = "/photos/b.jpg", c = "/photos/c.jpg"
        let provider = FakeProvider(matrix: [
            a: [b: 0.10, c: 0.90],
            b: [c: 0.90],
        ])
        let scanner = SimilarPhotoScanner(provider: provider, threshold: 0.28)

        // 注入条目属性：A 100px、B 900px（B 更大 → keep B）、C 孤立
        let items = [
            (a, 100, Int64(10)), (b, 900, Int64(20)), (c, 500, Int64(30)),
        ]
        let clusters = await scanWith(items: items, scanner: scanner)
        #expect(clusters.count == 1)
        #expect(clusters[0].keep.path == b)          // 像素最高保留
        #expect(clusters[0].similar.map(\.path) == [a])
        #expect(!clusters.contains { $0.keep.path == c })   // 孤立不报
    }

    @Test("距离恰为阈值 0.28 → 同簇；0.29 → 不同簇")
    func thresholdBoundary() async {
        let a = "/p/x1.jpg", b = "/p/x2.jpg"
        let tight = SimilarPhotoScanner(
            provider: FakeProvider(matrix: [a: [b: 0.28]]), threshold: 0.28)
        #expect(await scanWith(items: [(a, 1, 1), (b, 1, 1)], scanner: tight).count == 1)

        let loose = SimilarPhotoScanner(
            provider: FakeProvider(matrix: [a: [b: 0.29]]), threshold: 0.28)
        #expect(await scanWith(items: [(a, 1, 1), (b, 1, 1)], scanner: loose).isEmpty)
    }

    @Test("提取失败（distance nil）：该对不并簇，不误报")
    func extractionFailure() async {
        let a = "/p/f1.jpg", b = "/p/f2.jpg"
        let provider = FakeProvider(matrix: [:])   // 全 nil
        let scanner = SimilarPhotoScanner(provider: provider, threshold: 0.28)
        #expect(await scanWith(items: [(a, 1, 1), (b, 1, 1)], scanner: scanner).isEmpty)
    }

    @Test("makeCluster：像素平局 → 取文件更大者")
    func keepTieBreak() {
        let big1 = SimilarPhotoScanner.PhotoItem(path: "/p/big1", sizeBytes: 500, pixelCount: 100)
        let big2 = SimilarPhotoScanner.PhotoItem(path: "/p/big2", sizeBytes: 900, pixelCount: 100)
        let cluster = SimilarPhotoScanner.makeCluster([big1, big2])
        #expect(cluster.keep.path == "/p/big2")
        #expect(cluster.similar.first?.path == "/p/big1")
    }

    /// scan 但条目属性由注入列表控制（绕过真实文件系统）。
    func scanWith(
        items: [(path: String, pixels: Int, size: Int64)],
        scanner: SimilarPhotoScanner
    ) async -> [SimilarPhotoScanner.PhotoCluster] {
        let paths = items.map(\.path)
        let itemMap = Dictionary(uniqueKeysWithValues: items.map {
            ($0.path, SimilarPhotoScanner.PhotoItem(
                path: $0.path, sizeBytes: $0.size, pixelCount: $0.pixels))
        })
        // 直接复用 scan 的聚类逻辑需要真实文件——注入层改为测试专用入口：
        // 走 scan() 前用 hook 注入 item 映射（生产路径不经此）
        return await scanner.scanForTesting(paths: paths, overrideItems: itemMap)
    }
}