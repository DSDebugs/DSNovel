import DSCore
import DSDesignSystem
import DSStorage
import SwiftUI

/// 外观卡片内「主题色」6 色圆形色块选择行
struct ThemeColorPickerRow: View {
    @Binding var selection: DSAccentTheme

    var body: some View {
        HStack(spacing: DSSpacing.sm) {
            Image(systemName: "paintpalette.fill")
                .font(DSTypography.footnote.weight(.semibold))
                .foregroundStyle(DSColors.inkSecondary)
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(DSColors.inkSecondary.opacity(0.12))
                )
                .accessibilityHidden(true)

            Text("主题色")
                .font(DSTypography.subheadline)
                .foregroundStyle(DSColors.inkPrimary)
                .lineLimit(1)

            Spacer(minLength: 6)

            HStack(spacing: 6) {
                ForEach(DSAccentTheme.allCases) { theme in
                    swatchButton(for: theme)
                }
            }
        }
        .padding(.horizontal, DSSpacing.md)
        .frame(minHeight: 56)
    }

    private func swatchButton(for theme: DSAccentTheme) -> some View {
        let isSelected = (selection == theme)
        let swatch = DSColors.accentSwatch(for: theme)
        return Button {
            DSHaptics.selection()
            DSColors.setAccentTheme(theme)
            selection = theme
        } label: {
            ZStack {
                Circle()
                    .fill(swatch)
                    .frame(width: 20, height: 20)
                if isSelected {
                    Circle()
                        .strokeBorder(swatch, lineWidth: 2)
                        .frame(width: 26, height: 26)
                }
            }
            .frame(width: 26, height: 26)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("me_accent_\(theme.rawValue)")
        .accessibilityLabel("主题色 \(theme.title)")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// 系统卡片内「启动默认页」书架 / 首页双段胶囊切换行
struct DefaultLaunchTabRow: View {
    @Environment(\.dsAccentTheme) private var accentTheme
    @Binding var selection: DSLaunchTab

    var body: some View {
        let _ = accentTheme
        HStack(spacing: DSSpacing.sm) {
            Image(systemName: "house.fill")
                .font(DSTypography.footnote.weight(.semibold))
                .foregroundStyle(DSColors.inkSecondary)
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(DSColors.inkSecondary.opacity(0.12))
                )
                .accessibilityHidden(true)

            Text("启动默认页")
                .font(DSTypography.subheadline)
                .foregroundStyle(DSColors.inkPrimary)

            Spacer(minLength: 8)

            HStack(spacing: 2) {
                ForEach(DSLaunchTab.allCases) { tab in
                    segmentButton(for: tab)
                }
            }
            .padding(3)
            .background(
                Capsule(style: .continuous)
                    .fill(DSColors.surfaceGrouped)
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(DSColors.separator.opacity(0.24), lineWidth: 0.5)
            )
        }
        .padding(.horizontal, DSSpacing.md)
        .frame(minHeight: 56)
    }

    private func segmentButton(for tab: DSLaunchTab) -> some View {
        let isSelected = (selection == tab)
        return Button {
            DSHaptics.selection()
            selection = tab
        } label: {
            Text(tab.title)
                .font(DSTypography.caption.weight(isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? DSColors.onAccent : DSColors.inkSecondary)
                .padding(.horizontal, 12)
                .frame(minHeight: 28)
                .background(
                    Capsule(style: .continuous)
                        .fill(isSelected ? DSColors.accent : Color.clear)
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("me_launch_tab_\(tab.rawValue)")
        .accessibilityLabel("默认启动到\(tab.title)")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}
