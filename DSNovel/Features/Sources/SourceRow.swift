import SwiftUI

struct SourceRow: View {
    let source: PluginRecord
    let isChecking: Bool
    let isBatchSelecting: Bool
    let isSelected: Bool
    private let onSelect: () -> Void

    init(
        source: PluginRecord,
        isChecking: Bool = false,
        isBatchSelecting: Bool = false,
        isSelected: Bool = false,
        onSelect: @escaping () -> Void
    ) {
        self.source = source
        self.isChecking = isChecking
        self.isBatchSelecting = isBatchSelecting
        self.isSelected = isSelected
        self.onSelect = onSelect
    }

    private var displayStatus: SourceDisplayStatus {
        SourceDisplayStatus.classify(source)
    }

    private var statusBadgeColor: Color {
        switch displayStatus {
        case .available:
            return source.healthState == .slow ? .yellow : .green
        case .needAuth:
            return .orange
        case .unavailable:
            return .red
        case .untested, .disabled:
            return .secondary
        }
    }

    private var statusIconName: String {
        switch displayStatus {
        case .available:
            return source.healthState == .slow ? "tortoise.fill" : "checkmark.circle.fill"
        case .needAuth:
            return "person.badge.key"
        case .unavailable:
            return "exclamationmark.triangle.fill"
        case .untested:
            return "circle.dashed"
        case .disabled:
            return "pause.circle"
        }
    }

    private var statusTitle: String {
        if displayStatus == .available && source.healthState == .slow {
            return "较慢"
        }
        return displayStatus.title
    }

    private var subtitleText: String {
        var parts: [String] = ["v\(source.version)"]
        if source.lastLatencyMs > 0 && source.isEnabled {
            parts.append("延迟 \(source.lastLatencyMs) ms")
        }
        if source.requiresLogin && source.loggedIn {
            parts.append("已登录")
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: Spacing.s3) {
                if isBatchSelecting {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(isSelected ? Color.dsAccent : .secondary)
                }

                DSSourceAvatar(name: source.name, size: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text(source.name)
                        .font(DSTypography.rowTitle)
                        .foregroundStyle(source.isEnabled ? .primary : .secondary)
                        .lineLimit(1)
                    Text(subtitleText)
                        .font(DSTypography.numericCaption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: Spacing.s2)

                if isChecking {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    HStack(spacing: 4) {
                        Image(systemName: statusIconName)
                            .font(DSTypography.caption2)
                        Text(statusTitle)
                            .font(DSTypography.caption.weight(.medium))
                    }
                    .foregroundStyle(statusBadgeColor)
                    .fixedSize(horizontal: true, vertical: false)
                }
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
