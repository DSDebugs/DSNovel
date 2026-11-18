import SwiftUI

enum DSScrubberLogic {
    static func mapDragDelta(
        startSeconds: Double,
        deltaRatio: Double,
        durationSeconds: Double,
        isFineScrubbing: Bool
    ) -> Double {
        guard durationSeconds > 0 else { return 0 }
        let sensitivity = isFineScrubbing ? 0.25 : 1.0
        let raw = startSeconds + deltaRatio * durationSeconds * sensitivity
        return min(max(raw, 0), durationSeconds)
    }

    static func crossedWholeMinute(from oldSec: Double, to newSec: Double) -> Bool {
        guard oldSec >= 0, newSec >= 0 else { return false }
        return Int(oldSec / 60.0) != Int(newSec / 60.0)
    }
}

struct DSScrubber: View {
    let currentTimeSec: Double
    let durationSec: Double
    let bufferedFraction: Double
    private let onSeek: (Double) -> Void

    @State private var isDragging = false
    @State private var isFineMode = false
    @State private var dragPreviewSec: Double = 0
    @State private var fineAnchorSec: Double = 0
    @State private var fineAnchorFraction: Double = 0
    @State private var minuteBucket: Int = 0

    init(
        currentTimeSec: Double,
        durationSec: Double,
        bufferedFraction: Double = 0,
        onSeek: @escaping (Double) -> Void = { _ in }
    ) {
        self.currentTimeSec = currentTimeSec
        self.durationSec = durationSec
        self.bufferedFraction = bufferedFraction
        self.onSeek = onSeek
    }

    private var displayedSec: Double {
        isDragging ? dragPreviewSec : currentTimeSec
    }

    private var progressFraction: Double {
        guard durationSec > 0 else { return 0 }
        return min(max(displayedSec / durationSec, 0), 1)
    }

    private var clampedBufferedFraction: Double {
        min(max(bufferedFraction, progressFraction), 1.0)
    }

    private var bufferedPercentText: String {
        let pct = Int((clampedBufferedFraction * 100.0).rounded())
        return "已缓冲 \(min(max(pct, 0), 100))%"
    }

    var body: some View {
        VStack(spacing: Spacing.s2) {
            if isDragging {
                HStack(spacing: Spacing.s2) {
                    Image(systemName: isFineMode ? "scope" : "waveform")
                        .font(DSTypography.caption2)
                        .foregroundStyle(Color.dsAccent)
                    Text("\(Self.formatTime(displayedSec)) / \(Self.formatTime(durationSec))")
                        .font(DSTypography.numericCaption.weight(.semibold))
                        .foregroundStyle(.white)
                    if isFineMode {
                        Text("1/4x 精细")
                            .font(DSTypography.caption2.weight(.semibold))
                            .foregroundStyle(Color.dsAccent)
                    }
                }
                .padding(.horizontal, Spacing.s3)
                .padding(.vertical, 4)
                .background(
                    Capsule().fill(Color.black.opacity(0.45))
                )
                .overlay(
                    Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
                )
            }

            ZStack(alignment: .center) {
                ProgressView(value: clampedBufferedFraction, total: 1.0)
                    .tint(Color.white.opacity(0.28))
                    .scaleEffect(x: 1.0, y: isDragging ? 1.5 : 1.0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)

                Slider(
                    value: Binding(
                        get: { progressFraction },
                        set: { newFraction in
                            let safeDur = max(durationSec, 1)
                            let newSec: Double
                            if isFineMode {
                                let deltaRatio = newFraction - fineAnchorFraction
                                newSec = DSScrubberLogic.mapDragDelta(
                                    startSeconds: fineAnchorSec,
                                    deltaRatio: deltaRatio,
                                    durationSeconds: safeDur,
                                    isFineScrubbing: true
                                )
                            } else {
                                newSec = newFraction * safeDur
                            }
                            if DSScrubberLogic.crossedWholeMinute(from: dragPreviewSec, to: newSec) {
                                minuteBucket = Int(newSec / 60.0)
                                DSHapticPolicy.fire(.scrubberMinuteTick)
                            }
                            dragPreviewSec = newSec
                        }
                    ),
                    in: 0...1,
                    onEditingChanged: { editing in
                        isDragging = editing
                        if editing {
                            dragPreviewSec = currentTimeSec
                            fineAnchorSec = currentTimeSec
                            fineAnchorFraction = progressFraction
                        } else {
                            onSeek(dragPreviewSec)
                        }
                    }
                )
                .tint(Color.dsAccent)
                .scaleEffect(x: 1.0, y: isDragging ? 1.16 : 1.0)
                .simultaneousGesture(
                    LongPressGesture(minimumDuration: 0.45)
                        .onEnded { _ in
                            isFineMode = true
                            fineAnchorSec = displayedSec
                            fineAnchorFraction = progressFraction
                            DSHapticPolicy.fire(.selection)
                        }
                )
            }

            HStack {
                Text(Self.formatTime(displayedSec))
                    .font(DSTypography.numericCaption)
                    .foregroundStyle(.white.opacity(0.78))
                    .contentTransition(.numericText())

                Spacer()

                Button {
                    isFineMode.toggle()
                    fineAnchorSec = displayedSec
                    fineAnchorFraction = progressFraction
                    DSHapticPolicy.fire(.selection)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: isFineMode ? "scope" : "arrow.left.and.right.circle")
                            .font(DSTypography.caption2)
                        Text(isFineMode ? "精细拖动 (1/4x)" : bufferedPercentText)
                            .font(DSTypography.caption2.weight(isFineMode ? .semibold : .regular))
                    }
                    .foregroundStyle(isFineMode ? Color.dsAccent : .white.opacity(0.65))
                    .padding(.horizontal, Spacing.s2)
                    .padding(.vertical, 3)
                    .background(
                        Capsule().fill(isFineMode ? Color.dsAccent.opacity(0.18) : Color.white.opacity(0.08))
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isFineMode ? "已开启四分之一精细拖动，点击恢复标准拖动" : "点击开启精细拖动模式")

                Spacer()

                Text("-" + Self.formatTime(max(0, durationSec - displayedSec)))
                    .font(DSTypography.numericCaption)
                    .foregroundStyle(.white.opacity(0.78))
                    .contentTransition(.numericText())
            }
        }
        .transaction { tx in
            if !isDragging {
                tx.animation = nil
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("播放进度")
        .accessibilityValue("已播放 \(Self.formatTime(displayedSec))，总时长 \(Self.formatTime(durationSec))，\(bufferedPercentText)")
        .accessibilityAdjustableAction { direction in
            let safeDur = max(durationSec, 1)
            switch direction {
            case .increment:
                onSeek(min(safeDur, currentTimeSec + 15))
            case .decrement:
                onSeek(max(0, currentTimeSec - 15))
            @unknown default:
                break
            }
        }
    }

    static func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds > 0 else { return "00:00" }
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }
}

#Preview("Light") {
    DSScrubber(currentTimeSec: 165, durationSec: 1200, bufferedFraction: 0.45)
        .padding()
        .background(Color.black)
        .preferredColorScheme(.dark)
}

#Preview("Dark") {
    DSScrubber(currentTimeSec: 420, durationSec: 1800, bufferedFraction: 0.72)
        .padding()
        .background(Color.black)
        .preferredColorScheme(.dark)
}

#Preview("AX") {
    DSScrubber(currentTimeSec: 90, durationSec: 600, bufferedFraction: 0.6)
        .padding()
        .background(Color.black)
        .environment(\.sizeCategory, .accessibilityExtraExtraLarge)
}
