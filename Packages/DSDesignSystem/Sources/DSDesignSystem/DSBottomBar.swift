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

/// 一体化单胶囊底部悬浮栏（54pt 高：保持原布局不变，启用 iOS 26 原生 Liquid Glass `.glassEffect(.regular.interactive())` 真实光学折射与按压微光）
public struct DSBottomBar<CenterSlot: View>: View {
    @Environment(\.dsAccentTheme) private var accentTheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
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

    private var barContent: some View {
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
    }

    public var body: some View {
        let _ = accentTheme
        Group {
            if reduceTransparency {
                barContent
                    .background(
                        Capsule(style: .continuous)
                            .fill(DSColors.surfaceCard)
                            .overlay(
                                Capsule(style: .continuous)
                                    .strokeBorder(DSColors.separator.opacity(0.28), lineWidth: 0.5)
                            )
                    )
            } else {
                barContent
                    .glassEffect(.regular.interactive(), in: Capsule(style: .continuous))
            }
        }
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
