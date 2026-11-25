import DSCore
import SwiftUI

/// 3 柱律动均衡器（零 repeatForever，基于 AnimationTimelineSchedule 驱动，支持减弱动态效果）
public struct DSEqualizer: View {
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.dsReduceMotion) private var appReduceMotion

    public let isPlaying: Bool
    public let barColor: Color
    public let height: CGFloat

    public init(
        isPlaying: Bool,
        barColor: Color = DSColors.accent,
        height: CGFloat = 12
    ) {
        self.isPlaying = isPlaying
        self.barColor = barColor
        self.height = height
    }

    public static func shouldAnimate(isPlaying: Bool, reduceMotion: Bool) -> Bool {
        isPlaying && !reduceMotion
    }

    private var active: Bool {
        Self.shouldAnimate(isPlaying: isPlaying, reduceMotion: systemReduceMotion || appReduceMotion)
    }

    public var body: some View {
        Image(systemName: "waveform")
            .font(DSTypography.caption.weight(.semibold))
            .foregroundStyle(barColor)
            .symbolEffect(.variableColor.iterative, isActive: active)
            .frame(height: height)
            .accessibilityLabel(isPlaying ? "正在播放" : "已暂停")
    }
}

/// 进度样式（环形 / 线性条）
public enum DSProgressStyle: Equatable, Sendable {
    case ring(size: CGFloat, lineWidth: CGFloat)
    case bar(height: CGFloat)
}

/// 通用进度视图（1:1 复刻 v2.8 `DSProgress`）
public struct DSProgress: View {
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.dsReduceMotion) private var appReduceMotion

    public let value: Double
    public let style: DSProgressStyle
    @State private var displayedValue: Double

    public init(value: Double, style: DSProgressStyle = .bar(height: 4)) {
        let clamped = min(max(value, 0), 1)
        self.value = clamped
        self.style = style
        self._displayedValue = State(initialValue: clamped)
    }

    public var body: some View {
        Group {
            switch style {
            case .ring(let size, let lineWidth):
                ZStack {
                    Circle()
                        .stroke(DSColors.separator.opacity(0.28), lineWidth: lineWidth)
                    Circle()
                        .trim(from: 0, to: displayedValue)
                        .stroke(DSColors.accent, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: size, height: size)

            case .bar(let height):
                ProgressView(value: displayedValue, total: 1.0)
                    .tint(DSColors.accent)
                    .frame(height: height)
            }
        }
        .onChange(of: value) { oldValue, newValue in
            let reduce = systemReduceMotion || appReduceMotion
            let isForward = newValue > oldValue && newValue > 0
            if reduce || !isForward {
                var tx = Transaction(animation: nil)
                tx.disablesAnimations = true
                withTransaction(tx) { displayedValue = newValue }
            } else {
                withAnimation(DSMotion.progressLinear) { displayedValue = newValue }
            }
        }
    }
}

/// 20pt 环形下载进度视图（1:1 复刻 v2.8 `DownloadProgressRingView`）
public struct DownloadProgressRingView: View {
    public let progress: Double
    public let size: CGFloat
    public let lineWidth: CGFloat

    public init(progress: Double, size: CGFloat = 20, lineWidth: CGFloat = 2.2) {
        self.progress = min(max(progress, 0), 1)
        self.size = size
        self.lineWidth = lineWidth
    }

    public var body: some View {
        DSProgress(value: progress, style: .ring(size: size, lineWidth: lineWidth))
            .accessibilityLabel("下载进度 \(Int((progress * 100).rounded()))%")
    }
}

/// 继续收听 Hero 卡片（1:1 复刻 v2.8 `DSContinueCard`）
public struct DSContinueCard: View {
    private let book: BookSummaryDTO
    private let pipeline: CoverImagePipeline
    private let progressFraction: Double
    private let progressSubtitle: String
    private let isPlaying: Bool
    private let isDownloaded: Bool
    private let hasUpdate: Bool
    private let isVIP: Bool
    private let onOpenDetail: () -> Void
    private let onTogglePlay: () -> Void

    public init(
        book: BookSummaryDTO,
        pipeline: CoverImagePipeline,
        progressFraction: Double = 0,
        progressSubtitle: String = "",
        isPlaying: Bool = false,
        isDownloaded: Bool = false,
        hasUpdate: Bool = false,
        isVIP: Bool = false,
        onOpenDetail: @escaping () -> Void = {},
        onTogglePlay: @escaping () -> Void = {}
    ) {
        self.book = book
        self.pipeline = pipeline
        self.progressFraction = progressFraction
        self.progressSubtitle = progressSubtitle
        self.isPlaying = isPlaying
        self.isDownloaded = isDownloaded
        self.hasUpdate = hasUpdate
        self.isVIP = isVIP
        self.onOpenDetail = onOpenDetail
        self.onTogglePlay = onTogglePlay
    }

