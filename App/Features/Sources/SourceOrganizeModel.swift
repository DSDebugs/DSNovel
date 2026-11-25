import DSCore
import DSDesignSystem
import DSStorage
import Observation
import SwiftUI

/// 书源分组与排序状态模型（支持新建空分组、重命名、安全删除、单源换组与拖拽排序，同时兼容既有单测）
@Observable
@MainActor
final class SourceOrganizeModel {
    struct GroupBucket: Identifiable {
        let id: String
        var name: String
        var sources: [SourceMetaDTO]
    }

    var groups: [GroupBucket] = []
    var allSources: [SourceMetaDTO] = []
    var groupNames: [String] = []
    var selectedIDs: Set<String> = []
    var newGroupName: String = ""

    func load(from rawSources: [SourceMetaDTO], customGroups: [String] = []) {
        allSources = rawSources.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
            return lhs.sortOrder < rhs.sortOrder
        }
        groupNames = SourceListHelper.allGroupNames(sources: allSources, customGroups: customGroups)
        rebuildBuckets()
    }

    func count(inGroup groupName: String) -> Int {
        allSources.reduce(0) { partial, src in
            partial + (SourceListHelper.normalizedGroupName(src.groupName) == groupName ? 1 : 0)
        }
    }

    func createGroup(_ name: String) -> Bool {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean != SourceListHelper.defaultGroupName, !groupNames.contains(clean) else {
            return false
        }
        let insertIdx = max(0, groupNames.count - 1)
        groupNames.insert(clean, at: insertIdx)
        rebuildBuckets()
        return true
    }

    func renameGroup(from oldName: String, to newName: String) -> Bool {
        let clean = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard oldName != SourceListHelper.defaultGroupName,
              !clean.isEmpty,
              clean != SourceListHelper.defaultGroupName,
              clean != oldName else {
            return false
        }
        if let idx = groupNames.firstIndex(of: oldName) {
            groupNames.remove(at: idx)
            if !groupNames.contains(clean) {
                groupNames.insert(clean, at: idx)
            }
        }
        allSources = allSources.map { src in
            guard SourceListHelper.normalizedGroupName(src.groupName) == oldName else { return src }
            return cloneSource(src, groupName: clean, sortOrder: src.sortOrder)
        }
        rebuildBuckets()
        return true
    }

    func deleteGroup(_ name: String) -> Bool {
        guard name != SourceListHelper.defaultGroupName else { return false }
        groupNames.removeAll { $0 == name }
        allSources = allSources.map { src in
            guard SourceListHelper.normalizedGroupName(src.groupName) == name else { return src }
            return cloneSource(src, groupName: SourceListHelper.defaultGroupName, sortOrder: src.sortOrder)
        }
        rebuildBuckets()
        return true
    }

    func assignSource(id: String, toGroup groupName: String) {
        let clean = SourceListHelper.normalizedGroupName(groupName)
        if !groupNames.contains(clean) {
            let insertIdx = max(0, groupNames.count - 1)
            groupNames.insert(clean, at: insertIdx)
        }
        allSources = allSources.map { src in
            guard src.id == id else { return src }
            return cloneSource(src, groupName: clean, sortOrder: src.sortOrder)
        }
        rebuildBuckets()
    }

    @discardableResult
    func moveGroups(from offsets: IndexSet, to destination: Int) -> [String] {
        var nonDefault = groupNames.filter { $0 != SourceListHelper.defaultGroupName }
        let validOffsets = IndexSet(offsets.filter { $0 < nonDefault.count })
        guard !validOffsets.isEmpty else { return nonDefault }
        let clampedDest = min(max(0, destination), nonDefault.count)
        nonDefault.move(fromOffsets: validOffsets, toOffset: clampedDest)
        groupNames = nonDefault + [SourceListHelper.defaultGroupName]
        rebuildBuckets()
        return nonDefault
    }

    func moveAllSources(from offsets: IndexSet, to destination: Int) {
        allSources.move(fromOffsets: offsets, toOffset: destination)
        allSources = allSources.enumerated().map { idx, src in
            cloneSource(src, groupName: SourceListHelper.normalizedGroupName(src.groupName), sortOrder: idx)
        }
        rebuildBuckets()
    }

    func move(inGroup groupID: String, from offsets: IndexSet, to destination: Int) {
        guard let idx = groups.firstIndex(where: { $0.id == groupID }) else { return }
        groups[idx].sources.move(fromOffsets: offsets, toOffset: destination)
        syncAllSourcesFromBuckets()
    }

    func toggleSelection(_ id: String) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }

    func moveSelected(toGroup targetGroup: String) {
        let clean = targetGroup.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !selectedIDs.isEmpty else { return }
        if !groupNames.contains(clean) {
            let insertIdx = max(0, groupNames.count - 1)
            groupNames.insert(clean, at: insertIdx)
        }
        allSources = allSources.map { src in
            guard selectedIDs.contains(src.id) else { return src }
            return cloneSource(src, groupName: clean, sortOrder: src.sortOrder)
        }
        selectedIDs.removeAll()
        rebuildBuckets()
    }

    func flattenedForSave() -> [SourceMetaDTO] {
        allSources.enumerated().map { idx, s in
            cloneSource(s, groupName: SourceListHelper.normalizedGroupName(s.groupName), sortOrder: idx)
        }
    }

    private func rebuildBuckets() {
        let grouped = Dictionary(grouping: allSources, by: { SourceListHelper.normalizedGroupName($0.groupName) })
        groups = groupNames.compactMap { name in
            guard let list = grouped[name], !list.isEmpty else { return nil }
            return GroupBucket(id: name, name: name, sources: list)
        }
    }

    private func syncAllSourcesFromBuckets() {
        var merged: [SourceMetaDTO] = []
        var order = 0
        for g in groups {
            for s in g.sources {
                merged.append(cloneSource(s, groupName: g.name, sortOrder: order))
                order += 1
            }
        }
        allSources = merged
    }

    private func cloneSource(_ s: SourceMetaDTO, groupName: String, sortOrder: Int) -> SourceMetaDTO {
        SourceMetaDTO(
            id: s.id, name: s.name, version: s.version, author: s.author,
            summary: s.summary, declaredHosts: s.declaredHosts,
            permissionMode: s.permissionMode, methods: s.methods,
            isEnabled: s.isEnabled, isPinned: s.isPinned,
            groupName: groupName, sortOrder: sortOrder, loginURL: s.loginURL
        )
    }
}
