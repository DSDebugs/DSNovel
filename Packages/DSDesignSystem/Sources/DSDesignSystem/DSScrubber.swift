import SwiftUI

/// 精细进度条计算逻辑（1:1 复刻 v2.8）
public enum DSScrubberLogic {
    public static func mapDragDelta(
        startSeconds: Double,
        deltaRatio: Double,
        durationSeconds: Double,
        isFineScrubbing: Bool
    ) -> Double {
        mapDragDelta(
            startSeconds: startSeconds,
            deltaRatio: deltaRatio,
            durationSeconds: durationSeconds,
            sensitivity: isFineScrubbing ? 0.25 : 1.0
        )
    }

    public static func mapDragDelta(
        startSeconds: Double,
        deltaRatio: Double,
        durationSeconds: Double,
        sensitivity: Double
    ) -> Double {
        guard durationSeconds > 0 else { return 0 }
        let raw = startSeconds + deltaRatio * durationSeconds * sensitivity
        return min(max(raw, 0), durationSeconds)
    }

    /// 手指向上偏离轨道的距离自动映射精细调速倍率：0..<40pt -> 1x，40..<80pt -> 0.5x，>=80pt -> 0.25x
    public static func scrubbingSensitivity(forVerticalLift liftPoints: CGFloat) -> Double {
        if liftPoints >= 80 {
            return 0.25
        } else if liftPoints >= 40 {
            return 0.5
        }
        return 1.0
    }

