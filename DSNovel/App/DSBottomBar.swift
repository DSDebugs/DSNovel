import SwiftUI

struct DSBottomBar: View {
    @Binding var selectedTab: ShellTab
    let libraryBadge: Int
    let meBadge: Int
    let player: PlayerEngine
    let continueBook: Book?
    private let onReselectTab: (ShellTab) -> Void
    private let onOpenFullPlayer: () -> Void

    init(
        selectedTab: Binding<ShellTab>,
        libraryBadge: Int,
        meBadge: Int,
        player: PlayerEngine = .shared,
        continueBook: Book? = nil,
        onReselectTab: @escaping (ShellTab) -> Void,
        onOpenFullPlayer: @escaping () -> Void
    ) {
        self._selectedTab = selectedTab
        self.libraryBadge = libraryBadge
        self.meBadge = meBadge
        self.player = player
        self.continueBook = continueBook
        self.onReselectTab = onReselectTab
        self.onOpenFullPlayer = onOpenFullPlayer
    }

    var body: some View {
        HStack(spacing: 0) {
            tabButton(for: .discover, badge: 0)
            tabButton(for: .search, badge: 0)

            MiniPlayer(
                player: player,
                continueBook: continueBook,
                onOpenFullPlayer: onOpenFullPlayer,
                onFallbackDiscover: { selectedTab = .discover }
            )
            .frame(maxWidth: .infinity)

            tabButton(for: .library, badge: libraryBadge)
            tabButton(for: .me, badge: meBadge)
        }
        .padding(.horizontal, Spacing.s3)
        .frame(height: 60)
        .background {
            Capsule(style: .continuous)
                .fill(.regularMaterial)
                .glassEffect(.regular, in: Capsule(style: .continuous))
                .shadow(color: .black.opacity(0.10), radius: 12, y: 4)
        }
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(Color.dsSeparator.opacity(0.25), lineWidth: 0.5)
        )
        .padding(.horizontal, Spacing.pageHorizontal)
        .padding(.bottom, Spacing.s1)
    }

    private func tabButton(for tab: ShellTab, badge: Int) -> some View {
        let isSelected = (selectedTab == tab)
        return Button {
            if isSelected {
                onReselectTab(tab)
            } else {
                DSHapticPolicy.fire(.selection)
                selectedTab = tab
            }
        } label: {
            VStack(spacing: 2) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: tab.icon)
                        .font(.body.weight(isSelected ? .semibold : .regular))
                        .symbolVariant(isSelected ? .fill : .none)
                        .frame(height: 22)

                    if badge > 0 {
                        Text(badge > 99 ? "99+" : "\(badge)")
                            .font(DSTypography.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .frame(minWidth: 16, minHeight: 16)
                            .background(Capsule().fill(Color.red))
                            .offset(x: 10, y: -4)
                    }
                }
                Text(tab.title)
                    .font(DSTypography.caption2.weight(isSelected ? .semibold : .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? Color.dsAccent : .secondary)
            .frame(maxWidth: .infinity, minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("tab.\(tab.rawValue)")
        .accessibilityLabel(tab.title)
    }
}
