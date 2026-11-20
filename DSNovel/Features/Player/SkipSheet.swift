import SwiftUI

struct SkipSheet: View {
    @Bindable var player: PlayerEngine
    @State private var draftConfig: BookSkipConfig
    @State private var saveErrorMessage: String?
    private let onClose: () -> Void

    init(player: PlayerEngine = .shared, onClose: @escaping () -> Void) {
        self.player = player
        self._draftConfig = State(initialValue: player.bookSkip)
        self.onClose = onClose
    }

    private var bookTitle: String {
        let title = player.currentBook?.title ?? ""
        return title.isEmpty ? "当前书籍" : title
    }

    private var canUseCurrentPositionForIntro: Bool {
        let sec = Int(player.clock.currentTimeSec.rounded())
        return sec >= 0 && sec <= BookSkipConfig.maxSkipSec
    }

    private var canUseCurrentPositionForOutro: Bool {
        let dur = player.clock.durationSec
        let pos = player.clock.currentTimeSec
        guard dur.isFinite, dur > 0, pos.isFinite else { return false }
        let remaining = Int((dur - pos).rounded())
        return remaining >= 0 && remaining <= BookSkipConfig.maxSkipSec
    }

    private func snapToStep(_ rawSeconds: Int) -> Int {
        let clamped = BookSkipConfig.clamp(rawSeconds)
        let step = BookSkipConfig.stepSec
        return BookSkipConfig.clamp(((clamped + step / 2) / step) * step)
    }

    private func commitConfig(_ next: BookSkipConfig) {
        let normalized = next.normalized
        let previous = draftConfig
        draftConfig = normalized
        if !player.updateBookSkip(normalized) {
            draftConfig = previous
            saveErrorMessage = "保存失败，已恢复原设置"
            DSHapticPolicy.fire(.error)
        } else {
            saveErrorMessage = nil
        }
    }

