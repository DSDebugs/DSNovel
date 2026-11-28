import DSCore
import DSDesignSystem
import DSPluginKit
import SwiftUI
import UIKit

extension BuiltinParserView {
    private func buildLogItems(from rawLogs: [String]) -> [ParserLogItem] {
        var counts: [String: Int] = [:]
        return rawLogs.reversed().map { line in
            let seen = (counts[line] ?? 0) + 1
            counts[line] = seen
            return ParserLogItem(id: "\(seen)|\(line)", text: line)
        }
    }

    func reload() async {
        parsers = await container.builtinParser.listParsers()
        let raw = await container.builtinParser.combinedLogs()
        logItems = buildLogItems(from: raw)
        await container.refreshBuiltinParserActiveState()
    }

    func refreshLogsOnly(haptic: Bool = true) async {
        parsers = await container.builtinParser.listParsers()
        let raw = await container.builtinParser.combinedLogs()
        logItems = buildLogItems(from: raw)
        if haptic { DSHaptics.selection() }
    }

    func copyAllLogs() {
        let text = logItems.map(\.text).joined(separator: "\n")
        UIPasteboard.general.string = text
        DSHaptics.selection()
        banner.show("已复制 \(logItems.count) 条诊断日志", tone: .success)
    }

    func clearLogs() async {
        await container.builtinParser.clearLogs()
        logItems = []
        DSHaptics.selection()
        banner.show("已清空诊断日志", tone: .info)
    }

    func handleImportedScriptFile(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let err):
            banner.show("读取文件失败：\(err.localizedDescription)", tone: .error)
        case .success(let urls):
            guard let url = urls.first else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                banner.show("无法解码脚本文件", tone: .error)
                return
            }
            installScriptText = text
        }
    }

    func installScript() async {
        do {
            let meta = try await container.builtinParser.installParser(scriptBody: installScriptText)
            installScriptText = ""
            showInstallSheet = false
            await reload()
            banner.show("已安装：\(meta.name) v\(meta.version)", tone: .success)
        } catch {
            banner.show("安装失败：\(error.localizedDescription)", tone: .error)
        }
    }

    func setEnabled(_ parser: BuiltinParserMetaDTO, enabled: Bool) async {
        do {
            try await container.builtinParser.setEnabled(id: parser.id, enabled: enabled)
            await reload()
            DSHaptics.selection()
            banner.show(enabled ? "已启用 \(parser.name)" : "已停用 \(parser.name)", tone: .info)
        } catch {
            banner.show("切换失败：\(error.localizedDescription)", tone: .error)
        }
    }

    func runCheckStatus(_ parser: BuiltinParserMetaDTO) async {
        checkingParserID = parser.id
        defer { checkingParserID = nil }
        do {
            let result = try await container.builtinParser.checkStatus(id: parser.id)
            checkResults[parser.id] = result
            await reload()
            banner.show(result.message, tone: result.ok ? .success : .warning)
        } catch {
            await reload()
            banner.show("自检失败：\(error.localizedDescription)", tone: .error)
        }
    }

    func clearCache(_ id: String) async {
        let removed = await container.builtinParser.clearParserCache(id: id)
        await reload()
        DSHaptics.selection()
        banner.show("已清理 \(removed) 项缓存文件", tone: .info)
    }

    func removeParser(_ id: String) async {
        do {
            try await container.builtinParser.deleteParser(id: id)
            checkResults.removeValue(forKey: id)
            await reload()
            banner.show("已移除解析脚本", tone: .info)
        } catch {
            banner.show("移除失败：\(error.localizedDescription)", tone: .error)
        }
    }
}
