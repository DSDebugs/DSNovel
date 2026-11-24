import SwiftUI

/// 标签项模型（1:1 复刻 v2.8 `DSChipItem`）
public struct DSChipItem<ID: Hashable & Sendable>: Identifiable, Equatable, Sendable {
    public let id: ID
    public let title: String
    public let count: Int?

    public init(id: ID, title: String, count: Int? = nil) {
        self.id = id
        self.title = title
        self.count = count
    }
}

/// 横向可滚动标签栏（支持 matchedGeometryEffect 滑块、计数角标、紧凑模式与右侧描边操作按钮）
public struct DSChipBar<ID: Hashable & Sendable>: View {
    @Environment(\.sizeCategory) private var sizeCategory
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.dsReduceMotion) private var appReduceMotion
    @Namespace private var chipNamespace

    public let items: [DSChipItem<ID>]
    @Binding public var selection: ID
    public let isCompact: Bool
    public let leadingPadding: CGFloat
    public let allowsVerticalStackInAX: Bool
    private let trailingActionTitle: String?
    private let onTrailingAction: (() -> Void)?

    public init(
        items: [DSChipItem<ID>],
        selection: Binding<ID>,
        isCompact: Bool = false,
        leadingPadding: CGFloat = DSSpacing.pageHorizontal,
        allowsVerticalStackInAX: Bool = false,
        trailingActionTitle: String? = nil,
        onTrailingAction: (() -> Void)? = nil
    ) {
        self.items = items
        self._selection = selection
        self.isCompact = isCompact
        self.leadingPadding = leadingPadding
        self.allowsVerticalStackInAX = allowsVerticalStackInAX
        self.trailingActionTitle = trailingActionTitle
        self.onTrailingAction = onTrailingAction
    }

    private var reduceMotion: Bool { systemReduceMotion || appReduceMotion }

    public var body: some View {
        Group {
            if sizeCategory.isAccessibilityCategory && allowsVerticalStackInAX {
                VStack(alignment: .leading, spacing: DSSpacing.xs) {
                    ForEach(items) { item in chipButton(for: item) }
                    if let trailingActionTitle, let onTrailingAction {
                        trailingActionButton(title: trailingActionTitle, action: onTrailingAction)
                    }
                }
                .padding(.horizontal, DSSpacing.pageHorizontal)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: DSSpacing.xs) {
                            ForEach(items) { item in
                                chipButton(for: item).id(item.id)
                            }
                            if let trailingActionTitle, let onTrailingAction {
                                trailingActionButton(title: trailingActionTitle, action: onTrailingAction)
                            }
                        }
                        .padding(.leading, leadingPadding)
                        .padding(.trailing, DSSpacing.pageHorizontal)
                    }
                    .contentMargins(.bottom, 0, for: .scrollContent)
                    .fixedSize(horizontal: false, vertical: true)
                    .onChange(of: selection) { _, newValue in
                        DSHaptics.selection()
                        withAnimation(DSMotion.resolve(DSMotion.snappy, reduce: reduceMotion)) {
                            proxy.scrollTo(newValue, anchor: .center)
                        }
                    }
                }
            }
        }
    }

    private func trailingActionButton(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(DSTypography.subtitle.weight(.medium))
                .foregroundStyle(DSColors.inkSecondary)
                .padding(.horizontal, DSSpacing.sm)
                .padding(.vertical, DSSpacing.xs)
                .frame(minHeight: sizeCategory.isAccessibilityCategory ? 44 : 36)
                .background(Capsule(style: .continuous).strokeBorder(DSColors.separator.opacity(0.5), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }

    private func chipButton(for item: DSChipItem<ID>) -> some View {
        let isSelected = selection == item.id
        return Button {
            withAnimation(DSMotion.resolve(DSMotion.snappy, reduce: reduceMotion)) {
                selection = item.id
            }
        } label: {
            HStack(spacing: DSSpacing.xxs) {
                Text(item.title)
                    .font(DSTypography.subtitle.weight(isSelected ? .semibold : .medium))
                if let count = item.count {
                    Text("\(count)").font(DSTypography.numericCaption)
                }
            }
            .foregroundStyle(isSelected ? DSColors.onAccent : DSColors.inkPrimary)
            .padding(.horizontal, DSSpacing.sm)
            .padding(.vertical, isCompact ? 6 : DSSpacing.xs)
            .frame(minHeight: sizeCategory.isAccessibilityCategory ? 44 : (isCompact ? 32 : 36))
            .background {
                if isSelected {
                    Capsule(style: .continuous)
                        .fill(DSColors.accent)
                        .matchedGeometryEffect(id: "activeChip", in: chipNamespace)
                } else {
                    Capsule(style: .continuous).fill(DSColors.surfaceGrouped)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

/// 分组标题栏（1:1 复刻 v2.8 `DSSectionHeader`）
public struct DSSectionHeader: View {
    public let title: String
    public let subtitle: String?
    public let actionTitle: String?
    private let onAction: (() -> Void)?

    public init(
        title: String,
        subtitle: String? = nil,
        actionTitle: String? = nil,
        onAction: (() -> Void)? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.actionTitle = actionTitle
        self.onAction = onAction
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline) {
            HStack(alignment: .firstTextBaseline, spacing: DSSpacing.xs) {
                Text(title)
                    .font(DSTypography.sectionHeader)
                    .foregroundStyle(DSColors.inkPrimary)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(DSTypography.numericFootnote)
                        .foregroundStyle(DSColors.inkSecondary)
                }
            }
            Spacer()
            if let actionTitle, let onAction {
                Button(action: onAction) {
                    Text(actionTitle)
                        .font(DSTypography.subtitle.weight(.medium))
                        .foregroundStyle(DSColors.accent)
                        .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, DSSpacing.pageHorizontal)
    }
}

/// 书源健康度语义枚举（1:1 复刻 v2.8 `DSSourceHealthKind`）
public enum DSSourceHealthKind: String, CaseIterable, Equatable, Sendable {
    case untested
    case healthy
    case slow
    case needAuth
    case unavailable

    public var iconName: String {
        switch self {
        case .healthy: return "checkmark.circle.fill"
        case .slow: return "tortoise.fill"
        case .needAuth: return "person.badge.key"
        case .unavailable: return "exclamationmark.triangle.fill"
        case .untested: return "circle.dashed"
        }
    }

    public var statusColor: Color {
        switch self {
        case .healthy: return DSColors.success
        case .slow: return .yellow
        case .needAuth: return DSColors.warning
        case .unavailable: return DSColors.danger
        case .untested: return DSColors.inkSecondary
        }
    }
}

/// 书源胶囊徽章（1:1 复刻 v2.8 `DSSourceBadge`）
public struct DSSourceBadge: View {
    public let name: String
    public let health: DSSourceHealthKind
    public let latencyMs: Int?
    public let showHealthAndLatency: Bool

    public init(
        name: String,
        health: DSSourceHealthKind = .untested,
        latencyMs: Int? = nil,
        showHealthAndLatency: Bool = true
    ) {
        self.name = name
        self.health = health
        self.latencyMs = latencyMs
        self.showHealthAndLatency = showHealthAndLatency
    }

    public var body: some View {
        HStack(spacing: DSSpacing.xxs) {
            DSSourceAvatar(name: name, size: 18)
            Text(name)
                .font(DSTypography.caption.weight(.medium))
                .foregroundStyle(DSColors.inkPrimary)
                .lineLimit(1)

            if showHealthAndLatency {
                Image(systemName: health.iconName)
                    .font(DSTypography.caption2)
                    .foregroundStyle(health.statusColor)
                if let latencyMs, latencyMs > 0 {
                    Text("\(latencyMs)ms")
                        .font(DSTypography.numericCaption)
                        .foregroundStyle(DSColors.inkSecondary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
        }
        .padding(.horizontal, DSSpacing.xs)
        .padding(.vertical, 4)
        .background(Capsule(style: .continuous).fill(DSColors.surfaceGrouped))
    }
}

/// 5 语义色胶囊标签（1:1 复刻 v2.8 `DSBadge`）
public enum DSBadgeStyle: Equatable, Sendable {
    case accent
    case neutral
    case success
    case warning
    case danger
}

public struct DSBadge: View {
    public let text: String
    public let icon: String?
    public let style: DSBadgeStyle

    public init(_ text: String, icon: String? = nil, style: DSBadgeStyle = .neutral) {
        self.text = text
        self.icon = icon
        self.style = style
    }

    private var foregroundColor: Color {
        switch style {
        case .accent: return DSColors.onAccent
        case .neutral: return DSColors.inkSecondary
        case .success: return DSColors.success
        case .warning: return DSColors.warning
        case .danger: return DSColors.danger
        }
    }

    private var backgroundColor: Color {
        switch style {
        case .accent: return DSColors.accent
        case .neutral: return DSColors.surfaceGrouped
        case .success: return DSColors.success.opacity(0.15)
        case .warning: return DSColors.warning.opacity(0.15)
        case .danger: return DSColors.danger.opacity(0.15)
        }
    }

    public var body: some View {
        HStack(spacing: 4) {
            if let icon {
                Image(systemName: icon).font(DSTypography.caption2)
            }
            Text(text)
                .font(DSTypography.caption2.weight(.medium))
                .monospacedDigit()
        }
        .foregroundStyle(foregroundColor)
        .padding(.horizontal, DSSpacing.xs)
        .padding(.vertical, 3)
        .background(Capsule(style: .continuous).fill(backgroundColor))
    }
}
