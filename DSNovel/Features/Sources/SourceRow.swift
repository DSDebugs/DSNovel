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

    private var healthKind: DSSourceHealthKind {
        DSSourceHealthKind(rawValue: source.lastCheckStatus) ?? .untested
    }

    private var subtitleText: String {
        var parts: [String] = ["v\(source.version)"]
        if source.lastLatencyMs > 0 {
            parts.append("延迟 \(source.lastLatencyMs) ms")
        }
        if !source.isEnabled {
            parts.append("已停用")
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

                DSSourceBadge(
                    name: source.name,
                    health: healthKind,
                    latencyMs: source.lastLatencyMs > 0 ? source.lastLatencyMs : nil
                )

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

                Spacer()

                if isChecking {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: healthKind.iconName)
                        .foregroundStyle(healthKind.statusColor)
                        .symbolEffect(.pulse, isActive: isChecking)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
