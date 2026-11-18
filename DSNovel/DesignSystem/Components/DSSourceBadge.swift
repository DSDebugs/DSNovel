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

struct DSSourceAvatar: View {
    let name: String
    let size: CGFloat

    init(name: String, size: CGFloat = 32) {
        self.name = name
        self.size = size
    }

    private var initialText: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "源" }
        return String(first)
    }

    var body: some View {
        Text(initialText)
            .font(size >= 30 ? DSTypography.cardTitle : DSTypography.caption.weight(.bold))
            .foregroundStyle(Color.dsOnAccent)
            .frame(width: size, height: size)
            .background(Circle().fill(Color.dsAccent))
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

    var body: some View {
        HStack(spacing: Spacing.s1) {
            DSSourceAvatar(name: name, size: 20)

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
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(.horizontal, Spacing.s2)
        .padding(.vertical, 5)
        .background(
            Capsule(style: .continuous)
                .fill(Color.dsSurfaceGrouped)
        )
    }
}
