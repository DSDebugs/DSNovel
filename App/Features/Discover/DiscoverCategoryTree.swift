import DSCore
import Foundation

/// 首页普通分类库排序方式（仅用于支持 sort 参数的书源，如喜马拉雅分类书库）
enum DiscoverSortOption: String, CaseIterable, Identifiable, Sendable {
    case comprehensive
    case hot
    case latest

    var id: String { rawValue }

    var title: String {
        switch self {
        case .comprehensive: return "综合"
        case .hot: return "最热"
        case .latest: return "最新"
        }
    }

    var ximalayaSortCode: Int {
        switch self {
        case .comprehensive: return 0
        case .hot: return 1
        case .latest: return 2
        }
    }

    var tingyouSortCode: String {
        switch self {
        case .comprehensive: return "comprehensive"
        case .hot: return "popular"
        case .latest: return "updated"
        }
    }
}

/// 排序 URL 辅助工具（无侵入适配喜马拉雅 xm-cat 与听友 tingyou:cat 协议，不污染其他书源）
enum DiscoverSortHelper {
    static func supportsSort(url: String) -> Bool {
        url.hasPrefix("xm-cat:") || url.hasPrefix("tingyou:cat:")
    }

    static func applyingSort(_ sort: DiscoverSortOption, to url: String) -> String {
        if url.hasPrefix("xm-cat:") {
            let parts = url.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
            let body = String(parts.first ?? "")
            let pageSuffix = parts.count > 1 ? "#\(parts[1])" : "#1"
            let segments = body.split(separator: ":", omittingEmptySubsequences: false)
            guard segments.count >= 3 else { return url }
            return "xm-cat:\(segments[1]):\(segments[2]):\(sort.ximalayaSortCode)\(pageSuffix)"
        }
        if url.hasPrefix("tingyou:cat:") {
            let parts = url.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
            let body = String(parts.first ?? "")
            let pageSuffix = parts.count > 1 ? "#\(parts[1])" : "#1"
            let payload = String(body.dropFirst("tingyou:cat:".count))
            let cleanedParams = payload
                .split(separator: "&")
                .filter { !$0.hasPrefix("sort=") }
                .joined(separator: "&")
            let sep = cleanedParams.isEmpty ? "" : "&"
            return "tingyou:cat:\(cleanedParams)\(sep)sort=\(sort.tingyouSortCode)\(pageSuffix)"
        }
        return url
    }
}

/// 首页一级/二级/三级分类树模型（一级下拉 Menu + 二级横向胶囊 + 可选三级横向胶囊）
struct DiscoverCategorySection: Identifiable, Sendable {
    let id: Int
    let title: String
    let tabs: [DiscoverCategoryTab]
}

struct DiscoverCategoryTab: Identifiable, Sendable {
    let id: Int
    let category: DiscoverCategoryDTO
    let shortTitle: String
    let subTabs: [DiscoverCategorySubTab]
}

struct DiscoverCategorySubTab: Identifiable, Sendable {
    let id: Int
    let category: DiscoverCategoryDTO
    let shortTitle: String
}

enum DiscoverCategoryGrouping {
    static func buildSections(from categories: [DiscoverCategoryDTO]) -> [DiscoverCategorySection] {
        guard !categories.isEmpty else { return [] }
        let hasGroups = categories.contains { !$0.groupTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if !hasGroups {
            let tabs = categories.enumerated().map { idx, cat in
                DiscoverCategoryTab(id: idx, category: cat, shortTitle: cat.title, subTabs: [])
            }
            return [DiscoverCategorySection(id: 0, title: "分类", tabs: tabs)]
        }

        var order: [String] = []
        var grouped: [String: [DiscoverCategoryDTO]] = [:]
        for cat in categories {
            let rawGroup = cat.groupTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = rawGroup.isEmpty ? "其他" : rawGroup
            if grouped[key] == nil { order.append(key) }
            grouped[key, default: []].append(cat)
        }

        return order.enumerated().map { secIdx, groupName in
            let sectionItems = grouped[groupName] ?? []
            let hasSubGroups = sectionItems.contains { !$0.subGroupTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

            if hasSubGroups {
                var subOrder: [String] = []
                var subGrouped: [String: [DiscoverCategoryDTO]] = [:]
                for cat in sectionItems {
                    let rawSub = cat.subGroupTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                    let subKey = rawSub.isEmpty ? "全部" : rawSub
                    if subGrouped[subKey] == nil { subOrder.append(subKey) }
                    subGrouped[subKey, default: []].append(cat)
                }
                let tabs: [DiscoverCategoryTab] = subOrder.enumerated().compactMap { tabIdx, subName in
                    let leaves = subGrouped[subName] ?? []
                    guard let firstLeaf = leaves.first else { return nil }
                    let fullPrefix = "\(groupName)·\(subName)·"
                    let subTabs = leaves.enumerated().map { leafIdx, leaf in
                        let short = stripLeafTitle(leaf.title, fullPrefix: fullPrefix, fallbackPrefix: "\(groupName)·")
                        return DiscoverCategorySubTab(id: leafIdx, category: leaf, shortTitle: short)
                    }
                    return DiscoverCategoryTab(id: tabIdx, category: firstLeaf, shortTitle: subName, subTabs: subTabs)
                }
                return DiscoverCategorySection(id: secIdx, title: groupName, tabs: tabs)
            } else {
                let prefix = "\(groupName)·"
                let tabs = sectionItems.enumerated().map { tabIdx, cat in
                    let short = cat.title.hasPrefix(prefix) ? String(cat.title.dropFirst(prefix.count)) : cat.title
                    return DiscoverCategoryTab(
                        id: tabIdx,
                        category: cat,
                        shortTitle: short.isEmpty ? cat.title : short,
                        subTabs: []
                    )
                }
                return DiscoverCategorySection(id: secIdx, title: groupName, tabs: tabs)
            }
        }
    }

    private static func stripLeafTitle(_ title: String, fullPrefix: String, fallbackPrefix: String) -> String {
        if title.hasPrefix(fullPrefix) {
            let trimmed = String(title.dropFirst(fullPrefix.count))
            if !trimmed.isEmpty { return trimmed }
        }
        if title.hasPrefix(fallbackPrefix) {
            let trimmed = String(title.dropFirst(fallbackPrefix.count))
            if !trimmed.isEmpty { return trimmed }
        }
        return title
    }
}