    private var coverBadges: [DSCoverBadge] {
        var list: [DSCoverBadge] = []
        if progressFraction > 0 { list.append(.progress(progressFraction)) }
        if isDownloaded { list.append(.downloaded) }
        if hasUpdate { list.append(.updated) }
        if isVIP { list.append(.vip) }
        return list
    }

    private var subtitleText: String {
        if !progressSubtitle.isEmpty { return progressSubtitle }
        return book.narrator.isEmpty ? book.author : book.narrator
    }

    public var body: some View {
        HStack(spacing: DSSpacing.sm) {
            Button(action: onOpenDetail) {
                HStack(spacing: DSSpacing.sm) {
                    DSCover(
                        url: book.coverURL,
                        title: book.title,
                        pipeline: pipeline,
                        side: 64,
                        badges: coverBadges
                    )

                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: DSSpacing.xs) {
                            Text(isPlaying ? "正在播放" : "继续收听")
                                .font(DSTypography.caption2.weight(.semibold))
                                .foregroundStyle(DSColors.accent)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(DSColors.accent.opacity(0.12)))
                            if isPlaying {
                                DSEqualizer(isPlaying: true)
                            }
                        }

                        Text(book.title)
                            .font(DSTypography.rowTitle)
                            .foregroundStyle(DSColors.inkPrimary)
                            .lineLimit(1)

                        if !subtitleText.isEmpty {
                            Text(subtitleText)
                                .font(DSTypography.numericCaption)
                                .foregroundStyle(isPlaying ? DSColors.accent : DSColors.inkSecondary)
                                .lineLimit(1)
                        }

                        if progressFraction > 0 {
                            DSProgress(value: progressFraction, style: .bar(height: 3))
                        }
                    }

                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.dsCard)

            Button(action: onTogglePlay) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(DSTypography.subheadline.weight(.semibold))
                    .foregroundStyle(DSColors.onAccent)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(DSColors.accent))
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isPlaying ? "暂停播放" : "继续收听")
        }
        .padding(.horizontal, DSSpacing.sm)
        .padding(.vertical, DSSpacing.sm)
        .background(RoundedRectangle(cornerRadius: DSRadius.card, style: .continuous).fill(DSColors.surfaceCard))
        .overlay(RoundedRectangle(cornerRadius: DSRadius.card, style: .continuous).strokeBorder(DSColors.accent.opacity(0.18), lineWidth: 1))
    }
}

/// 骨架屏模式（1:1 复刻 v2.8 `DSSkeleton`）
public enum DSSkeletonMode: Equatable, Sendable {
    case grid
    case list(rows: Int)
    case chapters(rows: Int)
}

public struct DSSkeletonVisibilityPolicy: Sendable {
    public static let appearDelayMs: Int = 200
    public static let minimumStayMs: Int = 400

    public static func shouldShow(elapsedLoadingMs: Int, isStillLoading: Bool, shownAtMs: Int?) -> Bool {
        if isStillLoading { return elapsedLoadingMs >= appearDelayMs }
        guard let shownAt = shownAtMs else { return false }
        return (elapsedLoadingMs - shownAt) < minimumStayMs
    }
}

public struct DSSkeleton: View {
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.dsReduceMotion) private var appReduceMotion
    public let mode: DSSkeletonMode

    public init(mode: DSSkeletonMode = .grid) {
        self.mode = mode
    }

    public var body: some View {
        let reduce = systemReduceMotion || appReduceMotion
        Group {
            switch mode {
            case .grid:
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: DSSpacing.gridColumnSpacing), count: 3),
                    spacing: DSSpacing.gridRowSpacing
                ) {
                    ForEach(0..<9, id: \.self) { _ in
                        VStack(alignment: .leading, spacing: DSSpacing.xs) {
                            RoundedRectangle(cornerRadius: DSRadius.coverLarge, style: .continuous)
                                .fill(DSColors.surfaceGrouped)
                                .aspectRatio(1, contentMode: .fit)
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(DSColors.surfaceGrouped)
                                .frame(height: 14)
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(DSColors.surfaceGrouped)
                                .frame(width: 60, height: 12)
                        }
                    }
                }
                .padding(.horizontal, DSSpacing.pageHorizontal)

            case .list(let rows), .chapters(let rows):
                VStack(spacing: DSSpacing.sm) {
                    ForEach(0..<max(1, rows), id: \.self) { _ in
                        HStack(spacing: DSSpacing.sm) {
                            RoundedRectangle(cornerRadius: DSRadius.coverSmall, style: .continuous)
                                .fill(DSColors.surfaceGrouped)
                                .frame(width: 48, height: 48)
                            VStack(alignment: .leading, spacing: DSSpacing.xs) {
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(DSColors.surfaceGrouped)
                                    .frame(height: 15)
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(DSColors.surfaceGrouped)
                                    .frame(width: 120, height: 12)
                            }
                            Spacer()
                        }
                    }
                }
                .padding(.horizontal, DSSpacing.pageHorizontal)
            }
        }
        .redacted(reason: .placeholder)
        .opacity(reduce ? 0.75 : 0.88)
        .accessibilityLabel("正在加载")
    }
}