    public static func crossedWholeMinute(from oldSec: Double, to newSec: Double) -> Bool {
        guard oldSec >= 0, newSec >= 0 else { return false }
        return Int(oldSec / 60.0) != Int(newSec / 60.0)
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

/// 精细进度条（极简无冗余胶囊：缓冲轨内嵌 + 顶部悬浮预览气泡 + 整分钟触觉 + 上滑 1x/0.5x/0.25x 精调，零 GeometryReader）
public struct DSScrubber: View {
    private let currentSeconds: Double
    private let durationSeconds: Double
    private let bufferedSeconds: Double
    private let trackColor: Color
    private let fillColor: Color
    private let timeLabelColor: Color
    private let onSeek: (Double) -> Void

    @State private var trackWidth: CGFloat = 280
    @State private var isDragging: Bool = false
    @State private var activeSensitivity: Double = 1.0
    @State private var previewSeconds: Double = 0
    @State private var lastDragLocationX: CGFloat? = nil
    @GestureState private var isGestureActive: Bool = false

    public init(
        currentSeconds: Double,
        durationSeconds: Double,
        bufferedSeconds: Double = 0,
        trackColor: Color = Color.white.opacity(0.16),
        fillColor: Color = DSColors.accent,
        timeLabelColor: Color = Color.white.opacity(0.72),
        onSeek: @escaping (Double) -> Void
    ) {
        self.currentSeconds = currentSeconds
        self.durationSeconds = durationSeconds
        self.bufferedSeconds = bufferedSeconds
        self.trackColor = trackColor
        self.fillColor = fillColor
        self.timeLabelColor = timeLabelColor
        self.onSeek = onSeek
    }

    private var safeDuration: Double {
        max(1, durationSeconds)
    }

    private var displayedSeconds: Double {
        isDragging ? previewSeconds : currentSeconds
    }

    private var progressFraction: Double {
        guard durationSeconds > 0 else { return 0 }
        return min(max(displayedSeconds / durationSeconds, 0), 1)
    }

    private var bufferedFraction: Double {
        guard durationSeconds > 0 else { return progressFraction }
        let raw = min(max(bufferedSeconds / durationSeconds, 0), 1)
        return min(max(raw, progressFraction), 1)
    }

    private var bufferedPercentText: String {
        let pct = Int((bufferedFraction * 100.0).rounded())
        return "已缓冲 \(min(max(pct, 0), 100))%"
    }

    private var sensitivityBadgeText: String? {
        if activeSensitivity <= 0.26 { return "0.25x 精细" }
        if activeSensitivity <= 0.51 { return "0.5x 半速" }
        return nil
    }

    public var body: some View {
        VStack(spacing: 4) {
            trackView
                .overlay(alignment: .top) {
                    if isDragging {
                        dragPreviewBubble
                            .offset(y: -38)
                            .allowsHitTesting(false)
                    }
                }

            HStack {
                Text(Self.formatTime(displayedSeconds))
                    .font(DSTypography.numericCaption)
                    .foregroundStyle(timeLabelColor)
                    .contentTransition(.numericText())

                Spacer()

                Text(Self.formatTime(durationSeconds))
                    .font(DSTypography.numericCaption)
                    .foregroundStyle(timeLabelColor)
                    .contentTransition(.numericText())
            }
        }
        .transaction { tx in
            if !isDragging {
                tx.animation = nil
            }
        }
        .onChange(of: isGestureActive) { _, active in
            if !active && isDragging {
                resetDragState()
            }
        }
    }

    private var dragPreviewBubble: some View {
        HStack(spacing: DSSpacing.xs) {
            Image(systemName: activeSensitivity < 0.99 ? "scope" : "waveform")
                .font(DSTypography.caption2)
                .foregroundStyle(fillColor)
            Text("\(Self.formatTime(displayedSeconds)) / \(Self.formatTime(durationSeconds))")
                .font(DSTypography.numericCaption.weight(.semibold))
                .foregroundStyle(.white)
            if let badge = sensitivityBadgeText {
                Text(badge)
                    .font(DSTypography.caption2.weight(.semibold))
                    .foregroundStyle(fillColor)
            }
        }
        .padding(.horizontal, DSSpacing.sm)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.black.opacity(0.68)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
    }

    private var trackView: some View {
        let safeWidth = max(trackWidth, 1)
        let trackHeight: CGFloat = isDragging ? 6 : 4
        let thumbSize: CGFloat = isDragging ? 18 : 12
        let filledWidth = safeWidth * CGFloat(progressFraction)
        let bufferedWidth = safeWidth * CGFloat(bufferedFraction)
        let thumbX = min(max(filledWidth, thumbSize * 0.5), safeWidth - thumbSize * 0.5)

        return ZStack(alignment: .leading) {
            Capsule()
                .fill(trackColor)
                .frame(height: trackHeight)

            Capsule()
                .fill(Color.white.opacity(0.30))
                .frame(width: max(0, bufferedWidth), height: trackHeight)

            Capsule()
                .fill(fillColor)
                .frame(width: max(0, filledWidth), height: trackHeight)

            Circle()
                .fill(Color.white)
                .frame(width: thumbSize, height: thumbSize)
                .shadow(color: Color.black.opacity(0.35), radius: isDragging ? 5 : 2, y: 1)
                .offset(x: thumbX - thumbSize * 0.5)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 36)
        .onGeometryChange(for: CGFloat.self) { proxy in
            max(1, proxy.size.width)
        } action: { newWidth in
            trackWidth = newWidth
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .updating($isGestureActive) { _, state, _ in
                    state = true
                }
                .onChanged { value in
                    guard durationSeconds > 0 else { return }
                    let width = max(trackWidth, 1)
                    if !isDragging {
                        isDragging = true
                        activeSensitivity = 1.0
                        let tappedRatio = min(max(Double(value.startLocation.x / width), 0), 1)
                        previewSeconds = tappedRatio * safeDuration
                        lastDragLocationX = value.location.x
                        DSHaptics.selection()
                    }

                    let liftPoints = max(0, -value.translation.height)
                    let nextSensitivity = DSScrubberLogic.scrubbingSensitivity(forVerticalLift: liftPoints)
                    if abs(nextSensitivity - activeSensitivity) > 0.01 {
                        activeSensitivity = nextSensitivity
                        DSHaptics.selection()
                    }

                    let prevX = lastDragLocationX ?? value.location.x
                    let deltaX = value.location.x - prevX
                    lastDragLocationX = value.location.x

                    let deltaRatio = Double(deltaX / width)
                    let nextSec = DSScrubberLogic.mapDragDelta(
                        startSeconds: previewSeconds,
                        deltaRatio: deltaRatio,
                        durationSeconds: safeDuration,
                        sensitivity: activeSensitivity
                    )
                    if DSScrubberLogic.crossedWholeMinute(from: previewSeconds, to: nextSec) {
                        DSHaptics.scrubberMinuteTick()
                    }
                    previewSeconds = nextSec
                }
                .onEnded { _ in
                    let target = previewSeconds
                    let shouldSeek = durationSeconds > 0
                    resetDragState()
                    if shouldSeek {
                        onSeek(target)
                    }
                }
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("播放进度")
        .accessibilityValue("\(Self.formatTime(displayedSeconds)) / \(Self.formatTime(durationSeconds))，\(bufferedPercentText)")
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
        .accessibilityAction(named: "快进 30 秒") {
            guard durationSeconds > 0 else { return }
            onSeek(min(safeDuration, currentSeconds + 30))
        }
        .accessibilityAction(named: "后退 15 秒") {
            guard durationSeconds > 0 else { return }
            onSeek(max(0, currentSeconds - 15))
        }
    }

    private func resetDragState() {
        isDragging = false
        lastDragLocationX = nil
        activeSensitivity = 1.0
    }

    public static func formatTime(_ seconds: Double) -> String {
        DSScrubberLogic.formatTime(seconds)
    }
}
