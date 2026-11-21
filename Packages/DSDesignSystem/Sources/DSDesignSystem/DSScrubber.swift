import SwiftUI

/// 精细进度条（采用 .onGeometryChange 零 GeometryReader，支持上滑自动切换 1x / 0.5x / 0.25x 精调倍率与浅深色轨道自定义）
public struct DSScrubber: View {
    private let currentSeconds: Double
    private let durationSeconds: Double
    private let trackColor: Color
    private let fillColor: Color
    private let timeLabelColor: Color
    private let onSeek: (Double) -> Void

    @State private var trackWidth: CGFloat = 1
    @State private var isDragging: Bool = false
    @State private var hasMoved: Bool = false
    @State private var lastTranslationX: CGFloat = 0
    @State private var previewSeconds: Double = 0
    @State private var precisionLabel: String = "1x"
    @GestureState private var isGestureActive: Bool = false

    public init(
        currentSeconds: Double,
        durationSeconds: Double,
        trackColor: Color = Color.white.opacity(0.24),
        fillColor: Color = DSColors.accent,
        timeLabelColor: Color = Color.white.opacity(0.8),
        onSeek: @escaping (Double) -> Void
    ) {
        self.currentSeconds = currentSeconds
        self.durationSeconds = durationSeconds
        self.trackColor = trackColor
        self.fillColor = fillColor
        self.timeLabelColor = timeLabelColor
        self.onSeek = onSeek
    }

    public var body: some View {
        let safeDuration = max(1, durationSeconds)
        let displayed = isDragging ? previewSeconds : currentSeconds
        let ratio = min(1, max(0, displayed / safeDuration))

        VStack(spacing: DSSpacing.xs) {
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(trackColor)
                    .frame(height: isDragging ? 7 : 5)
                Capsule()
                    .fill(fillColor)
                    .frame(width: max(8, trackWidth * ratio), height: isDragging ? 7 : 5)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
            .onGeometryChange(for: CGFloat.self) { proxy in
                max(1, proxy.size.width)
            } action: { newWidth in
                trackWidth = newWidth
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($isGestureActive) { _, state, _ in
                        state = true
                    }
                    .onChanged { value in
                        guard durationSeconds > 0 else { return }
                        if !isDragging {
                            isDragging = true
                            previewSeconds = currentSeconds
                            lastTranslationX = 0
                            hasMoved = false
                        }
                        let deltaX = value.translation.width - lastTranslationX
                        lastTranslationX = value.translation.width
                        if abs(deltaX) > 0.001 {
                            hasMoved = true
                        }
                        let verticalLift = max(0, -value.translation.height)
                        let multiplier: Double
                        if verticalLift > 80 {
                            multiplier = 0.25
                            precisionLabel = "0.25x 精调"
                        } else if verticalLift > 40 {
                            multiplier = 0.5
                            precisionLabel = "0.5x 细调"
                        } else {
                            multiplier = 1.0
                            precisionLabel = "1x"
                        }
                        let deltaRatio = Double(deltaX / max(1, trackWidth))
                        let next = previewSeconds + deltaRatio * safeDuration * multiplier
                        previewSeconds = min(safeDuration, max(0, next))
                    }
                    .onEnded { _ in
                        let target = previewSeconds
                        let shouldSeek = hasMoved && durationSeconds > 0
                        resetDragState()
                        if shouldSeek {
                            onSeek(target)
                        }
                    }
            )
            .onChange(of: isGestureActive) { _, active in
                if !active {
                    resetDragState()
                }
            }

            HStack {
                Text(Self.formatTime(displayed))
                    .font(DSTypography.monoCaption)
                    .foregroundStyle(timeLabelColor)
                Spacer()
                if isDragging && precisionLabel != "1x" {
                    Text(precisionLabel)
                        .font(DSTypography.caption)
                        .foregroundStyle(fillColor)
                }
                Spacer()
                Text(Self.formatTime(durationSeconds))
                    .font(DSTypography.monoCaption)
                    .foregroundStyle(timeLabelColor)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("播放进度")
        .accessibilityValue("\(Self.formatTime(displayed)) / \(Self.formatTime(durationSeconds))")
        .accessibilityAdjustableAction { direction in
            guard durationSeconds > 0 else { return }
            switch direction {
            case .increment:
                onSeek(min(safeDuration, currentSeconds + 15))
            case .decrement:
                onSeek(max(0, currentSeconds - 15))
            @unknown default:
                break
            }
        }
    }

    private func resetDragState() {
        isDragging = false
        hasMoved = false
        lastTranslationX = 0
        precisionLabel = "1x"
    }

    public static func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00" }
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }
}
