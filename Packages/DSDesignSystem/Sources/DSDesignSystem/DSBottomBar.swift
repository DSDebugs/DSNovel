import SwiftUI

/// 4 个主导航 Tab（居中叠加第 5 槽：迷你旋转封面直达全屏播放器）
public enum DSMainTab: String, CaseIterable, Sendable, Identifiable {
    case discover
    case search
    case library
    case me

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .discover: return "发现"
        case .search: return "搜索"
        case .library: return "书籍"
        case .me: return "我的"
        }
    }

    public var icon: String {
        switch self {
        case .discover: return "safari"
        case .search: return "magnifyingglass"
        case .library: return "books.vertical"
        case .me: return "person.crop.circle"
        }
    }
}

/// 固定单层 5 槽全胶囊液态玻璃底部导航栏（1:1 复刻 v2.8 `DSBottomBar`）
public struct DSBottomBar<CenterSlot: View>: View {
    public static var totalHeight: CGFloat { 64 }

    private let selectedTab: DSMainTab
    private let libraryBadge: Int
    private let meBadge: Int
    private let onSelectTab: (DSMainTab) -> Void
    private let centerSlot: () -> CenterSlot

    public init(
        selectedTab: DSMainTab,
        libraryBadge: Int = 0,
        meBadge: Int = 0,
        onSelectTab: @escaping (DSMainTab) -> Void,
        @ViewBuilder centerSlot: @escaping () -> CenterSlot
    ) {
        self.selectedTab = selectedTab
        self.libraryBadge = libraryBadge
        self.meBadge = meBadge
        self.onSelectTab = onSelectTab
        self.centerSlot = centerSlot
    }

    public var body: some View {
        HStack(spacing: 0) {
            tabButton(.discover, badge: 0)
            tabButton(.search, badge: 0)
            centerSlot()
                .frame(maxWidth: .infinity, minHeight: 48)
            tabButton(.library, badge: libraryBadge)
            tabButton(.me, badge: meBadge)
        }
        .padding(.horizontal, DSSpacing.sm)
        .frame(minHeight: 60)
        .background {
            Capsule(style: .continuous)
                .fill(Color.clear)
                .glassEffect(.regular, in: Capsule(style: .continuous))
                .shadow(color: .black.opacity(0.10), radius: 12, y: 4)
        }
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(DSColors.separator.opacity(0.25), lineWidth: 0.5)
        )
        .padding(.horizontal, DSSpacing.pageHorizontal)
        .padding(.bottom, DSSpacing.xxs)
        .ignoresSafeArea(.keyboard, edges: .bottom)
    }

    private func tabButton(_ tab: DSMainTab, badge: Int) -> some View {
        let active = (selectedTab == tab)
        return Button {
            if !active {
                DSHaptics.selection()
            }
            onSelectTab(tab)
        } label: {
            VStack(spacing: 2) {
                Image(systemName: tab.icon)
                    .font(.body.weight(active ? .semibold : .regular))
                    .symbolVariant(active ? .fill : .none)
                    .frame(height: 22)
                    .padding(.top, 4)
                    .padding(.horizontal, 12)
                    .overlay(alignment: .topTrailing) {
                        if badge > 0 {
                            Text(badge > 99 ? "99+" : "\(badge)")
                                .font(DSTypography.caption2.weight(.bold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                                .padding(.horizontal, 4)
                                .frame(minWidth: 16, minHeight: 16)
                                .background(Capsule().fill(Color.red))
                                .accessibilityHidden(true)
                        }
                    }

                Text(tab.title)
                    .font(DSTypography.caption2.weight(active ? .semibold : .medium))
                    .lineLimit(1)
                    .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            }
            .foregroundStyle(active ? DSColors.accent : DSColors.inkSecondary)
            .frame(maxWidth: .infinity, minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab.title)
        .accessibilityValue(badge > 0 ? "\(badge) 条提醒" : "")
        .accessibilityIdentifier("tab_\(tab.rawValue)")
        .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
    }
}
