import SwiftUI

struct SearchScopeBar: View {
    @Binding var selectedScope: SearchScopeSelection
    let groups: [PluginGroup]
    let activeSourceCount: Int
    private let onManageSources: () -> Void

    init(
        selectedScope: Binding<SearchScopeSelection>,
        groups: [PluginGroup],
        activeSourceCount: Int,
        onManageSources: @escaping () -> Void
    ) {
        self._selectedScope = selectedScope
        self.groups = groups
        self.activeSourceCount = activeSourceCount
        self.onManageSources = onManageSources
    }

    private var scopeChips: [DSChipItem<SearchScopeSelection>] {
        var list: [DSChipItem<SearchScopeSelection>] = [
            DSChipItem(id: .all, title: "全部书源"),
            DSChipItem(id: .currentDiscover, title: "当前发现书源")
        ]
        for g in groups {
            list.append(DSChipItem(id: .group(g.id), title: g.name))
        }
        return list
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s2) {
            DSChipBar(
                items: scopeChips,
                selection: $selectedScope,
                trailingActionTitle: "已选 \(activeSourceCount) 个书源",
                onTrailingAction: onManageSources
            )
        }
    }
}
