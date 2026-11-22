import DSCore
import DSDesignSystem
import SwiftUI

/// 发现页展示布局模式（1:1 复刻 v2.8 三态布局，单击循环切换）
enum DiscoverLayoutStyle: String, CaseIterable, Identifiable, Sendable {
    case grid
    case largeCard
    case list

    var id: String { rawValue }

    var title: String {
        switch self {
        case .grid: return "3列网格"
        case .largeCard: return "2列大图"
        case .list: return "列表"
        }
    }

    var iconName: String {
        switch self {
        case .grid: return "square.grid.3x3"
        case .largeCard: return "square.grid.2x2"
        case .list: return "list.bullet"
        }
    }

    var next: DiscoverLayoutStyle {
        switch self {
        case .grid: return .largeCard
        case .largeCard: return .list
        case .list: return .grid
        }
    }
}

/// 书源选择弹窗分组模型（在 VM 预计算，避免 View body 集合运算）
struct DiscoverSourceSection: Identifiable, Sendable {
    let id: String
    let title: String
    let sources: [SourceMetaDTO]
}

/// 发现页两级分类模型（1:1 复刻 v2.8：一级分类下拉 Menu + 二级分类横向 DSChipBar）
struct DiscoverCategorySection: Identifiable, Sendable {
    let id: Int
    let title: String
    let tabs: [DiscoverCategoryTab]
}

struct DiscoverCategoryTab: Identifiable, Sendable {
    let id: Int
    let category: DiscoverCategoryDTO
    let shortTitle: String
}

enum DiscoverCategoryGrouping {
    static func buildSections(from categories: [DiscoverCategoryDTO]) -> [DiscoverCategorySection] {
        guard !categories.isEmpty else { return [] }
        let hasGroups = categories.contains { !$0.groupTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if !hasGroups {
            let tabs = categories.enumerated().map { idx, cat in
                DiscoverCategoryTab(id: idx, category: cat, shortTitle: cat.title)
            }
            return [DiscoverCategorySection(id: 0, title: "分类", tabs: tabs)]
        }
        var order: [String] = []
        var grouped: [String: [DiscoverCategoryDTO]] = [:]
        for cat in categories {
            let rawGroup = cat.groupTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = rawGroup.isEmpty ? "其他" : rawGroup
            if grouped[key] == nil { order.append(key) }
            grouped[key, default: []].append(cat)
        }
        return order.enumerated().map { secIdx, groupName in
            let prefix = "\(groupName)·"
            let items = (grouped[groupName] ?? []).enumerated().map { tabIdx, cat in
                let short = cat.title.hasPrefix(prefix) ? String(cat.title.dropFirst(prefix.count)) : cat.title
                return DiscoverCategoryTab(id: tabIdx, category: cat, shortTitle: short.isEmpty ? cat.title : short)
            }
            return DiscoverCategorySection(id: secIdx, title: groupName, tabs: items)
        }
    }
}

/// 发现页紧凑双行顶栏（1:1 复刻 v2.8：书源头像 + 胶囊源内搜索 + 单击循环动效布局钮 + 一级下拉与二级标签栏）
struct DiscoverHeaderBar: View {
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.dsReduceMotion) private var appReduceMotion

    let currentSourceName: String
    @Binding var searchKeyword: String
    let isSearchActive: Bool
    @Binding var layoutStyle: DiscoverLayoutStyle
    let sectionChips: [DSChipItem<Int>]
    let tabChips: [DSChipItem<Int>]
    let selectedSectionIndex: Int
    let selectedTabIndex: Int
    let currentSectionTitle: String
    @FocusState.Binding var isSearchFocused: Bool

    private let onOpenSourcePicker: () -> Void
    private let onSubmitSearch: () -> Void
    private let onClearSearch: () -> Void
    private let onSelectSection: (Int) -> Void
    private let onSelectTab: (Int) -> Void

