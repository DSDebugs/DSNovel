import Foundation
import SwiftData

/// 内置书源种子安装器
///
/// DSNovel 默认不内置任何书源；本模块把随 App 一起打包的听书专享书源包
/// （BundledSources/ShunAudiobookPro-v5.6.zip）在首次启动时一次性安装到
/// 用户的插件目录，并补齐 SwiftData 的 PluginRecord，使其与其它书源一样
/// 出现在「书源管理」中，可被搜索 / 发现 / 播放 / 分组 / 停用。
///
/// 设计要点：
/// - 幂等：仅当未安装过该内置包时执行，绝不覆盖用户后续对书源的自定义修改。
/// - 可升级：seededKey 带版本后缀；日后升级内置包时改后缀即可再次播种。
/// - 零侵入：完全复用 PluginRuntime 现有的 prepareImportPreview / installPackage，
///   不改动 JS 运行时与插件协议。
enum BundledSourceSeeder {
    /// 换了内置书源包内容时，把版本号 +1 即可让老用户重新安装一次
    private static let seededKey = "bundled.sources.seeded.ShunAudiobookPro.v3"
    private static let resourceName = "ShunAudiobookPro-v5.6"
    private static let resourceExt = "zip"

    @MainActor
    static func seedIfNeeded(modelContext: ModelContext) async {
        guard !UserDefaults.standard.bool(forKey: seededKey) else { return }
        guard let url = Bundle.main.url(forResource: resourceName, withExtension: resourceExt),
              let zipData = try? Data(contentsOf: url) else {
            // 内置资源缺失（例如被裁剪）时静默跳过，不影响 App 启动
            return
        }
        do {
            // 完全复用用户手动导入的成熟链路：解析 -> 落盘 -> 建路由
            let preview = try await PluginRuntime.shared.prepareImportPreview(from: zipData)
            let metas = try await PluginRuntime.shared.installPackage(preview)
            applyInstalledMetas(metas, from: preview, modelContext: modelContext)
            UserDefaults.standard.set(true, forKey: seededKey)
        } catch {
            // 内置书源安装失败不应阻断启动；用户仍可在书源管理里手动导入
            NSLog("[BundledSourceSeeder] 内置书源安装失败: \(error.localizedDescription)")
        }
    }

    /// 与 PluginManagerView.applyInstalledMetas 保持一致，但面向启动场景：
    /// 不弹 Toast，分组 / 排序 / 默认发现源逻辑相同。
    @MainActor
    private static func applyInstalledMetas(
        _ metas: [ParsedSourceMeta],
        from preview: PluginImportPreview,
        modelContext: ModelContext
    ) {
        let existingGroups = (try? modelContext.fetch(FetchDescriptor<PluginGroup>())) ?? []
        let existingPlugins = (try? modelContext.fetch(FetchDescriptor<PluginRecord>())) ?? []

        var groupsByName: [String: PluginGroup] = [:]
        for g in existingGroups { groupsByName[g.name] = g }
        var nextGroupOrder = existingGroups.count
        var nextPluginOrder = (existingPlugins.map(\.order).max() ?? -1) + 1

        for meta in metas {
            let targetGroupID: String?
            let groupName = meta.group.trimmingCharacters(in: .whitespacesAndNewlines)
            if !groupName.isEmpty {
                if let existing = groupsByName[groupName] {
                    targetGroupID = existing.id
                } else {
                    let newGroup = PluginGroup(name: groupName, order: nextGroupOrder)
                    nextGroupOrder += 1
                    modelContext.insert(newGroup)
                    groupsByName[groupName] = newGroup
                    targetGroupID = newGroup.id
                }
            } else {
                targetGroupID = nil
            }

            let verifiedLogin = CookieSync.isSourceLoggedIn(meta.id)

            if let existing = existingPlugins.first(where: { $0.id == meta.id }) {
                existing.packageID = preview.packageID
                existing.name = meta.name
                existing.version = preview.version
                existing.author = preview.author
                existing.siteURL = meta.url
                existing.summary = meta.summary.isEmpty ? preview.description : meta.summary
                existing.searchable = meta.searchable
                existing.discoverable = meta.discoverable
                existing.requiresLogin = !meta.loginURL.isEmpty
                existing.loginURL = meta.loginURL
                existing.loggedIn = verifiedLogin
                if existing.groupID == nil { existing.groupID = targetGroupID }
            } else {
                let record = PluginRecord(
                    id: meta.id,
                    packageID: preview.packageID,
                    name: meta.name,
                    version: preview.version,
                    author: preview.author,
                    siteURL: meta.url,
                    summary: meta.summary.isEmpty ? preview.description : meta.summary,
                    groupID: targetGroupID,
                    order: nextPluginOrder,
                    isPinned: false,
                    isEnabled: meta.enabledByDefault,
                    searchable: meta.searchable,
                    discoverable: meta.discoverable,
                    requiresLogin: !meta.loginURL.isEmpty,
                    loginURL: meta.loginURL,
                    loggedIn: verifiedLogin
                )
                nextPluginOrder += 1
                modelContext.insert(record)
            }
        }
        // 内置包升级后，移除本包下已不再提供的旧源记录（例如从内置源中剔除的书源），
        // 避免书源管理里残留无法路由/调用的幽灵条目。只清理同 packageID，绝不误伤用户自导入的源。
        let validIDs = Set(metas.map(\.id))
        for stale in existingPlugins where stale.packageID == preview.packageID && !validIDs.contains(stale.id) {
            modelContext.delete(stale)
        }

        try? modelContext.save()

        let settings = AppSettingsStore.shared
        let currentDiscover = settings.currentDiscoverSourceID
        // 当前发现源为空、或指向已被移除的旧源时，回退到第一个可用的发现源
        if (currentDiscover.isEmpty || !validIDs.contains(currentDiscover)),
           let firstDiscover = metas.first(where: { $0.discoverable && $0.enabledByDefault }) {
            settings.currentDiscoverSourceID = firstDiscover.id
        }
    }
}
