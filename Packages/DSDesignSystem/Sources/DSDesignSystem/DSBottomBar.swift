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

/// 固定单层 5 槽液态玻璃底部导航栏（UI-01/AUD-22：纳入 safeAreaInset 自适应 AX3–AX5 高度并忽略底部键盘安全区）
public struct DSBottomBar<CenterSlot: View>: View {
    public static let totalHeight: CGFloat = 64

    private let selectedTab: DSMainTab
    private let onSelectTab: (DSMainTab) -> Void
    private let centerSlot: () -> CenterSlot

    public init(
        selectedTab: DSMainTab,
        onSelectTab: @escaping (DSMainTab) -> Void,
        @ViewBuilder centerSlot: @escaping () -> CenterSlot
    ) {
        self.selectedTab = selectedTab
        self.onSelectTab = onSelectTab
        self.centerSlot = centerSlot
    }

    public var body: some View {
        HStack(spacing: 0) {
            tabButton(.discover)
            tabButton(.search)
            centerSlot()
                .frame(maxWidth: .infinity, minHeight: 48)
            tabButton(.library)
            tabButton(.me)
        }
        .padding(.vertical, DSSpacing.xxs)
        .frame(minHeight: Self.totalHeight)
        .padding(.horizontal, DSSpacing.xs)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: DSRadius.lg, style: .continuous))
        .shadow(color: .black.opacity(0.10), radius: 12, y: 4)
        .padding(.horizontal, DSSpacing.sm)
        .padding(.top, DSSpacing.xxs)
        .padding(.bottom, DSSpacing.xs)
        .ignoresSafeArea(.keyboard, edges: .bottom)
    }

    private func tabButton(_ tab: DSMainTab) -> some View {
        let active = (selectedTab == tab)
        return Button {
            onSelectTab(tab)
        } label: {
            VStack(spacing: 3) {
                Image(systemName: tab.icon)
                    .font(DSTypography.headline)
                Text(tab.title)
                    .font(DSTypography.caption)
                    .lineLimit(1)
            }
            .foregroundStyle(active ? DSColors.accent : DSColors.inkSecondary)
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab.title)
        .accessibilityIdentifier("tab_\(tab.rawValue)")
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}
