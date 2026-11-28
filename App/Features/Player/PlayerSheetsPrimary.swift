import DSCore
import DSDesignSystem
import DSPlayback
import DSStorage
import SwiftUI

/// 弹窗 3：倍速调节（统一暗色卡片风格：读数微调卡 + 4×2 常用倍速网格卡）
struct SpeedSheet: View {
    @Environment(\.dsEffectiveReduceMotion) private var reduceMotion
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(AppSettingsStore.self) private var settings
    @Environment(DSBannerCoordinator.self) private var banner
    @State private var sliderDraftRate: Double?
    @State private var applyToCurrentBookOnly = false
    private let onDismiss: () -> Void
    private let presets: [Double] = [0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0]

    init(onDismiss: @escaping () -> Void) {
        self.onDismiss = onDismiss
    }

    private var gridColumns: [GridItem] {
        [
            GridItem(.flexible(), spacing: DSSpacing.xs),
            GridItem(.flexible(), spacing: DSSpacing.xs),
            GridItem(.flexible(), spacing: DSSpacing.xs),
            GridItem(.flexible(), spacing: DSSpacing.xs)
        ]
    }

    private var displayedRate: Double {
        sliderDraftRate ?? playback.playbackRate
    }

    private func snapSpeed(_ raw: Double) -> Double {
        min(3.0, max(0.5, (raw * 20.0).rounded() / 20.0))
    }

    private func applySpeed(_ raw: Double) {
        let snapped = snapSpeed(raw)
        sliderDraftRate = nil
        if abs(snapped - playback.playbackRate) > 0.001 {
            DSHaptics.selection()
        }
        playback.playbackRate = snapped
        if applyToCurrentBookOnly, let bookID = playback.currentBook?.id {
            settings.setBookPlaybackRate(snapped, forBookID: bookID)
        } else {
            if let bookID = playback.currentBook?.id {
                settings.setBookPlaybackRate(nil, forBookID: bookID)
            }
            settings.playbackRate = snapped
        }
    }

