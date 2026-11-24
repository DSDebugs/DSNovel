import DSCore
import DSDesignSystem
import SwiftUI

/// 首页展示布局模式（三态布局，单击循环切换）
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

/// 首页融合顶栏（浏览态：书源头像 + 胶囊搜索框 + 布局钮 + 两级分类；搜索态：展开搜索框 + 清空 × + 取消）
struct DiscoverHeaderBar: View {
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.dsReduceMotion) private var appReduceMotion

    let currentSourceName: String
    @Binding var searchKeyword: String
    let isSearchMode: Bool
    @Binding var layoutStyle: DiscoverLayoutStyle
    let sectionChips: [DSChipItem<Int>]
    let tabChips: [DSChipItem<Int>]
    let subTabChips: [DSChipItem<Int>]
    let selectedSectionIndex: Int
    let selectedTabIndex: Int
    let selectedSubTabIndex: Int
    let currentSectionTitle: String
    @FocusState.Binding var isSearchFocused: Bool

    private let onOpenSourcePicker: () -> Void
    private let onSubmitSearch: () -> Void
    private let onClearKeyword: () -> Void
    private let onCancelSearch: () -> Void
    private let onSelectSection: (Int) -> Void
    private let onSelectTab: (Int) -> Void
    private let onSelectSubTab: (Int) -> Void

    init(
        currentSourceName: String,
        searchKeyword: Binding<String>,
        isSearchMode: Bool,
        layoutStyle: Binding<DiscoverLayoutStyle>,
        sectionChips: [DSChipItem<Int>],
        tabChips: [DSChipItem<Int>],
        subTabChips: [DSChipItem<Int>] = [],
        selectedSectionIndex: Int,
        selectedTabIndex: Int,
        selectedSubTabIndex: Int = 0,
        currentSectionTitle: String,
        isSearchFocused: FocusState<Bool>.Binding,
        onOpenSourcePicker: @escaping () -> Void,
        onSubmitSearch: @escaping () -> Void,
        onClearKeyword: @escaping () -> Void,
        onCancelSearch: @escaping () -> Void,
        onSelectSection: @escaping (Int) -> Void,
        onSelectTab: @escaping (Int) -> Void,
        onSelectSubTab: @escaping (Int) -> Void = { _ in }
    ) {
        self.currentSourceName = currentSourceName
        self._searchKeyword = searchKeyword
        self.isSearchMode = isSearchMode
        self._layoutStyle = layoutStyle
        self.sectionChips = sectionChips
        self.tabChips = tabChips
        self.subTabChips = subTabChips
        self.selectedSectionIndex = selectedSectionIndex
        self.selectedTabIndex = selectedTabIndex
        self.selectedSubTabIndex = selectedSubTabIndex
        self.currentSectionTitle = currentSectionTitle
        self._isSearchFocused = isSearchFocused
        self.onOpenSourcePicker = onOpenSourcePicker
        self.onSubmitSearch = onSubmitSearch
        self.onClearKeyword = onClearKeyword
        self.onCancelSearch = onCancelSearch
        self.onSelectSection = onSelectSection
        self.onSelectTab = onSelectTab
        self.onSelectSubTab = onSelectSubTab
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 0) {
                Button(action: onOpenSourcePicker) {
                    DSSourceAvatar(name: currentSourceName, size: 38)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("切换书源，当前：\(currentSourceName)")
                .accessibilityIdentifier("discover.sourceSwitcher")
                .frame(width: isSearchMode ? 0 : 44, height: 44)
                .padding(.trailing, isSearchMode ? 0 : 10)
                .opacity(isSearchMode ? 0 : 1)
                .clipped()
                .allowsHitTesting(!isSearchMode)
                .accessibilityHidden(isSearchMode)

                HStack(spacing: 6) {
                    Button {
                        if !isSearchFocused { isSearchFocused = true }
                    } label: {
                        Image(systemName: "magnifyingglass")
                            .font(DSTypography.caption)
                            .foregroundStyle(DSColors.inkSecondary)
                            .frame(minWidth: 24, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHidden(true)

                    TextField("搜索书名、作者或演播", text: $searchKeyword)
                        .focused($isSearchFocused)
                        .font(DSTypography.subtitle)
                        .submitLabel(.search)
                        .textContentType(nil)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit(onSubmitSearch)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .id("discover.search.textfield.stable")
                        .accessibilityIdentifier("discover.searchField")

                    if !searchKeyword.isEmpty {
                        Button {
                            DSHaptics.selection()
                            searchKeyword = ""
                            onClearKeyword()
                            isSearchFocused = true
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(DSTypography.caption)
                                .foregroundStyle(.tertiary)
                                .frame(minWidth: 44, minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("清除输入内容")
                    }
                }
                .padding(.horizontal, DSSpacing.sm)
                .frame(minHeight: 44)
                .background(Capsule().fill(DSColors.surfaceGrouped))
                .padding(.trailing, 10)

                if isSearchMode {
                    Button {
                        DSHaptics.selection()
                        isSearchFocused = false
                        onCancelSearch()
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

            if !isSearchMode {
                singleRowCategoryBar
                if subTabChips.count > 1 {
                    DSChipBar(
                        items: subTabChips,
                        selection: Binding(
                            get: { selectedSubTabIndex },
                            set: { onSelectSubTab($0) }
                        ),
                        isCompact: true
                    )
                    .accessibilityIdentifier("discover.subTabBar")
                }
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
