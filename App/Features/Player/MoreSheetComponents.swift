import AVKit
import DSDesignSystem
import SwiftUI
import UIKit

/// AirPlay 音频输出路由选择器包装（单枚系统原生图标，避免双图标重复）
struct AirPlayRoutePickerRepresentable: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.prioritizesVideoDevices = false
        picker.tintColor = UIColor.white.withAlphaComponent(0.90)
        picker.activeTintColor = UIColor(DSColors.accent)
        return picker
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {
        uiView.tintColor = UIColor.white.withAlphaComponent(0.90)
        uiView.activeTintColor = UIColor(DSColors.accent)
    }
}

/// 更多播放设置 2×2 快捷控制磁贴（34pt 圆形微图标底衬 + 实时状态副标）
struct MoreQuickTile: View {
    let icon: String
    let title: String
    let subtitle: String
    let isActive: Bool
    let disabled: Bool
    private let action: () -> Void

    init(
        icon: String,
        title: String,
        subtitle: String,
        isActive: Bool,
        disabled: Bool,
        action: @escaping () -> Void
    ) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.isActive = isActive
        self.disabled = disabled
        self.action = action
    }

    var body: some View {
        Button {
            DSHaptics.selection()
            action()
        } label: {
            HStack(spacing: DSSpacing.sm) {
                Image(systemName: icon)
                    .font(DSTypography.callout.weight(.semibold))
                    .foregroundStyle(isActive ? DSColors.accent : DSColors.inkPrimary.opacity(0.90))
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(isActive ? DSColors.accent.opacity(0.18) : Color.white.opacity(0.08)))

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(DSTypography.subheadline.weight(.semibold))
                        .foregroundStyle(DSColors.inkPrimary)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(DSTypography.caption2)
                        .foregroundStyle(isActive ? DSColors.accent : DSColors.inkSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DSSpacing.sm)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 62)
            .background(
                RoundedRectangle(cornerRadius: DSRadius.card, style: .continuous)
                    .fill(isActive ? DSColors.accent.opacity(0.12) : DSColors.surfaceCard)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DSRadius.card, style: .continuous)
                    .strokeBorder(
                        isActive ? DSColors.accent.opacity(0.45) : DSColors.separator.opacity(0.24),
                        lineWidth: isActive ? 0.8 : 0.5
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1)
    }
}

/// 更多播放设置单卡内通用操作行（跳转行显 ›，即时动作行无冗余箭头）
struct MoreActionRow: View {
    let icon: String
    let title: String
    let badgeText: String?
    let trailingText: String?
    let showsChevron: Bool
    let disabled: Bool
    private let action: () -> Void

    init(
        icon: String,
        title: String,
        badgeText: String? = nil,
        trailingText: String? = nil,
        showsChevron: Bool,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) {
        self.icon = icon
        self.title = title
        self.badgeText = badgeText
        self.trailingText = trailingText
        self.showsChevron = showsChevron
        self.disabled = disabled
        self.action = action
    }

    var body: some View {
        Button {
            DSHaptics.selection()
            action()
        } label: {
            HStack(spacing: DSSpacing.sm) {
                Image(systemName: icon)
                    .font(DSTypography.callout)
                    .foregroundStyle(DSColors.inkPrimary.opacity(0.86))
                    .frame(width: 24, alignment: .center)

                Text(title)
                    .font(DSTypography.subheadline)
                    .foregroundStyle(DSColors.inkPrimary)
                    .lineLimit(1)

                Spacer(minLength: 8)

                if let badgeText, !badgeText.isEmpty {
                    Text(badgeText)
                        .font(DSTypography.caption2.weight(.semibold))
                        .foregroundStyle(DSColors.accent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(DSColors.accent.opacity(0.16)))
                }

                if let trailingText, !trailingText.isEmpty {
                    Text(trailingText)
                        .font(DSTypography.caption)
                        .foregroundStyle(DSColors.inkSecondary)
                        .lineLimit(1)
                }

                if showsChevron {
                    Image(systemName: "chevron.right")
                        .font(DSTypography.caption2.weight(.semibold))
                        .foregroundStyle(DSColors.inkSecondary.opacity(0.70))
                }
            }
            .padding(.horizontal, DSSpacing.md)
            .frame(minHeight: 50)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1)
    }
}
