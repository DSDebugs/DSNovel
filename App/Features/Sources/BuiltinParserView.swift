import DSCore
import DSDesignSystem
import DSPluginKit
import SwiftUI
import UniformTypeIdentifiers

/// 内置解析器管理页（保留 16 槽位/导入 .js/手工配置/自检/清缓存/日志完整功能，视觉对齐 v2.8）
struct BuiltinParserView: View {
    private struct ParserLogEntry: Identifiable {
        let id = UUID()
        let text: String
    }

    @Environment(AppContainer.self) private var container
    @Environment(DSBannerCoordinator.self) private var banner
    @State private var parsers: [BuiltinParserMetaDTO] = []
    @State private var logs: [ParserLogEntry] = []
    @State private var statusByID: [String: BuiltinParserStatusDTO] = [:]
    @State private var checkingID: String?
    @State private var isInstalling = false
    @State private var scriptInput: String = ""
    @State private var showInstallSheet = false
    @State private var showFileImporter = false
    @State private var configTarget: BuiltinParserMetaDTO?
    @State private var sampleTrackInput: String = ""
    @State private var manualCookieInput: String = ""

    var body: some View {
        List {
            Section("已安装内置解析器（独立于书源）") {
                if parsers.isEmpty {
                    Text("尚未安装自定义内置解析器脚本。")
                        .font(DSTypography.footnote)
                        .foregroundStyle(DSColors.inkSecondary)
                        .listRowBackground(DSColors.surfaceCard)
                } else {
                    ForEach(parsers) { p in
                        parserRow(p)
                            .listRowBackground(DSColors.surfaceCard)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    Task { await removeParser(p) }
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                    }
                }
            }

            Section("解析与脚本诊断日志") {
                if logs.isEmpty {
                    Text("暂无解析器运行日志")
                        .font(DSTypography.footnote)
                        .foregroundStyle(DSColors.inkSecondary)
                        .listRowBackground(DSColors.surfaceCard)
                } else {
                    ForEach(logs) { entry in
                        Text(entry.text)
                            .font(DSTypography.monoCaption)
                            .foregroundStyle(DSColors.inkSecondary)
                            .listRowBackground(DSColors.surfaceCard)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(DSColors.surfaceGrouped)
        .navigationTitle("内置解析器")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showFileImporter = true
                    } label: {
                        Label("导入 .js 脚本文件", systemImage: "doc.badge.plus")
                    }
                    Button {
                        showInstallSheet = true
                    } label: {
                        Label("粘贴脚本安装", systemImage: "doc.on.clipboard")
                    }
                } label: {
                    Text("安装脚本")
                        .frame(minHeight: 44)
                }
            }
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.javaScript, .plainText, .sourceCode],
            allowsMultipleSelection: false
        ) { result in
            Task { await handleImportedFile(result) }
        }
        .sheet(isPresented: $showInstallSheet) {
            DSSheetScaffold(title: "安装内置解析器", banner: banner, onDismiss: { showInstallSheet = false }) {
                VStack(spacing: DSSpacing.md) {
                    TextEditor(text: $scriptInput)
                        .font(DSTypography.footnote)
                        .padding(DSSpacing.xs)
                        .background(DSColors.surfaceCard, in: RoundedRectangle(cornerRadius: DSRadius.md))
                    Button {
                        Task { await install(scriptBody: scriptInput) }
                    } label: {
                        if isInstalling {
                            ProgressView()
                                .frame(maxWidth: .infinity, minHeight: 44)
                        } else {
                            Text("校验并原子安装")
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isInstalling || scriptInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(DSSpacing.md)
            }
        }
        .sheet(item: $configTarget) { parser in
            DSSheetScaffold(title: "配置 · \(parser.name)", banner: banner, onDismiss: { configTarget = nil }) {
                Form {
                    Section("自检样本章节 ID（可空）") {
                        TextField("如 123456789，留空则使用最近成功章节", text: $sampleTrackInput)
                            .keyboardType(.numberPad)
                            .listRowBackground(DSColors.surfaceCard)
                    }
                    Section("手工 Cookie（可选，优先使用书源本机登录态）") {
                        TextEditor(text: $manualCookieInput)
                            .font(DSTypography.monoCaption)
                            .frame(minHeight: 88)
                            .listRowBackground(DSColors.surfaceCard)
                    }
                    Section {
                        Button("保存配置") {
                            Task { await saveConfig(for: parser) }
                        }
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .listRowBackground(DSColors.surfaceCard)
                    }
                }
                .scrollContentBackground(.hidden)
                .background(DSColors.surfaceGrouped)
            }
        }
        .task { await reload() }
    }

    @ViewBuilder
    private func parserRow(_ p: BuiltinParserMetaDTO) -> some View {
        VStack(alignment: .leading, spacing: DSSpacing.xs) {
            HStack {
                Text(p.name)
                    .font(DSTypography.rowTitle)
                Spacer()
                DSBadge(healthLabel(p.healthStatus), style: healthBadgeStyle(p.healthStatus))
            }
            Text("v\(p.version) · \(p.isEnabled ? "已启用" : "已停用") · SHA256: \(p.sha256.prefix(12))")
                .font(DSTypography.monoCaption)
                .foregroundStyle(DSColors.inkSecondary)
            if let status = statusByID[p.id] {
                Text(status.message)
                    .font(DSTypography.caption)
                    .foregroundStyle(status.ok ? DSColors.success : DSColors.danger)
            }
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: DSSpacing.xs),
                    GridItem(.flexible(), spacing: DSSpacing.xs)
                ],
                spacing: DSSpacing.xs
            ) {
                Button {
                    Task { await runCheckStatus(for: p) }
                } label: {
                    Text(checkingID == p.id ? "自检中…" : "自检")
                        .font(DSTypography.caption)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .disabled(checkingID != nil)

                Button {
                    Task { await openConfig(for: p) }
                } label: {
                    Text("配置")
                        .font(DSTypography.caption)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)

                Button {
                    Task { await toggleEnabled(p) }
                } label: {
                    Text(p.isEnabled ? "停用" : "启用")
                        .font(DSTypography.caption)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)

                Button {
                    Task { await clearCache(for: p) }
                } label: {
                    Text("清缓存")
                        .font(DSTypography.caption)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
            }
            .padding(.top, 2)
        }
        .padding(.vertical, 2)
    }

    private func reload() async {
        parsers = await container.builtinParser.listParsers()
        let rawLogs = await container.builtinParser.combinedLogs()
        logs = rawLogs.map { ParserLogEntry(text: $0) }
    }

    private func install(scriptBody: String) async {
        guard !isInstalling else { return }
        isInstalling = true
        defer { isInstalling = false }
        do {
            let meta = try await container.builtinParser.installParser(scriptBody: scriptBody)
            scriptInput = ""
            showInstallSheet = false
            await container.refreshBuiltinParserActiveState()
            await reload()
            banner.show("已原子安装解析器 \(meta.name) v\(meta.version)", tone: .success)
        } catch {
            banner.show("安装失败（已回滚）：\(error.localizedDescription)", tone: .error)
        }
    }

    private func handleImportedFile(_ result: Result<[URL], Error>) async {
        do {
            guard let url = try result.get().first else { return }
            let text: String = try await Task.detached(priority: .userInitiated) {
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                return try String(contentsOf: url, encoding: .utf8)
            }.value
            await install(scriptBody: text)
        } catch {
            banner.show("读取脚本文件失败：\(error.localizedDescription)", tone: .error)
        }
    }

    private func runCheckStatus(for parser: BuiltinParserMetaDTO) async {
        checkingID = parser.id
        defer { checkingID = nil }
        do {
            let status = try await container.builtinParser.checkStatus(id: parser.id)
            statusByID[parser.id] = status
            await reload()
            banner.show(status.ok ? "自检通过（\(status.latencyMs)ms）" : "自检未通过", tone: status.ok ? .success : .warning)
        } catch {
            banner.show("自检失败：\(error.localizedDescription)", tone: .error)
        }
    }

    private func openConfig(for parser: BuiltinParserMetaDTO) async {
        sampleTrackInput = (await container.builtinParser.getPref(parserID: parser.id, key: "sampleTrackId")) ?? ""
        manualCookieInput = (await container.builtinParser.getPref(parserID: parser.id, key: "cookie")) ?? ""
        configTarget = parser
    }

    private func saveConfig(for parser: BuiltinParserMetaDTO) async {
        await container.builtinParser.setPref(parserID: parser.id, key: "sampleTrackId", value: sampleTrackInput)
        await container.builtinParser.setPref(parserID: parser.id, key: "cookie", value: manualCookieInput)
        configTarget = nil
        await reload()
        banner.show("已保存解析器配置", tone: .success)
    }

    private func toggleEnabled(_ parser: BuiltinParserMetaDTO) async {
        do {
            try await container.builtinParser.setEnabled(id: parser.id, enabled: !parser.isEnabled)
            await container.refreshBuiltinParserActiveState()
            await reload()
        } catch {
            banner.show("切换状态失败：\(error.localizedDescription)", tone: .error)
        }
    }

    private func clearCache(for parser: BuiltinParserMetaDTO) async {
        let count = await container.builtinParser.clearParserCache(id: parser.id)
        await reload()
        banner.show(count > 0 ? "已清理 \(count) 项直链/凭据缓存" : "暂无可清理缓存", tone: .info)
    }

    private func removeParser(_ parser: BuiltinParserMetaDTO) async {
        do {
            try await container.builtinParser.deleteParser(id: parser.id)
            statusByID.removeValue(forKey: parser.id)
            await container.refreshBuiltinParserActiveState()
            await reload()
            banner.show("已移除 \(parser.name)", tone: .info)
        } catch {
            banner.show("移除失败：\(error.localizedDescription)", tone: .error)
        }
    }

    private func healthLabel(_ status: ParserHealthStatus) -> String {
        switch status {
        case .healthy: return "健康"
        case .degraded: return "降级"
        case .failed: return "异常"
        case .unknown: return "待检测"
        }
    }

    private func healthBadgeStyle(_ status: ParserHealthStatus) -> DSBadgeStyle {
        switch status {
        case .healthy: return .success
        case .degraded: return .warning
        case .failed: return .danger
        case .unknown: return .neutral
        }
    }
}
