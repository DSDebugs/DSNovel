import SwiftUI

enum DSScrubberLogic {
    static func mapDragDelta(
        startSeconds: Double,
        deltaRatio: Double,
        durationSeconds: Double,
        isFineScrubbing: Bool
    ) -> Double {
        let rate = isFineScrubbing ? 0.25 : 1.0
        return mapDragDelta(
            startSeconds: startSeconds,
            deltaRatio: deltaRatio,
            durationSeconds: durationSeconds,
            sensitivity: rate
        )
    }

    static func mapDragDelta(
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
    static func scrubbingSensitivity(forVerticalLift liftPoints: CGFloat) -> Double {
        if liftPoints >= 80 {
            return 0.25
        } else if liftPoints >= 40 {
            return 0.5
        }
        return 1.0
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
    @State private var manualFineMode = false
    @State private var activeSensitivity: Double = 1.0
    @State private var dragPreviewSec: Double = 0
    @State private var lastDragLocationX: CGFloat? = nil
    @State private var minuteBucket: Int = 0
    @State private var trackWidth: CGFloat = 280

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

    private var effectiveSensitivity: Double {
        if isDragging {
            return min(activeSensitivity, manualFineMode ? 0.25 : 1.0)
        }
        return manualFineMode ? 0.25 : 1.0
    }

    private var sensitivityBadgeText: String? {
        let s = effectiveSensitivity
        if s <= 0.26 { return "0.25x 精细" }
        if s <= 0.51 { return "0.5x 半速" }
        return nil
    }

    var body: some View {
        VStack(spacing: Spacing.s2) {
            customTrack
                .overlay(alignment: .top) {
                    if isDragging {
                        dragPreviewBubble
                            .offset(y: -38)
                            .allowsHitTesting(false)
                    }
                }

            HStack {
                Text(Self.formatTime(displayedSec))
                    .font(DSTypography.numericCaption)
                    .foregroundStyle(.white.opacity(0.78))
                    .contentTransition(.numericText())

                Spacer()

                Button {
                    manualFineMode.toggle()
                    activeSensitivity = manualFineMode ? 0.25 : 1.0
                    DSHapticPolicy.fire(.selection)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: effectiveSensitivity < 0.99 ? "scope" : "arrow.left.and.right.circle")
                            .font(DSTypography.caption2)
                        Text(sensitivityBadgeText ?? bufferedPercentText)
                            .font(DSTypography.caption2.weight(effectiveSensitivity < 0.99 ? .semibold : .regular))
                    }
                    .foregroundStyle(effectiveSensitivity < 0.99 ? Color.dsAccent : .white.opacity(0.65))
                    .padding(.horizontal, Spacing.s2)
                    .padding(.vertical, 3)
                    .background(
                        Capsule().fill(effectiveSensitivity < 0.99 ? Color.dsAccent.opacity(0.18) : Color.white.opacity(0.08))
                    )
                }
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
                .buttonStyle(.plain)
                .accessibilityLabel(manualFineMode ? "已开启精细拖动，点击恢复标准拖动" : "点击开启精细拖动模式")

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
    }

    private var dragPreviewBubble: some View {
        HStack(spacing: Spacing.s2) {
            Image(systemName: effectiveSensitivity < 0.99 ? "scope" : "waveform")
                .font(DSTypography.caption2)
                .foregroundStyle(Color.dsAccent)
            Text("\(Self.formatTime(displayedSec)) / \(Self.formatTime(durationSec))")
                .font(DSTypography.numericCaption.weight(.semibold))
                .foregroundStyle(.white)
            if let badge = sensitivityBadgeText {
                Text(badge)
                    .font(DSTypography.caption2.weight(.semibold))
                    .foregroundStyle(Color.dsAccent)
            }
        }
        .padding(.horizontal, Spacing.s3)
        .padding(.vertical, 4)
        .background(
            Capsule().fill(Color.black.opacity(0.62))
        )
        .overlay(
            Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
        )
    }

    private var customTrack: some View {
        let safeTrackWidth = max(trackWidth, 1)
        let trackHeight: CGFloat = isDragging ? 6 : 4
        let thumbSize: CGFloat = isDragging ? 18 : 13
        let filledWidth = safeTrackWidth * CGFloat(progressFraction)
        let bufferedWidth = safeTrackWidth * CGFloat(clampedBufferedFraction)
        let thumbX = min(max(filledWidth, thumbSize * 0.5), safeTrackWidth - thumbSize * 0.5)

        return ZStack(alignment: .leading) {
            // 轨道底槽
            Capsule()
                .fill(Color.white.opacity(0.16))
                .frame(height: trackHeight)

            // 已缓冲进度
            Capsule()
                .fill(Color.white.opacity(0.32))
                .frame(width: max(0, bufferedWidth), height: trackHeight)

            // 已播放进度
            Capsule()
                .fill(Color.dsAccent)
                .frame(width: max(0, filledWidth), height: trackHeight)

            // 拖动手柄
            Circle()
                .fill(Color.white)
                .frame(width: thumbSize, height: thumbSize)
                .shadow(color: Color.black.opacity(0.35), radius: isDragging ? 5 : 2, y: 1)
                .offset(x: thumbX - thumbSize * 0.5)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 44)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { newWidth in
            trackWidth = max(newWidth, 1)
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let safeDur = max(durationSec, 1)
                    let width = max(trackWidth, 1)
                    if !isDragging {
                        isDragging = true
                        activeSensitivity = manualFineMode ? 0.25 : 1.0
                        let tappedRatio = min(max(Double(value.startLocation.x / width), 0), 1)
                        dragPreviewSec = tappedRatio * safeDur
                        lastDragLocationX = value.location.x
                        minuteBucket = Int(dragPreviewSec / 60.0)
                        DSHapticPolicy.fire(.selection)
                    }

                    // 手指向上偏离轨道自动切换 1x / 0.5x / 0.25x 精细调速
                    let liftPoints = max(0, -value.translation.height)
                    let gestureSensitivity = DSScrubberLogic.scrubbingSensitivity(forVerticalLift: liftPoints)
                    let nextSensitivity = manualFineMode ? min(0.25, gestureSensitivity) : gestureSensitivity
                    if abs(nextSensitivity - activeSensitivity) > 0.01 {
                        activeSensitivity = nextSensitivity
                        DSHapticPolicy.fire(.selection)
                    }

                    let prevX = lastDragLocationX ?? value.location.x
                    let deltaX = value.location.x - prevX
                    lastDragLocationX = value.location.x

                    let deltaRatio = Double(deltaX / width)
                    let newSec = DSScrubberLogic.mapDragDelta(
                        startSeconds: dragPreviewSec,
                        deltaRatio: deltaRatio,
                        durationSeconds: safeDur,
                        sensitivity: activeSensitivity
                    )
                    if DSScrubberLogic.crossedWholeMinute(from: dragPreviewSec, to: newSec) {
                        minuteBucket = Int(newSec / 60.0)
                        DSHapticPolicy.fire(.scrubberMinuteTick)
                    }
                    dragPreviewSec = newSec
                }
                .onEnded { _ in
                    let finalSec = dragPreviewSec
                    isDragging = false
                    lastDragLocationX = nil
                    // 松手自动恢复 1x（若未手动锁定精细模式）
                    activeSensitivity = manualFineMode ? 0.25 : 1.0
                    onSeek(finalSec)
                }
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("播放进度条")
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
        .accessibilityAction(named: "快进 30 秒") {
            let safeDur = max(durationSec, 1)
            onSeek(min(safeDur, currentTimeSec + 30))
        }
        .accessibilityAction(named: "后退 15 秒") {
            onSeek(max(0, currentTimeSec - 15))
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
