import SwiftUI

enum DSStateKind: Equatable, Hashable, Sendable {
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
                // 受限章节 / 仅试听 / 内置解析失败（含 no_cookie、trial_only）统一走 .vipChapter 态，
                // 保留「去开启内置解析」跳转入口，具体原因由 messageOverride(for:) 清晰展示。
                return .vipChapter
            case .timeout:
                return .error(detail: "请求超时 (timeout)")
            case .network(let msg):
                if msg.lowercased().contains("offline") || msg.contains("互联网") {
                    return .offline
                }
                return .error(detail: msg)
            case .rateLimited:
                return .error(detail: "请求过于频繁，请稍后再试")
            case .parseFailed(let msg):
                return .error(detail: msg)
            }
        }
        if let bpErr = error as? BuiltinParserError {
            switch bpErr {
            case .notInstalled, .noMatchingParser:
                return .vipChapter
            case .rejected(let reason, _):
                switch reason {
                case "trial_only", "not_vip", "no_cookie", "paid_api_failed":
                    return .vipChapter
                case "rate_limited":
                    return .error(detail: bpErr.localizedDescription)
                default:
                    return .error(detail: bpErr.localizedDescription)
                }
            case .timeout:
                return .error(detail: "内置解析超时 (timeout)")
            case .rateLimited:
                return .error(detail: "内置解析请求过于频繁，请稍后再试")
            case .scriptInvalid, .invokeFailed:
                return .error(detail: bpErr.localizedDescription)
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

    /// 提取 trial_only（仅提供试听）与 no_cookie（共享 Cookie 不可用）等具体说明，供 DSStateView.messageOverride 展示
    static func messageOverride(for error: Error) -> String? {
        if let pErr = error as? PluginError {
            if case .builtinParserFailed(_, let reason) = pErr {
                let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                let code = trimmed.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                    .first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
                if code == "trial_only" {
                    return "该章节仅提供试听，需要会员或购买"
                }
                if code == "no_cookie" {
                    return "本机账号无权限，且共享的具备权限的 Cookie 不可用；请用会员账号登录或稍后重试"
                }
                return trimmed
            }
            return nil
        }
        if let bpErr = error as? BuiltinParserError {
            if case .rejected(let reason, let msg) = bpErr {
                let trimmed = msg.trimmingCharacters(in: .whitespacesAndNewlines)
                switch reason {
                case "trial_only":
                    return trimmed.isEmpty ? "该章节仅提供试听，需要会员或购买" : trimmed
                case "no_cookie":
                    return trimmed.isEmpty ? "本机账号无权限，且共享的具备权限的 Cookie 不可用；请用会员账号登录或稍后重试" : trimmed
                default:
                    return trimmed.isEmpty ? bpErr.localizedDescription : trimmed
                }
            }
        }
        return nil
    }
}

struct DSStateView: View {
    let kind: DSStateKind
    let variant: DSStateVariant
    let titleOverride: String?
    let messageOverride: String?
    let primaryTitleOverride: String?
    let secondaryTitleOverride: String?
    private let onPrimary: (() -> Void)?
    private let onSecondary: (() -> Void)?
    @State private var showErrorDetails = false

    init(
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
        self.titleOverride = titleOverride
        self.messageOverride = messageOverride
        self.primaryTitleOverride = primaryTitleOverride
        self.secondaryTitleOverride = secondaryTitleOverride
        self.onPrimary = onPrimary
        self.onSecondary = onSecondary
    }

    private var resolvedTitle: String {
        titleOverride ?? kind.title
    }

    private var resolvedMessage: String {
        messageOverride ?? kind.message
    }

    private var resolvedPrimaryTitle: String? {
        primaryTitleOverride ?? kind.primaryButtonTitle
    }

    private var resolvedSecondaryTitle: String? {
        secondaryTitleOverride ?? kind.secondaryButtonTitle
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
                .foregroundStyle(Color.dsAccent)

            VStack(alignment: .leading, spacing: 2) {
                Text(resolvedTitle)
                    .font(DSTypography.cardTitle)
                    .foregroundStyle(.primary)
                Text(resolvedMessage)
                    .font(DSTypography.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)

            if let primaryTitle = resolvedPrimaryTitle, let onPrimary {
                Button(primaryTitle, action: onPrimary)
                    .font(DSTypography.caption.weight(.semibold))
                    .foregroundStyle(Color.dsOnAccent)
                    .padding(.horizontal, Spacing.s3)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.dsAccent))
                    .buttonStyle(.plain)
            }

            if let secondaryTitle = resolvedSecondaryTitle, let onSecondary {
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

            Text(resolvedTitle)
                .font(DSTypography.rowTitle)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)

            Text(resolvedMessage)
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
                if let primaryTitle = resolvedPrimaryTitle, let onPrimary {
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

                if let secondaryTitle = resolvedSecondaryTitle, let onSecondary {
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
