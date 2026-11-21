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
    ///
    /// v5（包内 5.6.5）：**移除番茄畅听源**（fanqie.js）。原因：该源内容实为
    /// 听友/云图/喜马多平台聚合壳，且其"番茄官方分类"入口产出的书无法打开；
    /// 番茄相关需求改由「喜马拉雅内置解析」承担。升级到 v5 后：
    /// - installPackage 会整体清空并重建包目录 → 旧 fanqie.js 从磁盘移除；
    /// - 本文件的 applyInstalledMetas 会删除本包中已不再提供的书源记录（含番茄）；
    /// - 若「当前发现书源」指向被移除的源，会自动回退到第一个可用发现源。
    private static let legacySeededKeyV5 = "bundled.sources.seeded.ShunAudiobookPro.v5"
    private static let installedVersionKey = "bundled.sources.installedVersion.ShunAudiobookPro"
    private static let resourceName = "ShunAudiobookPro-v5.6"
    private static let resourceExt = "zip"

    /// M12 / L2：从内置 ZIP 读取 manifest.json 的 version 字段（兼容并剥离 UTF-8 BOM）
    nonisolated static func readManifestVersion(from zipData: Data) -> String? {
        guard let files = try? ZIPArchiveReader.extractAll(from: zipData),
              var raw = files["manifest.json"] else { return nil }
        if raw.count >= 3, raw[raw.startIndex] == 0xEF, raw[raw.startIndex + 1] == 0xBB, raw[raw.startIndex + 2] == 0xBF {
            raw = raw.dropFirst(3)
        }
        guard let obj = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
              let ver = obj["version"] as? String else { return nil }
        let trimmed = ver.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    @MainActor
    static func seedIfNeeded(modelContext: ModelContext) async {
        guard let url = Bundle.main.url(forResource: resourceName, withExtension: resourceExt) else {
            // 内置资源缺失（例如被裁剪）时静默跳过，不影响 App 启动
            return
        }
        // S4：避免首启在主线程同步读取 zip 字节，改为后台线程读取后再走导入链路
        let payload: (data: Data, manifestVersion: String?)? = await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: url) else { return nil }
            return (data, readManifestVersion(from: data))
        }.value
        guard let payload else {
            NSLog("[BundledSourceSeeder] 读取内置书源压缩包字节失败: \(url.lastPathComponent)")
            return
        }
        let targetVersion = payload.manifestVersion ?? "5.6.5"
        let installedVersion = UserDefaults.standard.string(forKey: installedVersionKey)
        if installedVersion == targetVersion {
            return
        }
        // 兼容已通过旧 v5 布尔标记完成安装的老用户（当前内置包版本为 5.6.5 时免重复覆盖）
        if installedVersion == nil,
           targetVersion == "5.6.5",
           UserDefaults.standard.bool(forKey: legacySeededKeyV5) {
            UserDefaults.standard.set(targetVersion, forKey: installedVersionKey)
            return
        }
        do {
            // 完全复用用户手动导入的成熟链路：解析 -> 落盘 -> 建路由
            let preview = try await PluginRuntime.shared.prepareImportPreview(from: payload.data)
            let metas = try await PluginRuntime.shared.installPackage(preview)
            try applyInstalledMetas(metas, from: preview, modelContext: modelContext)
            // 8-4 / M12：仅在 modelContext.save() 确认落盘成功后才记录已安装版本号
            UserDefaults.standard.set(targetVersion, forKey: installedVersionKey)
            UserDefaults.standard.set(true, forKey: legacySeededKeyV5)
        } catch {
            // 内置书源安装失败不应阻断启动；记录完整日志以便下次启动重试或用户手动导入
            NSLog("[BundledSourceSeeder] 内置书源安装或持久化失败: \(error.localizedDescription)")
        }
    }

    /// 与 PluginManagerView.applyInstalledMetas 保持一致，但面向启动场景：
    /// 不弹 Toast，分组 / 排序 / 默认发现源逻辑相同。
    @MainActor
    private static func applyInstalledMetas(
        _ metas: [ParsedSourceMeta],
        from preview: PluginImportPreview,
        modelContext: ModelContext
    ) throws {
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
        var removedStaleIDs = Set<String>()
        for stale in existingPlugins where stale.packageID == preview.packageID && !validIDs.contains(stale.id) {
            removedStaleIDs.insert(stale.id)
            modelContext.delete(stale)
        }

        do {
            try modelContext.save()
        } catch {
            NSLog("[BundledSourceSeeder] 保存内置书源记录到 SwiftData 失败: \(error.localizedDescription)")
            throw error
        }

        let settings = AppSettingsStore.shared
        let currentDiscover = settings.currentDiscoverSourceID
        // M-05 修复：仅在当前发现源为空、或恰好指向本内置包已移除的旧源时回退，绝不覆盖用户自选的其他书源
        if (currentDiscover.isEmpty || removedStaleIDs.contains(currentDiscover)),
           let firstDiscover = metas.first(where: { $0.discoverable && $0.enabledByDefault }) {
            settings.currentDiscoverSourceID = firstDiscover.id
        }
    }
}
