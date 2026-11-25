import DSCore
import DSDesignSystem
import DSPluginKit
import SwiftUI
import UIKit

extension BuiltinParserView {
    var statusOverviewCard: some View {
        HStack(spacing: DSSpacing.sm) {
            Image(systemName: activeParser != nil ? "waveform.circle.fill" : "waveform.circle")
                .font(DSTypography.title)
                .foregroundStyle(activeParser != nil ? DSColors.accent : DSColors.inkSecondary)

            VStack(alignment: .leading, spacing: 3) {
                if let active = activeParser {
                    Text("\(active.name) v\(active.version)")
                        .font(DSTypography.rowTitle)
                        .foregroundStyle(DSColors.inkPrimary)
                        .lineLimit(1)
                    Text("已生效 · 播放与下载优先走音频解析")
                        .font(DSTypography.caption)
                        .foregroundStyle(DSColors.inkSecondary)
                } else if !parsers.isEmpty {
                    Text("解析脚本已暂停")
                        .font(DSTypography.rowTitle)
                        .foregroundStyle(DSColors.inkPrimary)
                    Text("开启下方开关即可恢复音频解析")
                        .font(DSTypography.caption)
                        .foregroundStyle(DSColors.inkSecondary)
                } else {
                    Text("未安装解析脚本")
                        .font(DSTypography.rowTitle)
                        .foregroundStyle(DSColors.inkPrimary)
                    Text("点击右上角 + 导入解析脚本")
                        .font(DSTypography.caption)
                        .foregroundStyle(DSColors.inkSecondary)
                }
            }

            Spacer(minLength: 4)

            if let active = activeParser {
                DSBadge(healthTitle(for: active.healthStatus), style: badgeStyle(for: active.healthStatus))
            } else {
                DSBadge(parsers.isEmpty ? "未安装" : "已停用", style: .neutral)
            }
        }
        .padding(DSSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: DSRadius.heroCard, style: .continuous)
                .fill(DSColors.surfaceCard)
        )
    }

    var logSectionHeader: some View {
        HStack(spacing: DSSpacing.xs) {
            Text("解析与脚本诊断日志")
            Spacer()
            Button {
                Task { await refreshLogsOnly(haptic: true) }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(DSTypography.footnote)
                    .frame(minWidth: 36, minHeight: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(DSColors.accent)
            .accessibilityLabel("刷新日志")

            if !logItems.isEmpty {
                Button {
                    copyAllLogs()
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(DSTypography.footnote)
                        .frame(minWidth: 36, minHeight: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(DSColors.accent)
                .accessibilityLabel("复制全部日志")

                Button {
                    showClearLogsConfirm = true
                } label: {
                    Image(systemName: "trash")
                        .font(DSTypography.footnote)
                        .frame(minWidth: 36, minHeight: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(DSColors.danger)
                .accessibilityLabel("清空日志")
            }
        }
    }

    func parserCardRow(_ parser: BuiltinParserMetaDTO) -> some View {
        VStack(alignment: .leading, spacing: DSSpacing.sm) {
            HStack(spacing: DSSpacing.xs) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(parser.name)
                            .font(DSTypography.rowTitle)
                            .foregroundStyle(parser.isEnabled ? DSColors.inkPrimary : DSColors.inkSecondary)
                            .lineLimit(1)
                        Text("v\(parser.version)")
                            .font(DSTypography.numericCaption)
                            .foregroundStyle(DSColors.inkSecondary)
                        DSBadge(healthTitle(for: parser.healthStatus), style: badgeStyle(for: parser.healthStatus))
                    }
                    Text(capabilitySummary(for: parser))
                        .font(DSTypography.caption)
                        .foregroundStyle(DSColors.inkSecondary)
                        .lineLimit(2)
                }
                Spacer(minLength: DSSpacing.xs)
                Toggle("", isOn: Binding(
                    get: { parser.isEnabled },
                    set: { next in Task { await setEnabled(parser, enabled: next) } }
                ))
                .labelsHidden()
                .tint(DSColors.accent)
                .fixedSize()
                .accessibilityLabel("启用或停用 \(parser.name)")
            }

            if let result = checkResults[parser.id] {
                HStack(spacing: 6) {
                    Image(systemName: result.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(DSTypography.caption)
                        .foregroundStyle(result.ok ? DSColors.success : DSColors.warning)
                    Text(result.message)
                        .font(DSTypography.caption)
                        .foregroundStyle(DSColors.inkSecondary)
                        .lineLimit(2)
                }
                .padding(.horizontal, DSSpacing.xs)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: DSRadius.sm, style: .continuous)
                        .fill(DSColors.surfaceGrouped)
                )
            }

            HStack(spacing: DSSpacing.sm) {
                Button {
                    Task { await runCheckStatus(parser) }
                } label: {
                    HStack(spacing: 4) {
                        if checkingParserID == parser.id {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "stethoscope")
                                .font(DSTypography.caption)
                        }
                        Text(checkingParserID == parser.id ? "自检中..." : "运行自检")
                            .font(DSTypography.caption.weight(.medium))
                    }
                    .frame(maxWidth: .infinity, minHeight: 36)
                }
                .buttonStyle(.borderedProminent)
                .tint(DSColors.accent)
                .disabled(checkingParserID == parser.id)

                Button {
                    Task { await clearCache(parser.id) }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkles")
                            .font(DSTypography.caption)
                        Text("清理缓存")
                            .font(DSTypography.caption.weight(.medium))
                    }
                    .frame(maxWidth: .infinity, minHeight: 36)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 4)
    }

    func logRow(_ line: String) -> some View {
        HStack(alignment: .top, spacing: DSSpacing.xs) {
            Circle()
                .fill(logDotColor(for: line))
                .frame(width: 6, height: 6)
                .padding(.top, 6)
            Text(line)
                .font(DSTypography.caption.monospaced())
                .foregroundStyle(DSColors.inkPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
    }

    var installSheetContent: some View {
        DSSheetScaffold(title: "导入音频解析脚本", banner: banner, onDismiss: { showInstallSheet = false }) {
            VStack(spacing: DSSpacing.md) {
                Button {
                    showFileImporter = true
                } label: {
                    Label("从本地文件导入 .js 脚本", systemImage: "folder")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)

                TextEditor(text: $installScriptText)
                    .font(DSTypography.caption.monospaced())
                    .frame(minHeight: 220)
                    .overlay(
                        RoundedRectangle(cornerRadius: DSRadius.sm, style: .continuous)
                            .stroke(DSColors.separator, lineWidth: 1)
                    )

                DSActionButton(title: "校验并安装脚本", icon: "checkmark.shield", role: .primary) {
                    Task { await installScript() }
                }
                .disabled(installScriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(DSSpacing.md)
        }
    }

    func capabilitySummary(for parser: BuiltinParserMetaDTO) -> String {
        var parts: [String] = []
        if !parser.qualities.isEmpty {
            parts.append("音质：\(parser.qualities.map(\.displayName).joined(separator: "/"))")
        }
        var modes: [String] = []
        if parser.supportsPlayback { modes.append("播放") }
        if parser.supportsDownload { modes.append("下载") }
        if !modes.isEmpty {
            parts.append("支持 \(modes.joined(separator: "·"))")
        }
        return parts.isEmpty ? "喜马拉雅音频解析引擎" : parts.joined(separator: " · ")
    }

    func healthTitle(for status: ParserHealthStatus) -> String {
        switch status {
        case .healthy: return "正常"
        case .degraded: return "降级"
        case .failed: return "异常"
        case .unknown: return "未检"
        }
    }

    func badgeStyle(for status: ParserHealthStatus) -> DSBadgeStyle {
        switch status {
        case .healthy: return .success
        case .degraded: return .warning
        case .failed: return .danger
        case .unknown: return .neutral
        }
    }

    func logDotColor(for line: String) -> Color {
        if line.contains("失败") || line.contains("异常") || line.contains("错误") {
            return DSColors.danger
        }
        if line.contains("拦截") || line.contains("未通过") || line.contains("回退") || line.contains("试听") {
            return DSColors.warning
        }
        if line.contains("成功") || line.contains("通过") || line.contains("已启用") || line.contains("已安装") {
            return DSColors.success
        }
        return DSColors.inkSecondary
    }

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
