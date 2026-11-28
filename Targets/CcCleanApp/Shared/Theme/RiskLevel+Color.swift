import SwiftUI
import CcCleanFS

/// 风险等级 → 语义色（绿/黄/红；智能扫描页与专清页共用）。
extension RiskLevel {
    var semanticColor: Color {
        switch self {
        case .low: .green
        case .medium: .yellow
        case .high: .red
        }
    }
}