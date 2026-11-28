import SwiftUI

/// 功能页共享玻璃表面：卡片底 + 氛围背景（各功能页消除逐页重复的样式样板）。

/// 卡片底（regularMaterial + 白描边）。
struct GlassCardBackground: View {
    var body: some View {
        RoundedRectangle(cornerRadius: CCleanTheme.cardCornerRadius, style: .continuous)
            .fill(.regularMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: CCleanTheme.cardCornerRadius, style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )
    }
}

/// 氛围背景（浅紫→灰渐变 + 暗色模式垫底）。
struct AmbientBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        LinearGradient(
            colors: [Color(hex: "F5F3FF"), Color(hex: "F9FAFB")],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
        .overlay {
            Color(nsColor: .windowBackgroundColor).opacity(colorScheme == .dark ? 0.92 : 0)
        }
        .ignoresSafeArea()
    }
}