import SwiftUI

struct DiscoverHeaderBar: View {
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

    private var layoutIconName: String {
        switch layoutStyle {
        case .grid: return "square.grid.2x2"
        case .largeCard: return "rectangle.grid.2x2"
        case .list: return "list.bullet"
        }
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
                        .foregroundStyle(.secondary)

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
                .padding(.horizontal, Spacing.s3)
                .frame(minHeight: 44)
                .background(Capsule().fill(Color.dsSurfaceGrouped))

                Menu {
                    Picker("视图", selection: $layoutStyle) {
                        ForEach(DiscoverLayoutStyle.allCases) { style in
                            Text(style.title).tag(style)
                        }
                    }
                } label: {
                    Image(systemName: layoutIconName)
                        .font(DSTypography.body.weight(.medium))
                        .foregroundStyle(.primary)
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(Color.dsSurfaceGrouped))
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Circle())
                }
                .tint(.primary)
                .buttonStyle(.plain)
                .accessibilityLabel("切换视图")
                .accessibilityIdentifier("discover.layoutSwitcher")
            }
            .padding(.horizontal, Spacing.pageHorizontal)

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
            HStack(spacing: Spacing.s2) {
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
                    .foregroundStyle(Color.dsAccent)
                    .padding(.horizontal, Spacing.s3)
                    .frame(minHeight: 34)
                    .background(Capsule().fill(Color.dsAccent.opacity(0.14)))
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .tint(Color.dsAccent)
                .buttonStyle(.plain)
                .accessibilityLabel("切换一级分类，当前：\(currentSectionTitle)")
                .padding(.leading, Spacing.pageHorizontal)

                Divider()
                    .frame(height: 18)

                DSChipBar(
                    items: tabChips,
                    selection: Binding(
                        get: { selectedTabIndex },
                        set: { onSelectTab($0) }
                    ),
                    isCompact: true,
                    leadingPadding: Spacing.s1
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
