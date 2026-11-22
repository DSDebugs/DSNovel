import DSCore
import DSDesignSystem
import SwiftUI

/// 发现页展示布局模式（1:1 复刻 v2.8 三态布局）
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
        case .grid: return "square.grid.2x2"
        case .largeCard: return "rectangle.grid.2x2"
        case .list: return "list.bullet"
        }
    }
}

/// 书源选择弹窗分组模型（在 VM 预计算，避免 View body 集合运算）
struct DiscoverSourceSection: Identifiable, Sendable {
    let id: String
    let title: String
    let sources: [SourceMetaDTO]
}

/// 发现页紧凑双行顶栏（1:1 复刻 v2.8 DiscoverHeaderBar：书源头像 + 胶囊源内搜索 + 3 态布局菜单 + 紧凑分类芯片条）
struct DiscoverHeaderBar: View {
    let currentSourceName: String
    @Binding var searchKeyword: String
    let isSearchActive: Bool
    @Binding var layoutStyle: DiscoverLayoutStyle
    let categoryChips: [DSChipItem<String>]
    let selectedCategoryID: String
    @FocusState.Binding var isSearchFocused: Bool

    private let onOpenSourcePicker: () -> Void
    private let onSubmitSearch: () -> Void
    private let onClearSearch: () -> Void
    private let onSelectCategory: (String) -> Void

    init(
        currentSourceName: String,
        searchKeyword: Binding<String>,
        isSearchActive: Bool,
        layoutStyle: Binding<DiscoverLayoutStyle>,
        categoryChips: [DSChipItem<String>],
        selectedCategoryID: String,
        isSearchFocused: FocusState<Bool>.Binding,
        onOpenSourcePicker: @escaping () -> Void,
        onSubmitSearch: @escaping () -> Void,
        onClearSearch: @escaping () -> Void,
        onSelectCategory: @escaping (String) -> Void
    ) {
        self.currentSourceName = currentSourceName
        self._searchKeyword = searchKeyword
        self.isSearchActive = isSearchActive
        self._layoutStyle = layoutStyle
        self.categoryChips = categoryChips
        self.selectedCategoryID = selectedCategoryID
        self._isSearchFocused = isSearchFocused
        self.onOpenSourcePicker = onOpenSourcePicker
        self.onSubmitSearch = onSubmitSearch
        self.onClearSearch = onClearSearch
        self.onSelectCategory = onSelectCategory
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

                Menu {
                    Picker("视图", selection: $layoutStyle) {
                        ForEach(DiscoverLayoutStyle.allCases) { style in
                            Text(style.title).tag(style)
                        }
                    }
                } label: {
                    Image(systemName: layoutStyle.iconName)
                        .font(DSTypography.body.weight(.medium))
                        .foregroundStyle(DSColors.inkPrimary)
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(DSColors.surfaceGrouped))
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Circle())
                }
                .tint(DSColors.inkPrimary)
                .buttonStyle(.plain)
                .accessibilityLabel("切换视图")
                .accessibilityIdentifier("discover.layoutSwitcher")
            }
            .padding(.horizontal, DSSpacing.pageHorizontal)

            if !isSearchActive && !categoryChips.isEmpty {
                DSChipBar(
                    items: categoryChips,
                    selection: Binding(
                        get: { selectedCategoryID },
                        set: { onSelectCategory($0) }
                    ),
                    isCompact: true
                )
            }
        }
        .padding(.top, 4)
        .padding(.bottom, 6)
        .background(.bar)
    }
}
