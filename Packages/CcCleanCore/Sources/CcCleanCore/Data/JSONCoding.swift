import Foundation

/// 统一 JSON 编解码工厂（iso8601 日期策略）。
/// XPC 载荷（Privileged）、操作日志（Ops）、诊断导出（Core）共用，避免各处重复设置策略。
public enum JSONCoding {

    /// iso8601 日期编码器；prettyPrinted = true 时附加 [.prettyPrinted, .sortedKeys]（导出/落盘场景）。
    public static func encoder(prettyPrinted: Bool = false) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if prettyPrinted {
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        }
        return encoder
    }

    /// iso8601 日期解码器（与 encoder() 严格配对）。
    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}