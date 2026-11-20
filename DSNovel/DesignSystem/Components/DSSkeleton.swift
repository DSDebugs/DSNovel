import SwiftUI

enum DSSkeletonMode: Equatable, Sendable {
    case grid
    case list(rows: Int)
    case chapters(rows: Int)
}

struct DSSkeletonVisibilityPolicy: Sendable {
    static let appearDelayMs: Int = 200
    static let minimumStayMs: Int = 400

    static func shouldShow(elapsedLoadingMs: Int, isStillLoading: Bool, shownAtMs: Int?) -> Bool {
        if isStillLoading {
            return elapsedLoadingMs >= appearDelayMs
        }
        guard let shownAt = shownAtMs else { return false }
        return (elapsedLoadingMs - shownAt) < minimumStayMs
    }
}

struct DSSkeleton: View {
    @Environment(\.dsReduceMotion) private var reduceMotion
    let mode: DSSkeletonMode

    init(mode: DSSkeletonMode = .grid) {
        self.mode = mode
    }

    var body: some View {
        Group {
            switch mode {
            case .grid:
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: Spacing.gridColumnSpacing), count: 3),
                    spacing: Spacing.gridRowSpacing
                ) {
                    ForEach(0..<9, id: \.self) { _ in
                        VStack(alignment: .leading, spacing: Spacing.s2) {
                            RoundedRectangle(cornerRadius: Radius.coverLarge, style: .continuous)
                                .fill(Color.dsSurfaceGrouped)
                                .aspectRatio(1, contentMode: .fit)
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(Color.dsSurfaceGrouped)
                                .frame(height: 14)
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(Color.dsSurfaceGrouped)
                                .frame(width: 60, height: 12)
                        }
                    }
                }
                .padding(.horizontal, Spacing.pageHorizontal)

            case .list(let rows), .chapters(let rows):
                VStack(spacing: Spacing.s3) {
                    ForEach(0..<rows, id: \.self) { _ in
                        HStack(spacing: Spacing.s3) {
                            RoundedRectangle(cornerRadius: Radius.coverSmall, style: .continuous)
                                .fill(Color.dsSurfaceGrouped)
                                .frame(width: 48, height: 48)
                            VStack(alignment: .leading, spacing: Spacing.s2) {
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(Color.dsSurfaceGrouped)
                                    .frame(height: 15)
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(Color.dsSurfaceGrouped)
                                    .frame(width: 120, height: 12)
                            }
                            Spacer()
                        }
                    }
                }
                .padding(.horizontal, Spacing.pageHorizontal)
            }
        }
        .redacted(reason: .placeholder)
        .opacity(reduceMotion ? 0.75 : 0.88)
        .accessibilityLabel("正在加载")
    }
}

#Preview("Light") {
    DSSkeleton(mode: .grid)
        .preferredColorScheme(.light)
}

#Preview("Dark") {
    DSSkeleton(mode: .list(rows: 5))
        .preferredColorScheme(.dark)
}

#Preview("AX") {
    DSSkeleton(mode: .chapters(rows: 4))
        .environment(\.sizeCategory, .accessibilityExtraExtraLarge)
}
