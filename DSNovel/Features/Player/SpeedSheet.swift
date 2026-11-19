import SwiftUI

struct SpeedSheet: View {
    let player: PlayerEngine
    @State private var alsoSetDefault: Bool = false
    private let onClose: () -> Void

    static let presets: [Double] = [0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0]

    init(player: PlayerEngine = .shared, onClose: @escaping () -> Void) {
        self.player = player
        self.onClose = onClose
    }

    private func applySpeed(_ target: Double, persist: Bool = true) {
        let clamped = PlayerEngine.snapSpeed(target)
        let old = player.speed
        if abs(clamped - old) > 0.001 {
            DSHapticPolicy.fire(clamped >= old ? .speedIncrease : .speedDecrease)
        }
        if persist {
            player.setSpeed(clamped, persist: true, alsoSetDefault: alsoSetDefault)
        } else {
            player.speed = clamped
        }
    }

    var body: some View {
        DSSheetScaffold(title: "播放倍速", onClose: onClose) {
            ScrollView {
                VStack(spacing: Spacing.s5) {
                    HStack(spacing: Spacing.s5) {
                        Button {
                            applySpeed(player.speed - 0.05)
                        } label: {
                            HStack(spacing: 2) {
                                Image(systemName: "minus")
                                Text("0.05")
                            }
                            .font(DSTypography.numericCaption.weight(.semibold))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, Spacing.s3)
                            .padding(.vertical, Spacing.s2)
                            .background(Capsule().fill(Color.dsSurfaceCard))
                        }
                        .buttonStyle(.plain)
                        .disabled(player.speed <= 0.5)
                        .accessibilityLabel("减速 0.05 倍")

                        Text(PlayerSpeedFormatter.format(player.speed))
                            .font(DSTypography.bookTitleLarge.monospacedDigit())
                            .foregroundStyle(Color.dsAccent)
                            .contentTransition(.numericText())
                            .frame(minWidth: 100)

                        Button {
                            applySpeed(player.speed + 0.05)
                        } label: {
                            HStack(spacing: 2) {
                                Image(systemName: "plus")
                                Text("0.05")
                            }
                            .font(DSTypography.numericCaption.weight(.semibold))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, Spacing.s3)
                            .padding(.vertical, Spacing.s2)
                            .background(Capsule().fill(Color.dsSurfaceCard))
                        }
                        .buttonStyle(.plain)
                        .disabled(player.speed >= 3.0)
                        .accessibilityLabel("加速 0.05 倍")
                    }

                    Slider(
                        value: Binding(
                            get: { player.speed },
                            set: { newValue in
                                applySpeed(newValue, persist: false)
                            }
                        ),
                        in: 0.5...3.0,
                        step: 0.05,
                        onEditingChanged: { editing in
                            if !editing {
                                player.setSpeed(player.speed, persist: true, alsoSetDefault: alsoSetDefault)
                            }
                        }
                    )
                    .tint(Color.dsAccent)
                    .padding(.horizontal, Spacing.pageHorizontal)

                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: Spacing.s2), count: 4),
                        spacing: Spacing.s2
                    ) {
                        ForEach(Self.presets, id: \.self) { preset in
                            let isSelected = abs(player.speed - preset) < 0.01
                            Button {
                                applySpeed(preset)
                            } label: {
                                Text(PlayerSpeedFormatter.format(preset))
                                    .font(DSTypography.numericCaption.weight(.semibold))
                                    .foregroundStyle(isSelected ? Color.dsOnAccent : .primary)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, Spacing.s2)
                                    .background(
                                        Capsule().fill(isSelected ? Color.dsAccent : Color.dsSurfaceCard)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, Spacing.pageHorizontal)

                    VStack(alignment: .leading, spacing: Spacing.s2) {
                        Toggle("同时设为新书默认倍速", isOn: $alsoSetDefault)
                            .onChange(of: alsoSetDefault) { _, newValue in
                                if newValue {
                                    AppSettingsStore.shared.defaultSpeed = player.speed
                                }
                            }
                        Text("每本书会自动记住当前倍速；开启此项后，新书首次播放也将使用该倍速。")
                            .font(DSTypography.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(Spacing.s4)
                    .background(
                        RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                            .fill(Color.dsSurfaceCard)
                    )
                    .padding(.horizontal, Spacing.pageHorizontal)
                }
                .padding(.vertical, Spacing.s4)
            }
            .background(Color.dsSurfaceGrouped)
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.height(380), .medium])
    }
}
