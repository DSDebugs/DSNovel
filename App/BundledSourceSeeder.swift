import DSCore
import DSPluginKit
import DSStorage
import Foundation

/// 随包内置书源解压与幂等初始化器（L-CI-2/L-IOS-4：严格使用 ZIPArchiveReader 强校验并剥离任何非法条目）
enum BundledSourceSeeder {
    static let bundledArchiveName = "ShunAudiobookPro-v5.6"
    static let seedVersionTag = "v5.6.10-v3"

    private struct Manifest: Decodable {
        let name: String
        let version: String
        let author: String?
        let description: String?
        let scripts: [String]
    }

    static func seedIfNeeded(
        persistence: PersistenceEngine,
        pluginRuntime: PluginRuntime,
        settings: AppSettingsStore,
        logger: DSDiagnosticLogStore,
        force: Bool = false
    ) async {
        let alreadySeeded = await MainActor.run { settings.bundledSourcesSeededVersion == seedVersionTag }
        if alreadySeeded && !force {
            let existingCount = (try? await persistence.fetchAllSources().count) ?? 0
            if existingCount > 0 { return }
        }

        guard let zipURL = Bundle.main.url(forResource: bundledArchiveName, withExtension: "zip"),
              let zipData = try? Data(contentsOf: zipURL) else {
            await logger.record(category: .plugin, level: "WARN", message: "未找到随包内置书源压缩包 \(bundledArchiveName).zip")
            return
        }

        do {
            let entries = try ZIPArchiveReader().readAll(from: zipData)
            let byName = Dictionary(entries.map { ($0.path, $0.data) }, uniquingKeysWith: { first, _ in first })
            guard let manifestData = byName["manifest.json"] else {
                await logger.record(category: .plugin, level: "ERROR", message: "内置书源缺少 manifest.json")
                return
            }
            // 防御性去除可能残留的 UTF-8 BOM
            let cleanManifestData = stripUTF8BOM(manifestData)
            let manifest = try JSONDecoder().decode(Manifest.self, from: cleanManifestData)

            var combinedScript = ""
            for scriptName in manifest.scripts {
                guard let scriptData = byName[scriptName] else {
                    await logger.record(category: .plugin, level: "ERROR", message: "内置书源缺少声明脚本 \(scriptName)，已中止本次播种")
                    return
                }
                guard let text = String(data: stripUTF8BOM(scriptData), encoding: .utf8) else {
                    await logger.record(category: .plugin, level: "ERROR", message: "内置书源脚本 \(scriptName) UTF-8 解码失败，已中止本次播种")
                    return
                }
                combinedScript += "\n// --- \(scriptName) ---\n" + text + "\n"
            }

            let preview = try await pluginRuntime.previewSources(scriptBody: combinedScript)
            guard !preview.sources.isEmpty else {
                await logger.record(category: .plugin, level: "ERROR", message: "内置书源解析结果为空，已保留现有书源")
                return
            }
            let activeBundledIDs = Set(preview.sources.map(\.id))
            for meta in preview.sources {
                try await persistence.upsertSource(meta: meta, scriptBody: combinedScript, isBundled: true)
            }
            // P1-15：升级对账清理已被新内置包移除的旧内置书源
            _ = try? await persistence.pruneRemovedBundledSources(keepingIDs: activeBundledIDs)
            await MainActor.run {
                settings.bundledSourcesSeededVersion = seedVersionTag
            }
            await logger.record(category: .plugin, level: "INFO", message: "内置书源初始化完成：共 \(preview.sources.count) 个源")
        } catch {
            await logger.record(category: .plugin, level: "ERROR", message: "内置书源解压校验失败：\(error.localizedDescription)")
        }
    }

    /// 按 manifest.json["scripts"] 声明顺序提取并拼接 ZIP 内全部 JS（无 manifest 时自动将 common.js 置顶防乱序崩溃）
    static func extractOrderedScripts(from zipData: Data) throws -> String {
        let entries = try ZIPArchiveReader().readAll(from: zipData)
        let byName = Dictionary(entries.map { ($0.path, $0.data) }, uniquingKeysWith: { first, _ in first })

        if let manifestData = byName["manifest.json"],
           let manifest = try? JSONDecoder().decode(Manifest.self, from: stripUTF8BOM(manifestData)),
           !manifest.scripts.isEmpty {
            var ordered: [String] = []
            for scriptName in manifest.scripts {
                if let raw = byName[scriptName],
                   let text = String(data: stripUTF8BOM(raw), encoding: .utf8) {
                    ordered.append("// --- \(scriptName) ---\n" + text)
                }
            }
            if !ordered.isEmpty {
                return ordered.joined(separator: "\n")
            }
        }

        // 无 manifest.json 回退：common.js 优先，其余按路径字典序拼接
        let jsEntries = entries
            .filter { $0.path.lowercased().hasSuffix(".js") }
            .sorted { lhs, rhs in
                let lCommon = lhs.path.lowercased().hasSuffix("common.js")
                let rCommon = rhs.path.lowercased().hasSuffix("common.js")
                if lCommon != rCommon { return lCommon }
                return lhs.path < rhs.path
            }
        var chunks: [String] = []
        for entry in jsEntries {
            if let text = String(data: stripUTF8BOM(entry.data), encoding: .utf8) {
                chunks.append("// --- \(entry.path) ---\n" + text)
            }
        }
        return chunks.joined(separator: "\n")
    }

    static func stripUTF8BOM(_ data: Data) -> Data {
        data.starts(with: [0xEF, 0xBB, 0xBF]) ? Data(data.dropFirst(3)) : data
    }
}