    init(
        currentSourceName: String,
        searchKeyword: Binding<String>,
        isSearchActive: Bool,
        layoutStyle: Binding<DiscoverLayoutStyle>,
        sectionChips: [DSChipItem<Int>],
        tabChips: [DSChipItem<Int>],
        selectedSectionIndex: Int,
        selectedTabIndex: Int,
        currentSectionTitle: String,
        isSearchFocused: FocusState<Bool>.Binding,
        onOpenSourcePicker: @escaping () -> Void,
        onSubmitSearch: @escaping () -> Void,
        onClearSearch: @escaping () -> Void,
        onSelectSection: @escaping (Int) -> Void,
        onSelectTab: @escaping (Int) -> Void
    ) {
        self.currentSourceName = currentSourceName
        self._searchKeyword = searchKeyword
        self.isSearchActive = isSearchActive
        self._layoutStyle = layoutStyle
        self.sectionChips = sectionChips
        self.tabChips = tabChips
        self.selectedSectionIndex = selectedSectionIndex
        self.selectedTabIndex = selectedTabIndex
        self.currentSectionTitle = currentSectionTitle
        self._isSearchFocused = isSearchFocused
        self.onOpenSourcePicker = onOpenSourcePicker
        self.onSubmitSearch = onSubmitSearch
        self.onClearSearch = onClearSearch
        self.onSelectSection = onSelectSection
        self.onSelectTab = onSelectTab
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                Button(action: onOpenSourcePicker) {
                    DSSourceAvatar(name: currentSourceName, size: 38)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("切换书源，当前：\(currentSourceName)")
                .accessibilityIdentifier("discover.sourceSwitcher")

                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(DSTypography.caption)
                        .foregroundStyle(DSColors.inkSecondary)

                    TextField("在「\(currentSourceName)」中搜索", text: $searchKeyword)
                        .focused($isSearchFocused)
                        .font(DSTypography.subtitle)
                        .submitLabel(.search)
                        .textContentType(nil)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit(onSubmitSearch)
                        .accessibilityIdentifier("discover.searchField")

                    if !searchKeyword.isEmpty || isSearchActive {
                        Button(action: onClearSearch) {
                            Image(systemName: "xmark.circle.fill")
                                .font(DSTypography.caption)
                                .foregroundStyle(.tertiary)
                                .frame(minWidth: 44, minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("清除源内搜索")
                    }
                }
                .padding(.horizontal, DSSpacing.sm)
                .frame(minHeight: 44)
                .background(Capsule().fill(DSColors.surfaceGrouped))

                if isSearchFocused || isSearchActive {
                    Button {
                        DSHaptics.selection()
                        isSearchFocused = false
                        onClearSearch()
                    } label: {
                        Text("取消")
                            .font(DSTypography.body)
                            .foregroundStyle(DSColors.accent)
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("取消搜索")
                    .accessibilityIdentifier("discover.searchCancel")
                } else {
                    Button {
                        DSHaptics.selection()
                        let reduceMotion = systemReduceMotion || appReduceMotion
                        DSMotion.withResolved(DSMotion.snappy, reduceMotion: reduceMotion) {
                            layoutStyle = layoutStyle.next
                        }
                    } label: {
                        Image(systemName: layoutStyle.iconName)
                            .font(DSTypography.body.weight(.medium))
                            .foregroundStyle(DSColors.inkPrimary)
                            .contentTransition(.symbolEffect(.replace.downUp.byLayer))
                            .symbolEffect(.bounce, value: layoutStyle)
                            .frame(width: 38, height: 38)
                            .background(Circle().fill(DSColors.surfaceGrouped))
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.dsCard)
                    .accessibilityLabel("切换布局，当前：\(layoutStyle.title)，点击切换至\(layoutStyle.next.title)")
                    .accessibilityIdentifier("discover.layoutSwitcher")
                }
            }
            .padding(.horizontal, DSSpacing.pageHorizontal)

            if !isSearchActive {
                singleRowCategoryBar
            }
        }
        .padding(.top, 4)
        .padding(.bottom, 6)
        .background(.bar)
    }

    @ViewBuilder
    private var singleRowCategoryBar: some View {
        if sectionChips.count > 1 && tabChips.count > 1 {
            HStack(spacing: DSSpacing.xs) {
                Menu {
                    ForEach(sectionChips) { sec in
                        Button {
                            onSelectSection(sec.id)
                        } label: {
                            HStack {
                                Text(sec.title)
                                if sec.id == selectedSectionIndex {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(currentSectionTitle)
                            .font(DSTypography.subtitle.weight(.semibold))
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(DSTypography.caption2.weight(.semibold))
                    }
                    .foregroundStyle(DSColors.accent)
                    .padding(.horizontal, DSSpacing.sm)
                    .frame(minHeight: 34)
                    .background(Capsule().fill(DSColors.accent.opacity(0.14)))
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .tint(DSColors.accent)
                .buttonStyle(.plain)
                .accessibilityLabel("切换一级分类，当前：\(currentSectionTitle)")
                .padding(.leading, DSSpacing.pageHorizontal)

                Divider()
                    .frame(height: 18)

                DSChipBar(
                    items: tabChips,
                    selection: Binding(
                        get: { selectedTabIndex },
                        set: { onSelectTab($0) }
                    ),
                    isCompact: true,
                    leadingPadding: DSSpacing.xxs
                )
            }
        } else if sectionChips.count > 1 {
            DSChipBar(
                items: sectionChips,
                selection: Binding(
                    get: { selectedSectionIndex },
                    set: { onSelectSection($0) }
                ),
                isCompact: true
            )
        } else if tabChips.count > 1 {
            DSChipBar(
                items: tabChips,
                selection: Binding(
                    get: { selectedTabIndex },
                    set: { onSelectTab($0) }
                ),
                isCompact: true
            )
        }
    }
}
