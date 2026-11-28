import Foundation

/// CChar 缓冲区（含 null 终止符）→ UTF8 字符串。
/// 替代已废弃的 `String(cString:)` 数组版（macOS 26 起 deprecated）。
extension Array where Element == CChar {
    func cStringDecoded() -> String {
        String(decoding: prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}