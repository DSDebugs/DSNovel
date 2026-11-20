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

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s2) {
            HStack {
                Text("内置解析")
                    .font(DSTypography.rowTitle)
                Spacer()
                if let rec = matchedRecord {
                    DSBadge(rec.isEnabled ? "已安装 · 正常" : "已停用", style: rec.isEnabled ? .success : .neutral)
                } else {
                    DSBadge("未安装", style: .neutral)
                }
            }

            if let rec = matchedRecord {
                Text("\(rec.name) v\(rec.version)")
                    .font(DSTypography.subtitle)
                    .foregroundStyle(.secondary)
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
