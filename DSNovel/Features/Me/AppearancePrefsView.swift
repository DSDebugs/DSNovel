import SwiftUI

struct AppearancePrefsView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Bindable var settings: AppSettingsStore

    init(settings: AppSettingsStore = .shared) {
        self.settings = settings
    }

    private var isEffectiveDarkMode: Bool {
        switch settings.appearanceMode {
        case .dark: return true
        case .light: return false
        case .system: return colorScheme == .dark
        }
    }

    var body: some View {
        Group {
            Picker("外观模式", selection: $settings.appearanceMode) {
                ForEach(AppAppearanceMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .listRowBackground(Color.dsSurfaceCard)

            HStack(spacing: Spacing.s3) {
                iconBadge("moon.stars")
                VStack(alignment: .leading, spacing: 2) {
                    Text("夜间降亮")
                        .font(DSTypography.body)
                        .foregroundStyle(isEffectiveDarkMode ? .primary : .secondary)
                    Text("仅在深色外观下生效")
                        .font(DSTypography.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: Spacing.s2)
                Toggle("夜间降亮", isOn: $settings.nightDimEnabled)
                    .labelsHidden()
                    .tint(Color.dsAccent)
                    .disabled(!isEffectiveDarkMode)
            }
            .frame(minHeight: 44)
            .opacity(isEffectiveDarkMode ? 1.0 : 0.55)
            .listRowBackground(Color.dsSurfaceCard)

            HStack(spacing: Spacing.s3) {
                iconBadge("hand.tap")
                Toggle("触感反馈", isOn: $settings.hapticsEnabled)
                    .tint(Color.dsAccent)
                    .onChange(of: settings.hapticsEnabled) { oldValue, newValue in
                        if !oldValue && newValue {
                            DSHapticPolicy.fire(.selection)
                        }
                    }
            }
            .frame(minHeight: 44)
            .listRowBackground(Color.dsSurfaceCard)

            HStack(spacing: Spacing.s3) {
                iconBadge("sparkles.rectangle.stack")
                VStack(alignment: .leading, spacing: 2) {
                    Text("减少动态效果")
                        .font(DSTypography.body)
                        .foregroundStyle(.primary)
                    Text("开启后始终减弱；关闭则跟随系统")
                        .font(DSTypography.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: Spacing.s2)
                Toggle("减少动态效果", isOn: $settings.reduceMotionOverride)
                    .labelsHidden()
                    .tint(Color.dsAccent)
            }
            .frame(minHeight: 44)
            .listRowBackground(Color.dsSurfaceCard)
        }
    }

    private func iconBadge(_ name: String) -> some View {
        Image(systemName: name)
            .font(DSTypography.subtitle.weight(.semibold))
            .foregroundStyle(Color.dsAccent)
            .frame(width: 28, height: 28)
            .background(
                RoundedRectangle(cornerRadius: Radius.coverSmall, style: .continuous)
                    .fill(Color.dsAccent.opacity(0.10))
            )
            .accessibilityHidden(true)
    }
}
