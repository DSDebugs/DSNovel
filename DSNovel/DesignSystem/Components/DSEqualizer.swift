import SwiftUI

struct DSEqualizer: View {
    @Environment(\.dsReduceMotion) private var reduceMotion
    let isPlaying: Bool

    init(isPlaying: Bool) {
        self.isPlaying = isPlaying
    }

    static func shouldAnimate(isPlaying: Bool, reduceMotion: Bool) -> Bool {
        isPlaying && !reduceMotion
    }

    var body: some View {
        let active = Self.shouldAnimate(isPlaying: isPlaying, reduceMotion: reduceMotion)
        Image(systemName: "waveform")
            .font(.caption.weight(.semibold))
            .foregroundStyle(Color.dsAccent)
            .symbolEffect(.variableColor.iterative, isActive: active)
            .accessibilityLabel(isPlaying ? "正在播放" : "已暂停")
    }
}

#Preview("Light") {
    DSEqualizer(isPlaying: true)
        .preferredColorScheme(.light)
}

#Preview("Dark") {
    DSEqualizer(isPlaying: false)
        .preferredColorScheme(.dark)
}

#Preview("AX") {
    DSEqualizer(isPlaying: true)
        .environment(\.sizeCategory, .accessibilityExtraExtraLarge)
}
