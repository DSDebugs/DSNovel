import DSCore
import DSDesignSystem
import DSPlayback
import DSStorage
import SwiftUI

/// 应用作者与动态版本信息
enum AuthorInfo {
    static let name = "DS"
    static let role = "设计与开发"
    static let copyrightText = "© 2026 DS"

    static var shortVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "3.3.9"
    }

    static var buildNumber: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "1"
    }

    static var appVersionDisplay: String {
        shortVersion
    }
}

/// 播放偏好页（规则 #17：严禁提供全局跳过片头片尾；精修圆角卡片 + 无竖线滑动胶囊条）
struct PlaybackPrefsView: View {
    @Environment(\.dsAccentTheme) private var accentTheme
    @Environment(\.dsEffectiveReduceMotion) private var reduceMotion
    @Environment(AppContainer.self) private var container
    @Environment(AppSettingsStore.self) private var settings

    @Namespace private var concurrentNamespace
    @Namespace private var precacheNamespace
    @Namespace private var rewindThresholdNamespace
    @Namespace private var rewindSecondsNamespace

    var body: some View {
        @Bindable var bindable = settings
        let _ = accentTheme

        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                sectionGroup(title: "连续播放") {
                    VStack(spacing: 0) {
                        toggleRow(
                            icon: "forward.end.fill",
                            title: "播完自动连播下一章",
                            subtitle: "当前章节结束时无缝衔接到下一章",
                            isOn: $bindable.autoPlayNextChapter
                        )

                        insetDivider

                        toggleRow(
                            icon: "play.circle.fill",
                            title: "启动时自动续播",
                            subtitle: "打开 App 时自动继续播放上次收听的书籍",
                            isOn: $bindable.autoPlayOnLaunch
                        )
                    }
                }

                sectionGroup(title: "离线与预缓存") {
                    VStack(spacing: 0) {
                        segmentedControlRow(
                            icon: "arrow.down.circle.fill",
                            title: "同时下载任务数",
                            badgeText: "\(settings.maxConcurrentDownloads) 项",
                            hint: "推荐 3 项，避免触发书源限流",
                            options: Array(1...6),
                            selection: $bindable.maxConcurrentDownloads,
                            namespace: concurrentNamespace,
                            labelForOption: { "\($0)" }
                        )

                        insetDivider

                        segmentedControlRow(
                            icon: "bolt.circle.fill",
                            title: "自动预缓存后续章数",
                            badgeText: settings.precacheNextCount == 0 ? "关闭" : "\(settings.precacheNextCount) 章",
                            hint: "提前缓存后续章节，弱网或地铁听书更流畅",
                            options: Array(0...5),
                            selection: $bindable.precacheNextCount,
                            namespace: precacheNamespace,
                            labelForOption: { $0 == 0 ? "关闭" : "\($0)" }
                        )
                    }
                }

                sectionGroup(title: "智能暂停回退") {
                    VStack(spacing: 0) {
                        toggleRow(
                            icon: "gobackward.10",
                            title: "智能暂停回退",
                            subtitle: "暂停超阈值恢复播放时自动回退衔接剧情",
                            isOn: $bindable.smartRewindEnabled
                        )

                        if settings.smartRewindEnabled {
                            insetDivider

                            segmentedControlRow(
                                icon: "clock.arrow.circlepath",
                                title: "触发暂停时长",
                                badgeText: "\(settings.smartRewindThresholdMinutes) 分钟",
                                hint: "仅在暂停超过该时长后恢复播放才回退",
                                options: AppSettingsStore.supportedSmartRewindThresholds,
                                selection: $bindable.smartRewindThresholdMinutes,
                                namespace: rewindThresholdNamespace,
                                labelForOption: { "\($0)分" }
                            )

                            insetDivider

                            segmentedControlRow(
                                icon: "arrow.counterclockwise",
                                title: "自动回退时长",
                                badgeText: "\(settings.smartRewindSeconds) 秒",
                                hint: "不与睡眠定时回退叠加，绝不回退进片头",
                                options: AppSettingsStore.supportedSmartRewindSeconds,
                                selection: $bindable.smartRewindSeconds,
                                namespace: rewindSecondsNamespace,
                                labelForOption: { "\($0)秒" }
                            )
                        }
                    }
                }
            }
            .padding(.horizontal, DSSpacing.pageHorizontal)
            .padding(.top, DSSpacing.sm)
            .padding(.bottom, DSSpacing.xl)
        }
        .background(DSColors.surfaceBase)
        .navigationTitle("播放偏好")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: settings.autoPlayNextChapter) { _, _ in container.syncSettingsToEngines() }
        .onChange(of: settings.maxConcurrentDownloads) { _, _ in container.syncSettingsToEngines() }
        .onChange(of: settings.precacheNextCount) { _, _ in container.syncSettingsToEngines() }
        .onChange(of: settings.smartRewindEnabled) { _, _ in container.syncSettingsToEngines() }
        .onChange(of: settings.smartRewindThresholdMinutes) { _, _ in container.syncSettingsToEngines() }
        .onChange(of: settings.smartRewindSeconds) { _, _ in container.syncSettingsToEngines() }
    }

    private func sectionGroup<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(DSTypography.footnote.weight(.medium))
                .foregroundStyle(DSColors.inkSecondary)
                .padding(.leading, 6)

            content()
                .background(
                    RoundedRectangle(cornerRadius: DSRadius.card, style: .continuous)
                        .fill(DSColors.surfaceCard)
                        .overlay(
                            RoundedRectangle(cornerRadius: DSRadius.card, style: .continuous)
                                .strokeBorder(DSColors.separator.opacity(0.28), lineWidth: 0.5)
                        )
                        .shadow(color: Color.black.opacity(0.035), radius: 8, y: 2)
                )
        }
    }

    private func toggleRow(
        icon: String,
        title: String,
        subtitle: String,
        isOn: Binding<Bool>
    ) -> some View {
        Toggle(isOn: isOn) {
            HStack(spacing: DSSpacing.sm) {
                rowBadgeIcon(icon)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(DSTypography.subheadline.weight(.medium))
                        .foregroundStyle(DSColors.inkPrimary)
                    Text(subtitle)
                        .font(DSTypography.caption)
                        .foregroundStyle(DSColors.inkSecondary)
                        .lineLimit(2)
                }
            }
        }
        .tint(DSColors.accent)
        .padding(.horizontal, DSSpacing.md)
        .padding(.vertical, 13)
    }

    private func segmentedControlRow<Option: Hashable>(
        icon: String,
        title: String,
        badgeText: String,
        hint: String,
        options: [Option],
        selection: Binding<Option>,
        namespace: Namespace.ID,
        labelForOption: @escaping (Option) -> String
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: DSSpacing.sm) {
                rowBadgeIcon(icon)
                Text(title)
                    .font(DSTypography.subheadline.weight(.medium))
                    .foregroundStyle(DSColors.inkPrimary)
                Spacer(minLength: 8)
                Text(badgeText)
                    .font(DSTypography.numericCaption.weight(.semibold))
                    .foregroundStyle(DSColors.accent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        Capsule(style: .continuous)
                            .fill(DSColors.accent.opacity(0.13))
                    )
            }

            HStack(spacing: 2) {
                ForEach(options, id: \.self) { opt in
                    let isSelected = (selection.wrappedValue == opt)
                    Button {
                        guard selection.wrappedValue != opt else { return }
                        DSHaptics.selection()
                        DSMotion.withResolved(DSMotion.snappy, reduceMotion: reduceMotion) {
                            selection.wrappedValue = opt
                        }
                    } label: {
                        Text(labelForOption(opt))
                            .font(DSTypography.numericFootnote.weight(isSelected ? .semibold : .regular))
                            .foregroundStyle(isSelected ? DSColors.onAccent : DSColors.inkSecondary)
                            .frame(maxWidth: .infinity, minHeight: 34)
                            .background {
                                if isSelected {
                                    Capsule(style: .continuous)
                                        .fill(DSColors.accent)
                                        .shadow(color: DSColors.accent.opacity(0.26), radius: 4, y: 1.5)
                                        .matchedGeometryEffect(id: "pill", in: namespace)
                                }
                            }
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(title) \(labelForOption(opt))")
                    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
                }
            }
            .padding(3)
            .background(
                Capsule(style: .continuous)
                    .fill(DSColors.surfaceGrouped)
            )
            .animation(DSMotion.resolved(DSMotion.snappy, reduceMotion: reduceMotion), value: selection.wrappedValue)

            Text(hint)
                .font(DSTypography.caption2)
                .foregroundStyle(DSColors.inkSecondary.opacity(0.85))
                .padding(.leading, 2)
        }
        .padding(.horizontal, DSSpacing.md)
        .padding(.vertical, 14)
    }

    private func rowBadgeIcon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(DSTypography.footnote.weight(.semibold))
            .foregroundStyle(DSColors.accent)
            .frame(width: 32, height: 32)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(DSColors.accent.opacity(0.14))
            )
            .accessibilityHidden(true)
    }

    private var insetDivider: some View {
        Divider()
            .overlay(DSColors.separator.opacity(0.28))
            .padding(.leading, 60)
    }
}
