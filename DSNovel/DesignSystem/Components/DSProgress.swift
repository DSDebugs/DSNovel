import SwiftUI

enum DSProgressStyle {
    case ring(size: CGFloat, lineWidth: CGFloat)
    case bar(height: CGFloat)
}

struct DSProgress: View {
    @Environment(\.dsReduceMotion) private var reduceMotion

    let value: Double
    let style: DSProgressStyle

    @State private var displayedValue: Double

    init(value: Double, style: DSProgressStyle = .bar(height: 4)) {
        let clamped = min(max(value, 0), 1)
        self.value = clamped
        self.style = style
        self._displayedValue = State(initialValue: clamped)
    }

    var body: some View {
        Group {
            switch style {
            case .ring(let size, let lineWidth):
                ZStack {
                    Circle()
                        .stroke(Color.dsSeparator.opacity(0.28), lineWidth: lineWidth)
                    Circle()
                        .trim(from: 0, to: displayedValue)
                        .stroke(
                            Color.dsAccent,
                            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: size, height: size)

            case .bar(let height):
                ProgressView(value: displayedValue, total: 1.0)
                    .tint(Color.dsAccent)
                    .frame(height: height)
            }
        }
        .onAppear {
            if displayedValue != value {
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    displayedValue = value
                }
            }
        }
        .onChange(of: value) { oldValue, newValue in
            let isForwardStep = newValue > oldValue && newValue > 0
            if reduceMotion || !isForwardStep {
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    displayedValue = newValue
                }
            } else {
                withAnimation(.linear(duration: 1.0)) {
                    displayedValue = newValue
                }
            }
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
