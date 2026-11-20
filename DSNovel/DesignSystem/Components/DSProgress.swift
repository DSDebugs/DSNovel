import SwiftUI

enum DSProgressStyle {
    case ring(size: CGFloat, lineWidth: CGFloat)
    case bar(height: CGFloat)
}

struct DSProgress: View {
    let value: Double
    let style: DSProgressStyle

    init(value: Double, style: DSProgressStyle = .bar(height: 4)) {
        self.value = min(max(value, 0), 1)
        self.style = style
    }

    var body: some View {
        switch style {
        case .ring(let size, let lineWidth):
            ZStack {
                Circle()
                    .stroke(Color.dsSeparator.opacity(0.28), lineWidth: lineWidth)
                Circle()
                    .trim(from: 0, to: value)
                    .stroke(
                        Color.dsAccent,
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 1.0), value: value)
            }
            .frame(width: size, height: size)

        case .bar(let height):
            ProgressView(value: value, total: 1.0)
                .tint(Color.dsAccent)
                .frame(height: height)
                .animation(.linear(duration: 1.0), value: value)
        }
    }
}

#Preview("Light") {
    HStack(spacing: 20) {
        DSProgress(value: 0.65, style: .ring(size: 32, lineWidth: 3))
        DSProgress(value: 0.45, style: .bar(height: 4))
    }
    .padding()
    .preferredColorScheme(.light)
}

#Preview("Dark") {
    DSProgress(value: 0.75, style: .ring(size: 36, lineWidth: 3))
        .padding()
        .preferredColorScheme(.dark)
}

#Preview("AX") {
    DSProgress(value: 0.5, style: .bar(height: 6))
        .padding()
        .environment(\.sizeCategory, .accessibilityExtraExtraLarge)
}
