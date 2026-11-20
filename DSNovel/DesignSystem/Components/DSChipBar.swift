import SwiftUI

struct DSChipItem<ID: Hashable>: Identifiable, Equatable {
    let id: ID
    let title: String
    let count: Int?

    init(id: ID, title: String, count: Int? = nil) {
        self.id = id
        self.title = title
        self.count = count
    }
}

struct DSChipBar<ID: Hashable>: View {
    @Environment(\.sizeCategory) private var sizeCategory
    @Environment(\.dsReduceMotion) private var reduceMotion
    @Namespace private var chipNamespace

    let items: [DSChipItem<ID>]
    @Binding var selection: ID
    let isCompact: Bool
    let leadingPadding: CGFloat
    private let trailingActionTitle: String?
    private let onTrailingAction: (() -> Void)?

    init(
        items: [DSChipItem<ID>],
        selection: Binding<ID>,
        isCompact: Bool = false,
        leadingPadding: CGFloat = Spacing.pageHorizontal,
        trailingActionTitle: String? = nil,
        onTrailingAction: (() -> Void)? = nil
    ) {
        self.items = items
        self._selection = selection
        self.isCompact = isCompact
        self.leadingPadding = leadingPadding
        self.trailingActionTitle = trailingActionTitle
        self.onTrailingAction = onTrailingAction
    }

    var body: some View {
        Group {
            if sizeCategory.isAccessibilityCategory {
                VStack(alignment: .leading, spacing: Spacing.s2) {
                    ForEach(items) { item in
                        chipButton(for: item)
                    }
                    if let trailingActionTitle, let onTrailingAction {
                        trailingActionButton(title: trailingActionTitle, action: onTrailingAction)
                    }
                }
                .padding(.horizontal, Spacing.pageHorizontal)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: Spacing.s2) {
                            ForEach(items) { item in
                                chipButton(for: item)
                                    .id(item.id)
                            }
                            if let trailingActionTitle, let onTrailingAction {
                                trailingActionButton(title: trailingActionTitle, action: onTrailingAction)
                            }
                        }
                        .padding(.leading, leadingPadding)
                        .padding(.trailing, Spacing.pageHorizontal)
                    }
                    .onChange(of: selection) { _, newValue in
                        withAnimation(Motion.resolve(Motion.snappy, reduce: reduceMotion)) {
                            proxy.scrollTo(newValue, anchor: .center)
                        }
                    }
                }
            }
        }
        .dsHaptic(.selection, trigger: selection)
    }

    private func trailingActionButton(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(DSTypography.subtitle.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, Spacing.s3)
                .padding(.vertical, Spacing.s2)
                .frame(minHeight: 36)
                .background(
                    Capsule(style: .continuous)
                        .strokeBorder(Color.dsSeparator.opacity(0.5), lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
    }

    private func chipButton(for item: DSChipItem<ID>) -> some View {
        let isSelected = selection == item.id
        return Button {
            withAnimation(Motion.resolve(Motion.snappy, reduce: reduceMotion)) {
                selection = item.id
            }
        } label: {
            HStack(spacing: Spacing.s1) {
                Text(item.title)
                    .font(DSTypography.subtitle.weight(isSelected ? .semibold : .medium))
                if let count = item.count {
                    Text("\(count)")
                        .font(DSTypography.numericCaption)
                }
            }
            .foregroundStyle(isSelected ? Color.dsOnAccent : .primary)
            .padding(.horizontal, Spacing.s3)
            .padding(.vertical, isCompact ? 6 : Spacing.s2)
            .frame(minHeight: isCompact ? 32 : 36)
            .background {
                if isSelected {
                    Capsule(style: .continuous)
                        .fill(Color.dsAccent)
                        .matchedGeometryEffect(id: "activeChip", in: chipNamespace)
                } else {
                    Capsule(style: .continuous)
                        .fill(Color.dsSurfaceGrouped)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

#Preview("Light") {
    DSChipBar(
        items: [DSChipItem(id: "all", title: "全部", count: 12), DSChipItem(id: "dl", title: "已下载", count: 3)],
        selection: .constant("all"),
        trailingActionTitle: "＋ 新建分类",
        onTrailingAction: {}
    )
    .preferredColorScheme(.light)
}

#Preview("Dark") {
    DSChipBar(
        items: [DSChipItem(id: "a", title: "国学经典"), DSChipItem(id: "b", title: "文学文艺")],
        selection: .constant("a")
    )
    .preferredColorScheme(.dark)
}

#Preview("AX") {
    DSChipBar(
        items: [DSChipItem(id: "a", title: "全部"), DSChipItem(id: "b", title: "有更新")],
        selection: .constant("a")
    )
    .environment(\.sizeCategory, .accessibilityExtraExtraLarge)
}
