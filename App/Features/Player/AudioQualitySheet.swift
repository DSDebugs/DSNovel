import DSCore
import DSDesignSystem
import DSPlayback
import DSStorage
import SwiftUI

/// 弹窗 6：音质切换（实况输出状态条 + 圆角卡片单选，严格保留 v3.0 未解锁隐藏超清约束，无码率数字展示）
struct AudioQualitySheet: View {
    @Environment(AppContainer.self) private var container
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(AppSettingsStore.self) private var settings
    @Environment(DSBannerCoordinator.self) private var banner
    private let onDismiss: () -> Void

    init(onDismiss: @escaping () -> Void) {
        self.onDismiss = onDismiss
    }

    private var availableTiers: [AudioQualityTier] {
        AudioQualityTier.availableTiers(builtinParserUnlocked: container.canUseUltraHighQuality)
    }

    private var resolvedAutoTier: AudioQualityTier {
        AudioQualityTier.auto.resolved(isOnWiFi: playback.isOnWiFi, allowUltraHigh: container.canUseUltraHighQuality)
    }

    private var actualOutputLabel: String {
        let tierName: String
        if let stream = playback.activeStream {
            if stream.qualityTier == .auto {
                tierName = resolvedAutoTier.displayName
            } else {
                tierName = stream.qualityTier.displayName
            }
            return stream.url.isFileURL ? "离线 · \(tierName)" : tierName
        }
        return playback.preferredQuality.resolved(
            isOnWiFi: playback.isOnWiFi,
            allowUltraHigh: container.canUseUltraHighQuality
        ).displayName
    }

    var body: some View {
        DSSheetScaffold(title: "播放音质", banner: banner, onDismiss: onDismiss) {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 12) {
                    statusSummaryCard

                    VStack(spacing: 10) {
                        ForEach(availableTiers) { tier in
                            qualityOptionCard(for: tier)
                        }
                    }

                    Text("仅对当前书籍生效 · 离线章节下次在线时应用")
                        .font(DSTypography.caption2)
                        .foregroundStyle(DSColors.inkSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 4)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 20)
            }
            .background(DSColors.surfaceGrouped)
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.medium, .large])
    }

    private var statusSummaryCard: some View {
        HStack(spacing: 8) {
            Text("当前实际输出")
                .font(DSTypography.caption)
                .foregroundStyle(DSColors.inkSecondary)
            Spacer(minLength: 8)
            Text(actualOutputLabel)
                .font(DSTypography.subheadline.weight(.semibold))
                .foregroundStyle(DSColors.inkPrimary)
            if playback.activeStream?.isCappedFallback == true {
                Text("已降档")
                    .font(DSTypography.caption2.weight(.semibold))
                    .foregroundStyle(DSColors.warning)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(DSColors.warning.opacity(0.15)))
            }
            Text("|")
                .font(DSTypography.caption)
                .foregroundStyle(Color.white.opacity(0.22))
            HStack(spacing: 4) {
                Text(playback.isOnWiFi ? "Wi-Fi" : "蜂窝")
                    .font(DSTypography.caption.weight(.medium))
                    .foregroundStyle(DSColors.inkSecondary)
                Image(systemName: playback.isOnWiFi ? "wifi" : "antenna.radiowaves.left.and.right")
                    .font(DSTypography.caption)
                    .foregroundStyle(playback.isOnWiFi ? DSColors.success : DSColors.inkSecondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: DSRadius.input, style: .continuous)
                .fill(DSColors.surfaceCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DSRadius.input, style: .continuous)
                .strokeBorder(Color.white.opacity(0.06), lineWidth: 0.8)
        )
    }

    private func qualityOptionCard(for tier: AudioQualityTier) -> some View {
        let isSelected = playback.preferredQuality == tier
        return Button {
            DSHaptics.selection()
            if let bookID = playback.currentBook?.id {
                settings.setQuality(tier, forBookID: bookID)
            }
            if playback.activeStream?.url.isFileURL == true {
                playback.preferredQuality = tier
                banner.show("已保存音质「\(tier.displayName)」，当前为离线音频，下次在线播放生效", tone: .info)
            } else {
                playback.switchQuality(tier)
                banner.show("已切换音质为「\(tier.displayName)」", tone: .success)
            }
            onDismiss()
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text(tier.displayName)
                            .font(DSTypography.headline)
                            .foregroundStyle(DSColors.inkPrimary)
                        Text(tagText(for: tier))
                            .font(DSTypography.caption2.weight(.semibold))
                            .foregroundStyle(isSelected ? DSColors.accent : DSColors.inkSecondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(
                                Capsule().fill(isSelected ? DSColors.accent.opacity(0.18) : Color.white.opacity(0.08))
                            )
                    }
                    Text(subtitle(for: tier))
                        .font(DSTypography.caption)
                        .foregroundStyle(isSelected ? DSColors.accent.opacity(0.92) : DSColors.inkSecondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(DSTypography.title)
                        .foregroundStyle(DSColors.accent)
                } else {
                    Circle()
                        .strokeBorder(Color.white.opacity(0.18), lineWidth: 1.2)
                        .frame(width: 20, height: 20)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DSRadius.card, style: .continuous)
                    .fill(isSelected ? DSColors.accent.opacity(0.12) : DSColors.surfaceCard)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DSRadius.card, style: .continuous)
                    .strokeBorder(isSelected ? DSColors.accent : Color.white.opacity(0.06), lineWidth: isSelected ? 1.5 : 0.8)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func tagText(for tier: AudioQualityTier) -> String {
        switch tier {
        case .auto: return "智能"
        case .high: return "高解析"
        case .standard: return "均衡"
        case .saver: return "省流"
        }
    }

    private func subtitle(for tier: AudioQualityTier) -> String {
        switch tier {
        case .auto:
            return "\(tier.badgeLabel(allowUltraHigh: container.canUseUltraHighQuality)) · 当前匹配\(resolvedAutoTier.displayName)"
        case .high:
            return "高解析人声细节，适合 Wi-Fi 聆听"
        case .standard:
            return "清晰流畅，兼顾音质与流量"
        case .saver:
            return "极省流量，弱网环境首选"
        }
    }
}
