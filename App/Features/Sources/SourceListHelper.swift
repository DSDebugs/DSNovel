import DSCore
import DSDesignSystem
import Foundation

/// 书源列表顶部状态筛选枚举（全部 / 已启用 / 已停用 / 未登录）
enum SourceListFilter: String, CaseIterable, Hashable, Sendable, Identifiable {
    case all
    case enabled
    case disabled
    case needLogin

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "全部"
        case .enabled: return "已启用"
        case .disabled: return "已停用"
        case .needLogin: return "未登录"
        }
    }
}

struct SourceGroupSection: Identifiable {
    let id: String
    let title: String
    let sources: [SourceMetaDTO]
}

struct SourceListPartition {
    let pinned: [SourceMetaDTO]
    let grouped: [SourceGroupSection]
    let ungrouped: [SourceMetaDTO]

    var isEmpty: Bool {
        pinned.isEmpty && grouped.isEmpty && ungrouped.isEmpty
    }
}

/// 书源列表筛选、分组汇总与精炼简介纯逻辑（严格移出 View body，符合规则 #8）
enum SourceListHelper {
    static let defaultGroupName = "默认分组"

    static func supportsLogin(_ src: SourceMetaDTO) -> Bool {
        src.loginURL != nil || src.methods.contains("checkLogin")
    }

    static func needsLogin(_ src: SourceMetaDTO, loggedInSourceIDs: Set<String>) -> Bool {
        supportsLogin(src) && !loggedInSourceIDs.contains(src.id)
    }

    /// 规范化书源分组名称（空值或历史别名统一归一为「默认分组」）
    static func normalizedGroupName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "默认" || trimmed == "未分组" {
            return defaultGroupName
        }
        return trimmed
    }

    /// 汇总所有可用分组（保留自定义顺序 + 现有书源分组 + 系统默认分组置底）
    static func allGroupNames(sources: [SourceMetaDTO], customGroups: [String]) -> [String] {
        var result: [String] = []
        var seen: Set<String> = []

        func appendIfNew(_ name: String) {
            let clean = normalizedGroupName(name)
            guard clean != defaultGroupName, seen.insert(clean).inserted else { return }
            result.append(clean)
        }

        // 优先保证内置主流分组顺序
        let sourceGroupSet = Set(sources.map { normalizedGroupName($0.groupName) })
        if sourceGroupSet.contains("主力听书") { appendIfNew("主力听书") }
        if sourceGroupSet.contains("精品有声") { appendIfNew("精品有声") }

        for g in customGroups { appendIfNew(g) }
        for src in sources.sorted(by: { $0.sortOrder < $1.sortOrder }) {
            appendIfNew(src.groupName)
        }
        result.append(defaultGroupName)
        return result
    }

    /// 提炼外置一句话书源简介（过滤旧版冗长星级行与重复修饰语）
    static func conciseSummary(for src: SourceMetaDTO) -> String {
        switch src.id {
        case "6e2b9c4d8a1f4d37b5c0e73a9f1d2b64":
            return "全品类主力源 · 免费直听，登录畅听 VIP"
        case "a6d1c3f08b2e4759b8e0f4a27c915d36":
            return "有声小说与评书全 · 免登录秒加载目录"
        default:
            break
        }
        switch src.name {
        case "喜马拉雅": return "全品类主力源 · 免费直听，登录畅听 VIP"
        case "听友听书": return "有声小说与评书全 · 免登录秒加载目录"
        case "云图有声": return "正版小说、广播剧与名著 · 免登录直链"
        case "博看有声": return "图书馆正版人文历史与评书 · 免登录直链"
        case "听书网": return "热门网文多人有声剧 · 单页目录免登录"
        default: break
        }
        let lines = src.summary
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.contains("⭐") && !$0.hasPrefix("推荐指数") && !$0.hasPrefix("主力推荐") }
        if let first = lines.first, !first.isEmpty {
            return first
        }
        return supportsLogin(src) ? "支持网页登录 · 点击查看详情" : "免登录直连听书源"
    }

    static func makeFilterChips(
        from sources: [SourceMetaDTO],
        loggedInSourceIDs: Set<String> = []
    ) -> [DSChipItem<SourceListFilter>] {
        var enabledCount = 0
        var disabledCount = 0
        var needLoginCount = 0
        for src in sources {
            if src.isEnabled { enabledCount += 1 } else { disabledCount += 1 }
            if needsLogin(src, loggedInSourceIDs: loggedInSourceIDs) { needLoginCount += 1 }
        }
        return [
            DSChipItem(id: .all, title: SourceListFilter.all.title, count: sources.count),
            DSChipItem(id: .enabled, title: SourceListFilter.enabled.title, count: enabledCount),
            DSChipItem(id: .disabled, title: SourceListFilter.disabled.title, count: disabledCount),
            DSChipItem(id: .needLogin, title: SourceListFilter.needLogin.title, count: needLoginCount)
        ]
    }

    static func partition(
        sources: [SourceMetaDTO],
        filter: SourceListFilter,
        loggedInSourceIDs: Set<String> = [],
        customGroups: [String] = []
    ) -> SourceListPartition {
        var filtered: [SourceMetaDTO] = []
        filtered.reserveCapacity(sources.count)
        for src in sources {
            switch filter {
            case .all:
                filtered.append(src)
            case .enabled:
                if src.isEnabled { filtered.append(src) }
            case .disabled:
                if !src.isEnabled { filtered.append(src) }
            case .needLogin:
                if needsLogin(src, loggedInSourceIDs: loggedInSourceIDs) { filtered.append(src) }
            }
        }

        var byGroup: [String: [SourceMetaDTO]] = [:]
        for src in filtered {
            let group = normalizedGroupName(src.groupName)
            byGroup[group, default: []].append(src)
        }

        let orderedNames = allGroupNames(sources: filtered, customGroups: customGroups)
        var sections: [SourceGroupSection] = []
        for name in orderedNames {
            guard let list = byGroup[name], !list.isEmpty else { continue }
            let sorted = list.sorted { lhs, rhs in
                if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
                return lhs.sortOrder < rhs.sortOrder
            }
            sections.append(SourceGroupSection(id: name, title: name, sources: sorted))
        }

        return SourceListPartition(pinned: [], grouped: sections, ungrouped: [])
    }
}
