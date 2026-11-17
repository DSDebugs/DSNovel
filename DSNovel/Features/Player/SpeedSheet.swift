import SwiftUI

struct SpeedSheet: View {
    let player: PlayerEngine
    @State private var applyToCurrentBookOnly: Bool = AppSettingsStore.shared.rememberBookVolume
    private let onClose: () -> Void

    static let presets: [Double] = [0.75, 1.0, 1.25, 1.5, 2.0, 3.0]

    init(player: PlayerEngine = .shared, onClose: @escaping () -> Void) {
        self.player = player
        self.onClose = onClose
    }

    var body: some View {
        DSSheetScaffold(title: "播放倍速", onClose: onClose) {
            VStack(spacing: Spacing.s5) {
                Text(String(format: "%.2fx", player.speed))
                    .font(DSTypography.bookTitleLarge.monospacedDigit())
                    .foregroundStyle(Color.dsAccent)
                    .contentTransition(.numericText())

                Slider(
                    value: Binding(
                        get: { player.speed },
                        set: { newValue in
                            let old = player.speed
                            let snapped = PlayerEngine.snapSpeed(newValue)
                            if snapped != old {
                                DSHapticPolicy.fire(snapped > old ? .speedIncrease : .speedDecrease)
                                player.setSpeed(snapped, persist: applyToCurrentBookOnly)
                            }
                        }
                    ),
                    in: 0.5...3.0,
                    step: 0.05
                )
                .tint(Color.dsAccent)
                .padding(.horizontal, Spacing.pageHorizontal)

                HStack(spacing: Spacing.s2) {
                    ForEach(Self.presets, id: \.self) { preset in
                        let isSelected = abs(player.speed - preset) < 0.01
                        Button(String(format: "%.2gx", preset)) {
                            DSHapticPolicy.fire(preset >= player.speed ? .speedIncrease : .speedDecrease)
                            player.setSpeed(preset, persist: applyToCurrentBookOnly)
                        }
                        .font(DSTypography.numericCaption.weight(.semibold))
                        .foregroundStyle(isSelected ? Color.dsOnAccent : .primary)
                        .padding(.horizontal, Spacing.s3)
                        .padding(.vertical, Spacing.s2)
                        .background(
                            Capsule().fill(isSelected ? Color.dsAccent : Color.dsSurfaceGrouped)
                        )
                        .buttonStyle(.plain)
                    }
                }

                Toggle("仅对本书生效", isOn: $applyToCurrentBookOnly)
                    .padding(.horizontal, Spacing.pageHorizontal)

                Spacer()
            }
            .padding(.top, Spacing.s4)
        }
        .presentationDetents([.height(320)])
    }
}