    var body: some View {
        DSSheetScaffold(title: "跳过片头片尾", onClose: onClose) {
            ScrollView {
                VStack(spacing: Spacing.s4) {
                    headerCard
                    toggleCard
                    skipCard(
                        title: "跳过片头",
                        icon: "forward.frame",
                        seconds: Binding(
                            get: { Double(draftConfig.introSec) },
                            set: { newVal in
                                let snapped = snapToStep(Int(newVal.rounded()))
                                if snapped != draftConfig.introSec {
                                    draftConfig.introSec = snapped
                                    DSHapticPolicy.fire(.selection)
                                }
                            }
                        ),
                        canUseCurrentPosition: canUseCurrentPositionForIntro,
                        onSelectPreset: { preset in
                            DSHapticPolicy.fire(.selection)
                            var next = draftConfig
                            next.introSec = preset
                            commitConfig(next)
                        },
                        onUseCurrentPosition: {
                            let snapped = snapToStep(Int(player.clock.currentTimeSec.rounded()))
                            DSHapticPolicy.fire(.selection)
                            var next = draftConfig
                            next.introSec = snapped
                            commitConfig(next)
                        }
                    )
                    skipCard(
                        title: "跳过片尾",
                        icon: "forward.end.alt",
                        seconds: Binding(
                            get: { Double(draftConfig.outroSec) },
                            set: { newVal in
                                let snapped = snapToStep(Int(newVal.rounded()))
                                if snapped != draftConfig.outroSec {
                                    draftConfig.outroSec = snapped
                                    DSHapticPolicy.fire(.selection)
                                }
                            }
                        ),
                        canUseCurrentPosition: canUseCurrentPositionForOutro,
                        onSelectPreset: { preset in
                            DSHapticPolicy.fire(.selection)
                            var next = draftConfig
                            next.outroSec = preset
                            commitConfig(next)
                        },
                        onUseCurrentPosition: {
                            let remaining = Int((player.clock.durationSec - player.clock.currentTimeSec).rounded())
                            let snapped = snapToStep(remaining)
                            DSHapticPolicy.fire(.selection)
                            var next = draftConfig
                            next.outroSec = snapped
                            commitConfig(next)
                        }
                    )

                    if let saveErrorMessage {
                        Text(saveErrorMessage)
                            .font(DSTypography.caption)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    footerCard
                }
                .padding(.horizontal, Spacing.pageHorizontal)
                .padding(.vertical, Spacing.s4)
            }
            .background(Color.dsSurfaceGrouped)
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.medium, .large])
        .onAppear {
            draftConfig = player.bookSkip
        }
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(bookTitle)
                .font(DSTypography.cardTitle)
                .foregroundStyle(.primary)
                .lineLimit(1)
            Text("仅对本书生效，不影响其它书")
                .font(DSTypography.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var toggleCard: some View {
        HStack(spacing: Spacing.s3) {
            VStack(alignment: .leading, spacing: 2) {
                Text("跳过片头片尾")
                    .font(DSTypography.body.weight(.medium))
                    .foregroundStyle(.primary)
                Text(draftConfig.summaryText)
                    .font(DSTypography.caption)
                    .foregroundStyle(draftConfig.state == .on ? Color.dsAccent : .secondary)
            }
            Spacer()
            Toggle(
                "跳过片头片尾",
                isOn: Binding(
                    get: { draftConfig.enabled },
                    set: { isOn in
                        DSHapticPolicy.fire(.selection)
                        commitConfig(draftConfig.toggled(to: isOn))
                    }
                )
            )
            .labelsHidden()
            .tint(Color.dsAccent)
        }
        .padding(Spacing.s4)
        .background(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .fill(Color.dsSurfaceCard)
        )
    }

    private func skipCard(
        title: String,
        icon: String,
        seconds: Binding<Double>,
        canUseCurrentPosition: Bool,
        onSelectPreset: @escaping (Int) -> Void,
        onUseCurrentPosition: @escaping () -> Void
    ) -> some View {
        let currentSec = Int(seconds.wrappedValue.rounded())
        let isEnabled = draftConfig.enabled
        return VStack(alignment: .leading, spacing: Spacing.s3) {
            HStack {
                Label(title, systemImage: icon)
                    .font(DSTypography.cardTitle)
                    .foregroundStyle(.primary)
                Spacer()
                Text(currentSec == 0 ? "关闭" : "\(currentSec) 秒")
                    .font(DSTypography.bookTitleMedium.monospacedDigit())
                    .foregroundStyle(isEnabled && currentSec > 0 ? Color.dsAccent : .secondary)
                    .contentTransition(.numericText())
            }

            Slider(
                value: seconds,
                in: 0...Double(BookSkipConfig.maxSkipSec),
                step: Double(BookSkipConfig.stepSec),
                onEditingChanged: { editing in
                    if !editing {
                        commitConfig(draftConfig)
                    }
                }
            )
            .tint(Color.dsAccent)
            .accessibilityLabel(title)
            .accessibilityValue(currentSec == 0 ? "关闭" : "\(currentSec) 秒")

            HStack(spacing: Spacing.s1) {
                ForEach(BookSkipConfig.quickPresetSeconds, id: \.self) { preset in
                    let isSelected = currentSec == preset
                    Button {
                        onSelectPreset(preset)
                    } label: {
                        Text(preset == 0 ? "关" : "\(preset)")
                            .font(DSTypography.numericCaption.weight(.semibold))
                            .foregroundStyle(isSelected && isEnabled ? Color.dsOnAccent : .primary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(
                                Capsule().fill(isSelected && isEnabled ? Color.dsAccent : Color.dsSurfaceGrouped)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(preset == 0 ? "关闭\(title)" : "设为 \(preset) 秒")
                }
            }

            Button(action: onUseCurrentPosition) {
                HStack(spacing: 4) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(DSTypography.caption)
                    Text("用当前位置")
                        .font(DSTypography.caption.weight(.medium))
                }
                .foregroundStyle(canUseCurrentPosition && isEnabled ? Color.dsAccent : .secondary)
                .padding(.horizontal, Spacing.s3)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.dsSurfaceGrouped))
            }
            .buttonStyle(.plain)
            .disabled(!canUseCurrentPosition || !isEnabled)
        }
        .padding(Spacing.s4)
        .background(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .fill(Color.dsSurfaceCard)
        )
        .opacity(isEnabled ? 1.0 : 0.55)
        .disabled(!isEnabled)
    }

    private var footerCard: some View {
        VStack(alignment: .leading, spacing: Spacing.s3) {
            Text("设置将自动保存于本书。片头改动对下一次切章或重新播放生效；片尾改动对当前章即时生效（手动拖入片尾回听时本章不再自动跳过）。")
                .font(DSTypography.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if draftConfig.state != .unset {
                Button(role: .destructive) {
                    DSHapticPolicy.fire(.selection)
                    commitConfig(.unset)
                } label: {
                    Text("恢复本书默认")
                        .font(DSTypography.subtitle.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Spacing.s2)
                        .background(
                            RoundedRectangle(cornerRadius: Radius.input, style: .continuous)
                                .fill(Color.dsSurfaceCard)
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }
}
