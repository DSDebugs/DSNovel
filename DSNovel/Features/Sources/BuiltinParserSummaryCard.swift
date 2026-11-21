import SwiftUI
import SwiftData

struct BuiltinParserSummaryCard: View {
    let plugin: PluginRecord
    let isHighlighted: Bool
    @Query(sort: [SortDescriptor(\BuiltinParserRecord.importedAt, order: .reverse)])
    private var records: [BuiltinParserRecord]

    init(plugin: PluginRecord, isHighlighted: Bool = false) {
        self.plugin = plugin
        self.isHighlighted = isHighlighted
    }

    private var matchedRecord: BuiltinParserRecord? {
        records.first { record in
            BuiltinParserTargets(hosts: record.targetHostList, sourceIDs: record.targetSourceIDList)
                .matches(sourceID: plugin.id, sourceURL: plugin.siteURL)
        }
    }

    /// 10-2：根据真实启用态与 lastCheckStatus 映射红/黄/绿状态徽标，不再硬编码绿色「正常」
    static func statusBadge(isEnabled: Bool, lastCheckStatus: String) -> (text: String, style: DSBadgeStyle) {
        guard isEnabled else {
            return ("已停用", .neutral)
        }
        switch lastCheckStatus.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "ok", "healthy":
            return ("已安装 · 正常", .success)
        case "failed", "error", "unavailable":
            return ("已安装 · 异常", .danger)
        case "slow", "warning", "degraded":
            return ("已安装 · 较慢", .warning)
        default:
            return ("已安装 · 待自检", .warning)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s2) {
            HStack {
                Text("内置解析")
                    .font(DSTypography.rowTitle)
                Spacer()
                if let rec = matchedRecord {
                    let badge = Self.statusBadge(isEnabled: rec.isEnabled, lastCheckStatus: rec.lastCheckStatus)
                    DSBadge(badge.text, style: badge.style)
                } else {
                    DSBadge("未安装", style: .neutral)
                }
            }

            if let rec = matchedRecord {
                Text("\(rec.name) v\(rec.version)")
                    .font(DSTypography.subtitle)
                    .foregroundStyle(.secondary)
                if rec.isEnabled,
                   ["failed", "error", "unavailable"].contains(rec.lastCheckStatus.lowercased()),
                   !rec.lastCheckMessage.isEmpty {
                    Text(rec.lastCheckMessage)
                        .font(DSTypography.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
                if !rec.lastAccountNickname.isEmpty || !rec.lastAccountExpireAt.isEmpty {
                    Text([rec.lastAccountNickname, rec.lastAccountExpireAt].compactMap { $0.isEmpty ? nil : $0 }.joined(separator: " · 到期 "))
                        .font(DSTypography.caption)
                        .foregroundStyle(.secondary)
                }
            }

            NavigationLink {
                Form {
                    BuiltinParserSection(plugin: plugin)
                }
                .navigationTitle("管理内置解析")
            } label: {
                Text("管理")
                    .font(DSTypography.cardTitle)
                    .foregroundStyle(Color.dsAccent)
            }
        }
        .padding(.vertical, Spacing.s2)
        .overlay(
            RoundedRectangle(cornerRadius: Radius.card)
                .strokeBorder(isHighlighted ? Color.dsAccent : Color.clear, lineWidth: 1.5)
        )
    }
}
