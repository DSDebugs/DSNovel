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

    var body: some View {
        VStack(spacing: Spacing.s2) {
            Slider(
                value: Binding(
                    get: { progressFraction },
                    set: { newFraction in
                        let newSec = newFraction * max(durationSec, 1)
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
                    } else {
                        onSeek(dragPreviewSec)
                        isFineMode = false
                    }
                }
            )
            .tint(Color.dsAccent)
            .scaleEffect(x: 1.0, y: isDragging ? 1.18 : 1.0)
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.45)
                    .onEnded { _ in
                        isFineMode = true
                        DSHapticPolicy.fire(.selection)
                    }
            )

            HStack {
                Text(Self.formatTime(displayedSec))
                    .font(DSTypography.numericCaption)
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())

                Spacer()

                if isFineMode {
                    Text("精细拖动 (1/4)")
                        .font(DSTypography.caption2)
                        .foregroundStyle(Color.dsAccent)
                }

                Spacer()

                Text("-" + Self.formatTime(max(0, durationSec - displayedSec)))
                    .font(DSTypography.numericCaption)
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
        }
        .transaction { tx in
            if !isDragging {
                tx.animation = nil
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
    DSScrubber(currentTimeSec: 165, durationSec: 1200)
        .padding()
        .preferredColorScheme(.light)
}

#Preview("Dark") {
    DSScrubber(currentTimeSec: 420, durationSec: 1800)
        .padding()
        .preferredColorScheme(.dark)
}

#Preview("AX") {
    DSScrubber(currentTimeSec: 90, durationSec: 600)
        .padding()
        .environment(\.sizeCategory, .accessibilityExtraExtraLarge)
}
