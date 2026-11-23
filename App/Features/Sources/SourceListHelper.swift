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

/// 书源列表筛选与分组纯逻辑（严格移出 View body，符合规则 #8）
enum SourceListHelper {
    static func supportsLogin(_ src: SourceMetaDTO) -> Bool {
        src.loginURL != nil || src.methods.contains("checkLogin")
    }

    static func needsLogin(_ src: SourceMetaDTO, loggedInSourceIDs: Set<String>) -> Bool {
        supportsLogin(src) && !loggedInSourceIDs.contains(src.id)
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
        loggedInSourceIDs: Set<String> = []
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

        var pinned: [SourceMetaDTO] = []
        var byGroup: [String: [SourceMetaDTO]] = [:]
        var ungrouped: [SourceMetaDTO] = []

        for src in filtered {
            if src.isPinned {
                pinned.append(src)
                continue
            }
            let group = src.groupName.trimmingCharacters(in: .whitespacesAndNewlines)
            if group.isEmpty || group == "默认" || group == "未分组" {
                ungrouped.append(src)
            } else {
                byGroup[group, default: []].append(src)
            }
        }

        let sortedGroupNames = byGroup.keys.sorted()
        let sections = sortedGroupNames.map { name in
            let list = (byGroup[name] ?? []).sorted { $0.sortOrder < $1.sortOrder }
            return SourceGroupSection(id: name, title: name, sources: list)
        }

        return SourceListPartition(
            pinned: pinned.sorted { $0.sortOrder < $1.sortOrder },
            grouped: sections,
            ungrouped: ungrouped.sorted { $0.sortOrder < $1.sortOrder }
        )
    }
}
