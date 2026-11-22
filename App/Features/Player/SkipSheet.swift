import DSCore
import DSDesignSystem
import DSPlayback
import SwiftUI

/// 弹窗 4：单本跳过片头/片尾（1:1 复刻 v2.8：空态保护 + 0–600s 滑块 + 快捷预设胶囊 + 用当前位置 + 恢复默认）
struct SkipSheet: View {
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(DSBannerCoordinator.self) private var banner
    private let onDismiss: () -> Void
    private let quickPresets = [0, 15, 30, 45, 60, 90, 120]

    @State private var introSec: Int = 0
    @State private var outroSec: Int = 0
    @State private var hasUserEdited = false
    @State private var boundBookID: String?

    init(onDismiss: @escaping () -> Void) {
        self.onDismiss = onDismiss
    }

    private func snap(_ raw: Int) -> Int {
        let clamped = max(0, min(600, raw))
        return max(0, min(600, ((clamped + 2) / 5) * 5))
    }

    private func commit() {
        guard let currentBookID = playback.currentBook?.id,
              boundBookID == nil || boundBookID == currentBookID else { return }
        playback.updateBookSkipConfig(SkipConfigDTO(introSeconds: introSec, outroSeconds: outroSec))
    }

    var body: some View {
        let hasNoBook = (playback.currentBook == nil)
        DSSheetScaffold(title: "跳过片头片尾", banner: banner, onDismiss: onDismiss) {
            ScrollView {
                VStack(spacing: DSSpacing.md) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(playback.currentBook.map { BookTitleFormatter.cleanTitle($0.title) } ?? "未选择书籍")
                            .font(DSTypography.cardTitle)
                            .foregroundStyle(DSColors.inkPrimary)
                            .lineLimit(1)
                        Text(hasNoBook ? "请先选择书籍后再配置跳过片头片尾。" : "仅对本书生效，不影响其它书")
                            .font(DSTypography.caption)
                            .foregroundStyle(DSColors.inkSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    skipCard(
                        title: "跳过片头",
                        icon: "forward.frame",
                        isIntro: true,
                        seconds: introSec,
                        disabled: hasNoBook,
                        onSet: { val in
                            introSec = snap(val)
                            hasUserEdited = true
                            commit()
                        }
                    )

                    skipCard(
                        title: "跳过片尾",
                        icon: "forward.end.alt",
                        isIntro: false,
                        seconds: outroSec,
                        disabled: hasNoBook,
                        onSet: { val in
                            outroSec = snap(val)
                            hasUserEdited = true
                            commit()
                        }
                    )

                    if !hasNoBook && (introSec > 0 || outroSec > 0) {
                        Button(role: .destructive) {
                            DSHaptics.selection()
                            introSec = 0
                            outroSec = 0
                            hasUserEdited = true
                            commit()
                            banner.show("已恢复本书默认跳过设置", tone: .info)
                        } label: {
                            Text("恢复本书默认")
                                .font(DSTypography.subtitle.weight(.medium))
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .background(RoundedRectangle(cornerRadius: DSRadius.input, style: .continuous).fill(DSColors.surfaceCard))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, DSSpacing.pageHorizontal)
                .padding(.vertical, DSSpacing.md)
            }
            .background(DSColors.surfaceGrouped)
            .task(id: playback.currentBook?.id) {
                boundBookID = playback.currentBook?.id
                hasUserEdited = false
                introSec = playback.bookSkipConfig.introSeconds
                outroSec = playback.bookSkipConfig.outroSeconds
            }
            .onChange(of: playback.bookSkipConfig) { _, next in
                guard !hasUserEdited else { return }
                introSec = next.introSeconds
                outroSec = next.outroSeconds
            }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.medium, .large])
    }

    private func skipCard(
        title: String,
        icon: String,
        isIntro: Bool,
        seconds: Int,
        disabled: Bool,
        onSet: @escaping (Int) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: DSSpacing.sm) {
            HStack {
                Label(title, systemImage: icon)
                    .font(DSTypography.cardTitle)
                    .foregroundStyle(DSColors.inkPrimary)
                Spacer()
                Text(seconds == 0 ? "关闭" : "\(seconds) 秒")
                    .font(DSTypography.bookTitleMedium.monospacedDigit())
                    .foregroundStyle(seconds > 0 ? DSColors.accent : DSColors.inkSecondary)
                    .contentTransition(.numericText())
            }

            Slider(
                value: Binding(
                    get: { Double(seconds) },
                    set: { onSet(Int($0.rounded())) }
                ),
                in: 0...600,
                step: 5
            )
            .tint(DSColors.accent)

            HStack(spacing: DSSpacing.xxs) {
                ForEach(quickPresets, id: \.self) { preset in
                    let isSelected = (seconds == preset)
                    Button {
                        DSHaptics.selection()
                        onSet(preset)
                    } label: {
                        Text(preset == 0 ? "关" : "\(preset)")
                            .font(DSTypography.numericCaption.weight(.semibold))
                            .foregroundStyle(isSelected ? DSColors.onAccent : DSColors.inkPrimary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(isSelected ? DSColors.accent : DSColors.surfaceGrouped))
                    }
                    .buttonStyle(.plain)
                }
            }

            SkipCurrentPositionGrabButton(isIntro: isIntro, isDisabled: disabled, onApply: onSet)
        }
        .padding(DSSpacing.md)
        .background(RoundedRectangle(cornerRadius: DSRadius.card, style: .continuous).fill(DSColors.surfaceCard))
        .opacity(disabled ? 0.5 : 1)
        .disabled(disabled)
    }
}

private struct SkipCurrentPositionGrabButton: View {
    @Environment(PlaybackClock.self) private var clock
    let isIntro: Bool
    let isDisabled: Bool
    let onApply: (Int) -> Void

    private var capturedSeconds: Int? {
        if isIntro {
            guard clock.currentSeconds.isFinite else { return nil }
            return Int(clock.currentSeconds.rounded())
        }
        guard clock.durationSeconds.isFinite, clock.durationSeconds > 0, clock.currentSeconds.isFinite else { return nil }
        return Int((clock.durationSeconds - clock.currentSeconds).rounded())
    }

    var body: some View {
        let sec = capturedSeconds
        let valid = sec.map { $0 >= 0 && $0 <= 600 } ?? false
        Button {
            guard let sec, valid else { return }
            DSHaptics.selection()
            onApply(sec)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(DSTypography.caption)
                Text("用当前位置")
                    .font(DSTypography.caption.weight(.medium))
            }
            .foregroundStyle(valid && !isDisabled ? DSColors.accent : DSColors.inkSecondary)
            .padding(.horizontal, DSSpacing.sm)
            .padding(.vertical, 6)
            .background(Capsule().fill(DSColors.surfaceGrouped))
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!valid || isDisabled)
    }
}
