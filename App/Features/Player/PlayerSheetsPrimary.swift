import DSCore
import DSDesignSystem
import DSPlayback
import DSStorage
import SwiftUI

/// 弹窗 3：倍速调节（1:1 复刻 v2.8：-0.05 / 大号倍速 / +0.05 + 连续滑块 + 4 列网格 8 档胶囊）
struct SpeedSheet: View {
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(AppSettingsStore.self) private var settings
    @Environment(DSBannerCoordinator.self) private var banner
    private let onDismiss: () -> Void
    private let presets: [Double] = [0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0]

    init(onDismiss: @escaping () -> Void) {
        self.onDismiss = onDismiss
    }

    private func applySpeed(_ raw: Double) {
        let snapped = min(3.0, max(0.5, (raw * 20.0).rounded() / 20.0))
        if abs(snapped - playback.playbackRate) > 0.001 {
            DSHaptics.selection()
        }
        playback.playbackRate = snapped
        settings.playbackRate = snapped
    }

    var body: some View {
        DSSheetScaffold(title: "播放倍速", banner: banner, onDismiss: onDismiss) {
            ScrollView {
                VStack(spacing: DSSpacing.s5) {
                    HStack(spacing: DSSpacing.s5) {
                        Button {
                            applySpeed(playback.playbackRate - 0.05)
                        } label: {
                            HStack(spacing: 2) {
                                Image(systemName: "minus")
                                Text("0.05")
                            }
                            .font(DSTypography.numericCaption.weight(.semibold))
                            .foregroundStyle(DSColors.inkPrimary)
                            .padding(.horizontal, DSSpacing.sm)
                            .frame(minHeight: 44)
                            .background(Capsule().fill(DSColors.surfaceCard))
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(playback.playbackRate <= 0.5)
                        .accessibilityLabel("减速 0.05 倍")

                        Text(PlayerSpeedFormatter.format(playback.playbackRate))
                            .font(DSTypography.bookTitleLarge.monospacedDigit())
                            .foregroundStyle(DSColors.accent)
                            .contentTransition(.numericText())
                            .frame(minWidth: 100)

                        Button {
                            applySpeed(playback.playbackRate + 0.05)
                        } label: {
                            HStack(spacing: 2) {
                                Image(systemName: "plus")
                                Text("0.05")
                            }
                            .font(DSTypography.numericCaption.weight(.semibold))
                            .foregroundStyle(DSColors.inkPrimary)
                            .padding(.horizontal, DSSpacing.sm)
                            .frame(minHeight: 44)
                            .background(Capsule().fill(DSColors.surfaceCard))
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(playback.playbackRate >= 3.0)
                        .accessibilityLabel("加速 0.05 倍")
                    }

                    Slider(
                        value: Binding(
                            get: { playback.playbackRate },
                            set: { applySpeed($0) }
                        ),
                        in: 0.5...3.0,
                        step: 0.05
                    )
                    .tint(DSColors.accent)
                    .padding(.horizontal, DSSpacing.pageHorizontal)

                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: DSSpacing.xs), count: 4),
                        spacing: DSSpacing.xs
                    ) {
                        ForEach(presets, id: \.self) { rate in
                            let isSelected = abs(playback.playbackRate - rate) < 0.01
                            Button {
                                applySpeed(rate)
                            } label: {
                                Text(PlayerSpeedFormatter.format(rate))
                                    .font(DSTypography.numericCaption.weight(.semibold))
                                    .foregroundStyle(isSelected ? DSColors.onAccent : DSColors.inkPrimary)
                                    .frame(maxWidth: .infinity, minHeight: 44)
                                    .background(Capsule().fill(isSelected ? DSColors.accent : DSColors.surfaceCard))
                                    .contentShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, DSSpacing.pageHorizontal)
                }
                .padding(.vertical, DSSpacing.md)
            }
            .background(DSColors.surfaceGrouped)
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.medium, .large])
    }
}
