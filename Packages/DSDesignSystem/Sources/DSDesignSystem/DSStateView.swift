import SwiftUI

/// 语义化状态枚举（1:1 复刻 v2.8 `DSStateKind`）
public enum DSStateKind: Equatable, Hashable, Sendable {
    case loading
    case empty
    case error(detail: String? = nil)
    case needLogin(sourceName: String)
    case needVerify
    case vipChapter
    case offline
    case noSource

    public var iconName: String {
        switch self {
        case .loading: return "hourglass"
        case .empty: return "tray"
        case .error: return "exclamationmark.triangle.fill"
        case .needLogin: return "person.badge.key"
        case .needVerify: return "checkmark.shield"
        case .vipChapter: return "lock.circle"
        case .offline: return "wifi.slash"
        case .noSource: return "shippingbox"
        }
    }

    public var title: String {
        switch self {
        case .loading: return ""
        case .empty: return "该分类暂无内容"
        case .error: return "加载失败"
        case .needLogin(let name): return "「\(name)」需要登录"
        case .needVerify: return "需要完成安全验证"
        case .vipChapter: return "此章节需要会员或内置解析"
        case .offline: return "当前没有网络"
        case .noSource: return "尚未启用任何书源"
        }
    }

    public var message: String {
        switch self {
        case .loading: return ""
        case .empty: return "试试切换其他分类或书源浏览"
        case .error: return "网络或书源响应异常，请重试"
        case .needLogin: return "登录后即可正常获取内容与收听"
        case .needVerify: return "完成网页验证后即可恢复访问"
        case .vipChapter: return "开启内置解析或登录会员账号后收听"
        case .offline: return "请检查网络连接或收听已下载章节"
        case .noSource: return "导入或启用书源后即可发现与搜索有声书"
        }
    }

    public var primaryButtonTitle: String? {
        switch self {
        case .loading: return nil
        case .empty: return "切换书源"
        case .error: return "重试"
        case .needLogin: return "去登录"
        case .needVerify: return "去验证"
        case .vipChapter: return "去开启内置解析"
        case .offline: return "查看已下载"
        case .noSource: return "导入书源"
        }
    }

    public var secondaryButtonTitle: String? {
        switch self {
        case .loading: return nil
        case .empty: return "刷新"
        case .error: return "切换书源"
        case .needLogin: return "稍后再说"
        case .needVerify: return "重试"
        case .vipChapter: return "查看说明"
        case .offline: return "重试"
        case .noSource: return "了解书源"
        }
    }
}

public enum DSStateVariant: Equatable, Sendable {
    case standard
    case inline
}

/// 统一空态 / 错误态 / 权限态视图（兼容 v3.0 `init(icon:title:message:actionTitle:action:)` 与 v2.8 `DSStateKind` 双按钮及可展开详情）
public struct DSStateView: View {
    private let kind: DSStateKind?
    private let variant: DSStateVariant
    private let iconName: String
    private let titleText: String
    private let messageText: String
    private let primaryTitle: String?
    private let secondaryTitle: String?
    private let errorDetail: String?
    private let onPrimary: (() -> Void)?
    private let onSecondary: (() -> Void)?
    @State private var showErrorDetails = false

    public init(
        icon: String,
        title: String,
        message: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.kind = nil
        self.variant = .standard
        self.iconName = icon
        self.titleText = title
        self.messageText = message
        self.primaryTitle = actionTitle
        self.secondaryTitle = nil
        self.errorDetail = nil
        self.onPrimary = action
        self.onSecondary = nil
    }

    public init(
        kind: DSStateKind,
        variant: DSStateVariant = .standard,
        titleOverride: String? = nil,
        messageOverride: String? = nil,
        primaryTitleOverride: String? = nil,
        secondaryTitleOverride: String? = nil,
        onPrimary: (() -> Void)? = nil,
        onSecondary: (() -> Void)? = nil
    ) {
        self.kind = kind
        self.variant = variant
        self.iconName = kind.iconName
        self.titleText = titleOverride ?? kind.title
        self.messageText = messageOverride ?? kind.message
        self.primaryTitle = primaryTitleOverride ?? kind.primaryButtonTitle
        self.secondaryTitle = secondaryTitleOverride ?? kind.secondaryButtonTitle
        if case .error(let detail) = kind {
            self.errorDetail = detail
        } else {
            self.errorDetail = nil
        }
        self.onPrimary = onPrimary
        self.onSecondary = onSecondary
    }

