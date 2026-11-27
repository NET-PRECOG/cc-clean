import Foundation

/// FS 层测试 fixture（基线 13.1：temp 下构造临时目录树，
/// 含假 .app bundle、软链接、中文/空格/emoji 路径、大小写差异）。
enum FSTestFixture {

    struct Layout {
        let root: URL
        let fileA: URL          // 1000 字节文件
        let dirCJK: URL         // 中文+空格目录（内含 500 字节文件）
        let dirEmoji: URL       // emoji 目录
        let fakeAppBundle: URL  // 假 .app（Info.plist + 可执行文件）
        let symlink: URL        // 指向 fileA 的软链接
        let nestedDir: URL      // 嵌套 3 层目录
    }

    static func makeTree() throws -> Layout {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cclean-fs-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let fileA = root.appendingPathComponent("a.txt")
        try Data(repeating: 0x41, count: 1000).write(to: fileA)

        let dirCJK = root.appendingPathComponent("中文 目录")
        try FileManager.default.createDirectory(at: dirCJK, withIntermediateDirectories: true)
        try Data(repeating: 0x42, count: 500).write(to: dirCJK.appendingPathComponent("配置 文件.dat"))

        let dirEmoji = root.appendingPathComponent("🎉dir")
        try FileManager.default.createDirectory(at: dirEmoji, withIntermediateDirectories: true)
        try Data(repeating: 0x43, count: 100).write(to: dirEmoji.appendingPathComponent("x.bin"))

        // 假 .app bundle（下探行为测试目标）
        let fakeAppBundle = root.appendingPathComponent("Demo.app")
        let contents = fakeAppBundle.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(
            at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true
        )
        try Data(repeating: 0x44, count: 200).write(to: contents.appendingPathComponent("Demo"))
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>CFBundleIdentifier</key><string>com.example.demo</string>
        <key>CFBundleName</key><string>Demo</string>
        <key>CFBundleShortVersionString</key><string>1.2.3</string>
        </dict></plist>
        """.data(using: .utf8)!.write(to: contents.appendingPathComponent("Info.plist"))

        let symlink = root.appendingPathComponent("a-link")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: fileA)

        // 嵌套 3 层
        let nestedDir = root.appendingPathComponent("n1/n2/n3")
        try FileManager.default.createDirectory(at: nestedDir, withIntermediateDirectories: true)
        try Data(repeating: 0x45, count: 80).write(to: nestedDir.appendingPathComponent("deep.log"))

        return Layout(
            root: root, fileA: fileA, dirCJK: dirCJK, dirEmoji: dirEmoji,
            fakeAppBundle: fakeAppBundle, symlink: symlink, nestedDir: nestedDir
        )
    }

    static func remove(_ root: URL) {
        try? FileManager.default.removeItem(at: root)
    }

    /// 索引数据库（temp 隔离）。
    static func indexDBURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("cclean-fs-index-\(UUID().uuidString).sqlite")
    }
}