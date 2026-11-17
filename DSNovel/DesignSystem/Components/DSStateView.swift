import SwiftUI

enum DSStateKind: Equatable, Sendable {
    case loading
    case empty
    case error(detail: String? = nil)
    case needLogin(sourceName: String)
    case needVerify
    case vipChapter
    case offline
    case noSource

    var iconName: String {
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

    var title: String {
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

    var message: String {
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

    var primaryButtonTitle: String? {
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

    var secondaryButtonTitle: String? {
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

enum DSStateVariant: Equatable, Sendable {
    case standard
    case inline
}

enum UserFacingError {
    static func from(_ error: Error, sourceName: String = "当前书源") -> DSStateKind {
        if let pErr = error as? PluginError {
            switch pErr {
            case .needLogin:
                return .needLogin(sourceName: sourceName)
            case .needVerify:
                return .needVerify
            case .vipRequired, .builtinParserMissing, .builtinParserFailed:
                return .vipChapter
            case .timeout:
                return .error(detail: "请求超时 (timeout)")
            case .network(let msg):
                if msg.lowercased().contains("offline") || msg.contains("互联网") {
                    return .offline
                }
                return .error(detail: msg)
            case .notFound(let msg), .invalidPackage(let msg), .scriptException(let msg), .parseFailed(let msg):
                return .error(detail: msg)
            }
        }
        if let urlErr = error as? URLError {
            switch urlErr.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                return .offline
            case .timedOut:
                return .error(detail: "连接超时 (URLError.timedOut)")
            default:
                return .error(detail: "网络错误 (\(urlErr.code.rawValue))")
            }
        }
        return .error(detail: error.localizedDescription)
    }
}

struct DSStateView: View {
    let kind: DSStateKind
    let variant: DSStateVariant
    private let onPrimary: (() -> Void)?
    private let onSecondary: (() -> Void)?
    @State private var showErrorDetails = false

    init(
        kind: DSStateKind,
        variant: DSStateVariant = .standard,
        onPrimary: (() -> Void)? = nil,
        onSecondary: (() -> Void)? = nil
    ) {
        self.kind = kind
        self.variant = variant
        self.onPrimary = onPrimary
        self.onSecondary = onSecondary
    }

    var body: some View {
        switch kind {
        case .loading:
            DSSkeleton(mode: .grid)
        default:
            if variant == .inline {
                inlineBody
            } else {
                standardBody
            }
        }
    }

    private var inlineBody: some View {
        HStack(spacing: Spacing.s3) {
            Image(systemName: kind.iconName)
                .font(.headline)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle( Color.dsAccent )

            VStack(alignment: .leading, spacing: 2) {
                Text(kind.title)
                    .font(DSTypography.cardTitle)
                    .foregroundStyle(.primary)
                Text(kind.message)
                    .font(DSTypography.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if let primaryTitle = kind.primaryButtonTitle, let onPrimary {
                Button(primaryTitle, action: onPrimary)
                    .font(DSTypography.caption.weight(.semibold))
                    .foregroundStyle(Color.dsOnAccent)
                    .padding(.horizontal, Spacing.s3)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.dsAccent))
                    .buttonStyle(.plain)
            }

            if let secondaryTitle = kind.secondaryButtonTitle, let onSecondary {
                Button(secondaryTitle, action: onSecondary)
                    .font(DSTypography.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .buttonStyle(.plain)
            }
        }
        .padding(Spacing.s3)
        .background(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .fill(Color.dsSurfaceCard)
        )
    }

    private var standardBody: some View {
        VStack(spacing: Spacing.s3) {
            Image(systemName: kind.iconName)
                .font(.largeTitle)
                .imageScale(.large)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .frame(width: 48, height: 48)

            Text(kind.title)
                .font(DSTypography.rowTitle)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)

            Text(kind.message)
                .font(DSTypography.cardTitle)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if case .error(let detail) = kind, let detail, !detail.isEmpty {
                DisclosureGroup("详情", isExpanded: $showErrorDetails) {
                    Text(detail)
                        .font(DSTypography.caption.monospaced())
                        .foregroundStyle(.tertiary)
                        .padding(.top, Spacing.s1)
                }
                .font(DSTypography.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 260)
            }

            HStack(spacing: Spacing.s3) {
                if let primaryTitle = kind.primaryButtonTitle, let onPrimary {
                    Button(action: onPrimary) {
                        Text(primaryTitle)
                            .font(DSTypography.cardTitle)
                            .foregroundStyle(Color.dsOnAccent)
                            .padding(.horizontal, Spacing.s5)
                            .padding(.vertical, Spacing.s3)
                            .frame(minHeight: 44)
                            .background(Capsule(style: .continuous).fill(Color.dsAccent))
                    }
                    .buttonStyle(.plain)
                }

                if let secondaryTitle = kind.secondaryButtonTitle, let onSecondary {
                    Button(action: onSecondary) {
                        Text(secondaryTitle)
                            .font(DSTypography.cardTitle)
                            .foregroundStyle(.primary)
                            .padding(.horizontal, Spacing.s4)
                            .padding(.vertical, Spacing.s3)
                            .frame(minHeight: 44)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(Color.dsSurfaceGrouped)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, Spacing.s1)
        }
        .padding(Spacing.s6)
        .frame(maxWidth: .infinity)
    }
}

#Preview("Light") {
    DSStateView(kind: .needLogin(sourceName: "博看有声"), onPrimary: {}, onSecondary: {})
        .preferredColorScheme(.light)
}

#Preview("Dark") {
    DSStateView(kind: .vipChapter, variant: .inline, onPrimary: {}, onSecondary: {})
        .padding()
        .preferredColorScheme(.dark)
}

#Preview("AX") {
    DSStateView(kind: .offline, onPrimary: {}, onSecondary: {})
        .environment(\.sizeCategory, .accessibilityExtraExtraLarge)
}