    public var body: some View {
        if kind == .loading {
            DSSkeleton(mode: .grid)
        } else if variant == .inline {
            inlineBody
        } else {
            standardBody
        }
    }

    private var inlineBody: some View {
        HStack(spacing: DSSpacing.sm) {
            Image(systemName: iconName)
                .font(DSTypography.headline)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(DSColors.accent)

            VStack(alignment: .leading, spacing: 2) {
                Text(titleText)
                    .font(DSTypography.cardTitle)
                    .foregroundStyle(DSColors.inkPrimary)
                Text(messageText)
                    .font(DSTypography.caption)
                    .foregroundStyle(DSColors.inkSecondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)

            if let primaryTitle, let onPrimary {
                Button(primaryTitle, action: onPrimary)
                    .font(DSTypography.caption.weight(.semibold))
                    .foregroundStyle(DSColors.onAccent)
                    .padding(.horizontal, DSSpacing.sm)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(DSColors.accent))
                    .buttonStyle(.plain)
            }
            if let secondaryTitle, let onSecondary {
                Button(secondaryTitle, action: onSecondary)
                    .font(DSTypography.caption.weight(.medium))
                    .foregroundStyle(DSColors.inkSecondary)
                    .buttonStyle(.plain)
            }
        }
        .padding(DSSpacing.sm)
        .background(RoundedRectangle(cornerRadius: DSRadius.card, style: .continuous).fill(DSColors.surfaceCard))
    }

    private var standardBody: some View {
        VStack(spacing: DSSpacing.sm) {
            Image(systemName: iconName)
                .font(DSTypography.largeTitle)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(DSColors.inkSecondary)

            Text(titleText)
                .font(DSTypography.rowTitle)
                .foregroundStyle(DSColors.inkPrimary)
                .multilineTextAlignment(.center)

            Text(messageText)
                .font(DSTypography.footnote)
                .foregroundStyle(DSColors.inkSecondary)
                .multilineTextAlignment(.center)

            if let detail = errorDetail, !detail.isEmpty {
                DisclosureGroup("详情", isExpanded: $showErrorDetails) {
                    Text(detail)
                        .font(DSTypography.caption.monospaced())
                        .foregroundStyle(.tertiary)
                        .padding(.top, DSSpacing.xxs)
                }
                .font(DSTypography.caption)
                .foregroundStyle(DSColors.inkSecondary)
                .frame(maxWidth: 260)
            }

            if (primaryTitle != nil && onPrimary != nil) || (secondaryTitle != nil && onSecondary != nil) {
                HStack(spacing: DSSpacing.sm) {
                    if let primaryTitle, let onPrimary {
                        Button(action: onPrimary) {
                            Text(primaryTitle)
                                .font(DSTypography.cardTitle)
                                .foregroundStyle(DSColors.onAccent)
                                .padding(.horizontal, DSSpacing.s5)
                                .padding(.vertical, DSSpacing.sm)
                                .frame(minHeight: 44)
                                .background(Capsule(style: .continuous).fill(DSColors.accent))
                        }
                        .buttonStyle(.plain)
                    }
                    if let secondaryTitle, let onSecondary {
                        Button(action: onSecondary) {
                            Text(secondaryTitle)
                                .font(DSTypography.cardTitle)
                                .foregroundStyle(DSColors.inkPrimary)
                                .padding(.horizontal, DSSpacing.md)
                                .padding(.vertical, DSSpacing.sm)
                                .frame(minHeight: 44)
                                .background(Capsule(style: .continuous).fill(DSColors.surfaceGrouped))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, DSSpacing.xxs)
            }
        }
        .padding(DSSpacing.lg)
        .frame(maxWidth: .infinity)
    }
}