    var body: some View {
        DSSheetScaffold(title: "播放倍速", banner: banner, onDismiss: onDismiss) {
            ScrollView {
                VStack(alignment: .leading, spacing: DSSpacing.md) {
                    if playback.currentBook != nil {
                        scopePickerCard
                    }
                    stepperCard
                    presetsCard
                    bookPrefsSummaryStrip
                }
                .padding(.horizontal, DSSpacing.pageHorizontal)
                .padding(.vertical, DSSpacing.sm)
            }
            .background(DSColors.surfaceGrouped)
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.medium, .large])
        .onAppear {
            if let bookID = playback.currentBook?.id {
                applyToCurrentBookOnly = settings.hasBookPlaybackRate(forBookID: bookID)
            }
        }
    }

    private var scopePickerCard: some View {
        HStack(spacing: 4) {
            scopePill(title: "仅本书", isSelected: applyToCurrentBookOnly) {
                DSHaptics.selection()
                applyToCurrentBookOnly = true
                if let bookID = playback.currentBook?.id {
                    settings.setBookPlaybackRate(playback.playbackRate, forBookID: bookID)
                }
            }
            scopePill(title: "全部书籍", isSelected: !applyToCurrentBookOnly) {
                DSHaptics.selection()
                applyToCurrentBookOnly = false
                if let bookID = playback.currentBook?.id {
                    settings.setBookPlaybackRate(nil, forBookID: bookID)
                }
                settings.playbackRate = playback.playbackRate
            }
        }
        .padding(4)
        .background(
            Capsule(style: .continuous)
                .fill(DSColors.surfaceCard)
                .overlay(Capsule(style: .continuous).strokeBorder(Color.white.opacity(0.07), lineWidth: 0.6))
        )
    }

    private func scopePill(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(DSTypography.caption.weight(.semibold))
                .foregroundStyle(isSelected ? DSColors.onAccent : DSColors.inkSecondary)
                .frame(maxWidth: .infinity, minHeight: 34)
                .background(Capsule(style: .continuous).fill(isSelected ? DSColors.accent : Color.clear))
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var bookPrefsSummaryStrip: some View {
        let rateLabel = applyToCurrentBookOnly ? "本书独立倍速" : "跟随全局倍速"
        let skip = playback.bookSkipConfig
        let skipLabel = (skip.introSeconds > 0 || skip.outroSeconds > 0)
            ? " · 跳过片头 \(skip.introSeconds)s / 片尾 \(skip.outroSeconds)s"
            : ""
        return Text("\(rateLabel)\(skipLabel)")
            .font(DSTypography.caption2.monospacedDigit())
            .foregroundStyle(DSColors.inkSecondary)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    private var stepperCard: some View {
        VStack(spacing: DSSpacing.md) {
            HStack(spacing: DSSpacing.md) {
                Button {
                    applySpeed(displayedRate - 0.05)
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "minus")
                        Text("0.05")
                    }
                    .font(DSTypography.numericCaption.weight(.semibold))
                    .foregroundStyle(displayedRate <= 0.5 ? DSColors.inkSecondary : DSColors.inkPrimary)
                    .padding(.horizontal, DSSpacing.sm)
                    .frame(minHeight: 40)
                    .background(Capsule().fill(DSColors.surfaceGrouped))
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(displayedRate <= 0.5)
                .accessibilityLabel("减速 0.05 倍")

                Spacer(minLength: 4)

                Text(PlayerSpeedFormatter.format(displayedRate))
                    .font(DSTypography.bookTitleLarge.monospacedDigit())
                    .foregroundStyle(DSColors.accent)
                    .contentTransition(reduceMotion ? .identity : .numericText())

                Spacer(minLength: 4)

                Button {
                    applySpeed(displayedRate + 0.05)
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "plus")
                        Text("0.05")
                    }
                    .font(DSTypography.numericCaption.weight(.semibold))
                    .foregroundStyle(displayedRate >= 3.0 ? DSColors.inkSecondary : DSColors.inkPrimary)
                    .padding(.horizontal, DSSpacing.sm)
                    .frame(minHeight: 40)
                    .background(Capsule().fill(DSColors.surfaceGrouped))
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(displayedRate >= 3.0)
                .accessibilityLabel("加速 0.05 倍")
            }

            VStack(spacing: 4) {
                Slider(
                    value: Binding(
                        get: { displayedRate },
                        set: { newValue in
                            let snapped = snapSpeed(newValue)
                            if abs(snapped - displayedRate) > 0.001 {
                                DSHaptics.selection()
                            }
                            sliderDraftRate = snapped
                        }
                    ),
                    in: 0.5...3.0,
                    step: 0.05,
                    onEditingChanged: { editing in
                        if !editing, let pending = sliderDraftRate {
                            applySpeed(pending)
                        }
                    }
                )
                .tint(DSColors.accent)

                HStack {
                    Text("0.5x")
                    Spacer()
                    Text("1.0x")
                    Spacer()
                    Text("3.0x")
                }
                .font(DSTypography.caption2.monospacedDigit())
                .foregroundStyle(DSColors.inkSecondary)
            }
        }
        .padding(DSSpacing.md)
        .background(cardBackground)
    }

    private var presetsCard: some View {
        VStack(alignment: .leading, spacing: DSSpacing.sm) {
            HStack {
                Label("常用倍速", systemImage: "speedometer")
                    .font(DSTypography.cardTitle)
                    .foregroundStyle(DSColors.inkPrimary)
                Spacer()
                if abs(displayedRate - 1.0) > 0.01 {
                    Button {
                        applySpeed(1.0)
                    } label: {
                        Text("恢复原速")
                            .font(DSTypography.caption.weight(.medium))
                            .foregroundStyle(DSColors.accent)
                    }
                    .buttonStyle(.plain)
                }
            }

            LazyVGrid(columns: gridColumns, spacing: DSSpacing.xs) {
                ForEach(presets, id: \.self) { rate in
                    let isSelected = abs(displayedRate - rate) < 0.01
                    Button {
                        applySpeed(rate)
                    } label: {
                        Text(PlayerSpeedFormatter.format(rate))
                            .font(DSTypography.numericCaption.weight(.semibold))
                            .foregroundStyle(isSelected ? DSColors.onAccent : DSColors.inkPrimary)
                            .frame(maxWidth: .infinity, minHeight: 42)
                            .background(
                                RoundedRectangle(cornerRadius: DSRadius.input, style: .continuous)
                                    .fill(isSelected ? DSColors.accent : DSColors.surfaceGrouped)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: DSRadius.input, style: .continuous)
                                    .strokeBorder(
                                        isSelected ? Color.clear : Color.white.opacity(0.06),
                                        lineWidth: 0.5
                                    )
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(DSSpacing.md)
        .background(cardBackground)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: DSRadius.card, style: .continuous)
            .fill(DSColors.surfaceCard)
            .overlay(
                RoundedRectangle(cornerRadius: DSRadius.card, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5)
            )
    }
}
