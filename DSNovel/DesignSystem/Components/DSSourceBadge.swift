import SwiftUI

enum DSSourceHealthKind: String, CaseIterable, Equatable, Sendable {
    case untested
    case healthy
    case slow
    case needAuth
    case unavailable

    var iconName: String {
        switch self {
        case .healthy: return "checkmark.circle.fill"
        case .slow: return "tortoise.fill"
        case .needAuth: return "person.badge.key"
        case .unavailable: return "exclamationmark.triangle.fill"
        case .untested: return "circle.dashed"
        }
    }

    var statusColor: Color {
        switch self {
        case .healthy: return .green
        case .slow: return .yellow
        case .needAuth: return .orange
        case .unavailable: return .red
        case .untested: return .secondary
        }
    }
}

struct DSSourceBadge: View {
    let name: String
    let health: DSSourceHealthKind
    let latencyMs: Int?

    init(
        name: String,
        health: DSSourceHealthKind = .untested,
        latencyMs: Int? = nil
    ) {
        self.name = name
        self.health = health
        self.latencyMs = latencyMs
    }

    private var initialText: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "源" }
        return String(first)
    }

    var body: some View {
        HStack(spacing: Spacing.s2) {
            Text(initialText)
                .font(DSTypography.caption.weight(.bold))
                .foregroundStyle(Color.dsOnAccent)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.dsAccent))

            Text(name)
                .font(DSTypography.subtitle.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Image(systemName: health.iconName)
                .font(.caption2)
                .foregroundStyle(health.statusColor)

            if let latencyMs, latencyMs > 0 {
                Text("\(latencyMs)ms")
                    .font(DSTypography.numericCaption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, Spacing.s2)
        .padding(.vertical, 4)
        .background(
            Capsule(style: .continuous)
                .fill(Color.dsSurfaceGrouped)
        )
    }
}

#Preview("Light") {
    DSSourceBadge(name: "博看有声", health: .healthy, latencyMs: 128)
        .preferredColorScheme(.light)
}

#Preview("Dark") {
    DSSourceBadge(name: "有听网", health: .needAuth)
        .preferredColorScheme(.dark)
}

#Preview("AX") {
    DSSourceBadge(name: "悦听吧", health: .slow, latencyMs: 860)
        .environment(\.sizeCategory, .accessibilityExtraExtraLarge)
}
