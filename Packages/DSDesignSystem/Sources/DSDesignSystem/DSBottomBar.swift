import SwiftUI

/// 3 个主导航 Tab（首页 / 书架 / 设置）
public enum DSMainTab: String, CaseIterable, Sendable, Identifiable {
    case discover
    case library
    case me

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .discover: return "首页"
        case .library: return "书架"
        case .me: return "设置"
        }
    }

    public var icon: String {
        switch self {
        case .discover: return "house"
        case .library: return "books.vertical"
        case .me: return "gearshape"
        }
    }
}

/// 一体化超薄单胶囊底部悬浮栏（54pt 高：高对比度磨砂单胶囊 + 3 Tab 赤陶圆点指示 + 竖线内嵌迷你播放控制 + 克制底部渐隐羽化）
public struct DSBottomBar<CenterSlot: View>: View {
    public static var totalHeight: CGFloat { 58 }

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
        ZStack(alignment: .bottom) {
            LinearGradient(
                colors: [
                    DSColors.surfaceBase.opacity(0),
                    DSColors.surfaceBase.opacity(0.68),
                    DSColors.surfaceBase.opacity(0.95)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 82)
            .allowsHitTesting(false)
            .ignoresSafeArea(edges: .bottom)

            HStack(spacing: 0) {
                HStack(spacing: 0) {
                    tabButton(.discover, badge: 0)
                    tabButton(.library, badge: libraryBadge)
                    tabButton(.me, badge: meBadge)
                }
                .frame(maxWidth: .infinity)

                Rectangle()
                    .fill(DSColors.separator.opacity(0.45))
                    .frame(width: 0.6, height: 24)
                    .padding(.horizontal, DSSpacing.xs)

                centerSlot()
                    .padding(.trailing, DSSpacing.xs)
            }
            .padding(.leading, DSSpacing.xs)
            .padding(.trailing, DSSpacing.xxs)
            .frame(maxWidth: .infinity, minHeight: 54, maxHeight: 54)
            .background {
                Capsule(style: .continuous)
                    .fill(DSColors.surfaceCard.opacity(0.92))
                    .glassEffect(.regular, in: Capsule(style: .continuous))
                    .shadow(color: .black.opacity(0.24), radius: 14, y: 5)
            }
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(DSColors.separator.opacity(0.32), lineWidth: 0.6)
            )
            .padding(.horizontal, DSSpacing.pageHorizontal)
            .padding(.bottom, DSSpacing.xxs)
        }
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
                    .frame(height: 20)
                    .padding(.top, 2)
                    .padding(.horizontal, 10)
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

                Circle()
                    .fill(active ? DSColors.accent : Color.clear)
                    .frame(width: 4, height: 4)
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
