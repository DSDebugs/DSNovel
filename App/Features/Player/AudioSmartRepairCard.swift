import DSDesignSystem
import DSPlayback
import SwiftUI

/// AI 智能修音主卡（顶部独立模块：Pre-EQ 逐帧分析 + 可折叠单行实时微调条 + 三档介入强度）
struct AudioSmartRepairCard: View {
    @Environment(\.dsEffectiveReduceMotion) private var reduceMotion
    let dsp: AudioTapDSP
    let disabled: Bool

    var body: some View {
        let isEnabled = dsp.smartRepairEnabled
        let telemetry = dsp.smartTelemetry

        VStack(alignment: .leading, spacing: DSSpacing.sm) {
            HStack(spacing: DSSpacing.xs) {
                Image(systemName: "sparkles")
                    .font(DSTypography.subheadline.weight(.semibold))
                    .foregroundStyle(isEnabled ? DSColors.accent : DSColors.inkSecondary)

                Text("AI 智能修音")
                    .font(DSTypography.cardTitle)
                    .foregroundStyle(DSColors.inkPrimary)

                Spacer(minLength: 8)

                Toggle("", isOn: Binding(
                    get: { dsp.smartRepairEnabled },
                    set: { next in
                        DSHaptics.selection()
                        dsp.smartRepairEnabled = next
                    }
                ))
                .labelsHidden()
                .tint(DSColors.accent)
                .accessibilityLabel("开关 AI 智能修音")
            }

            Text(isEnabled ? "逐帧分析原始干声频谱 · 自动去闷、抑齿音，与下方风格叠加" : "开启后逐帧自动去闷、抑齿音、提亮人声")
                .font(DSTypography.caption2)
                .foregroundStyle(DSColors.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if isEnabled {
                telemetryStrip(telemetry: telemetry)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                intensityPicker
                    .transition(.opacity)
            }
        }
        .padding(DSSpacing.sm)
        .background(
            RoundedRectangle(cornerRadius: DSRadius.card, style: .continuous)
                .fill(DSColors.surfaceCard)
                .overlay(
                    RoundedRectangle(cornerRadius: DSRadius.card, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.07), lineWidth: 0.6)
                )
        )
        .animation(DSMotion.resolved(DSMotion.snappy, reduceMotion: reduceMotion), value: isEnabled)
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1)
    }

    private func telemetryStrip(telemetry: AudioSmartTelemetry) -> some View {
        HStack(spacing: DSSpacing.xs) {
            HStack(spacing: 5) {
                Circle()
                    .fill(telemetry.isAnalyzing ? DSColors.accent : DSColors.inkSecondary.opacity(0.45))
                    .frame(width: 6, height: 6)
                Text(telemetry.isAnalyzing ? "实时微调" : "等待人声")
                    .font(DSTypography.caption2.weight(.medium))
                    .foregroundStyle(telemetry.isAnalyzing ? DSColors.inkPrimary : DSColors.inkSecondary)
            }

            Spacer(minLength: 4)

            HStack(spacing: DSSpacing.xs) {
                metricLabel(title: "去闷", value: telemetry.mudDB)
                metricLabel(title: "人声", value: telemetry.voiceDB)
                metricLabel(title: "齿音", value: telemetry.sibilanceDB)
            }
        }
        .padding(.horizontal, DSSpacing.sm)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: DSRadius.input, style: .continuous)
                .fill(Color.black.opacity(0.28))
        )
    }

    private func metricLabel(title: String, value: Float) -> some View {
        let isActive = abs(value) >= 0.1
        return HStack(spacing: 2) {
            Text(title)
                .font(DSTypography.caption2)
                .foregroundStyle(DSColors.inkSecondary)
            Text(String(format: "%+.1f", value))
                .font(DSTypography.numericCaption.weight(.medium))
                .foregroundStyle(isActive ? DSColors.accent : DSColors.inkSecondary)
        }
    }

    private var intensityPicker: some View {
        HStack(spacing: 4) {
            ForEach(AudioSmartIntensity.allCases) { level in
                let isSelected = dsp.smartRepairIntensity == level
                Button {
                    DSHaptics.selection()
                    dsp.smartRepairIntensity = level
                } label: {
                    Text(level.title)
                        .font(DSTypography.caption.weight(isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? DSColors.accent : DSColors.inkSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: DSRadius.input - 2, style: .continuous)
                                .fill(isSelected ? Color.white.opacity(0.09) : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("智能修音强度 \(level.title)")
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: DSRadius.input, style: .continuous)
                .fill(Color.black.opacity(0.28))
        )
    }
}
