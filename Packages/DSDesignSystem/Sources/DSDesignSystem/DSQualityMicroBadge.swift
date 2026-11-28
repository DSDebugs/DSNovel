import DSCore
import SwiftUI

/// 轻量无框音质微标（超清用主题色淡底、高清/标准用中性灰淡底、自适应自动隐藏）
public struct DSQualityMicroBadge: View, Equatable {
    public let tier: AudioQualityTier

    public init(tier: AudioQualityTier) {
        self.tier = tier
    }

    public var body: some View {
        if tier != .auto {
            let isUltra = (tier == .high)
            Text(tier.displayName)
                .font(DSTypography.caption2.weight(.medium))
                .foregroundStyle(isUltra ? DSColors.accent : DSColors.inkSecondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(isUltra ? DSColors.accent.opacity(0.16) : DSColors.inkSecondary.opacity(0.16))
                )
                .fixedSize()
                .accessibilityLabel("音质 \(tier.displayName)")
        }
    }
}
