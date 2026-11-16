import SwiftUI
import SwiftData
import UIKit

// MARK: - 内置解析分区（书源详情的「内置解析」功能区）
//
// 交互约束（按需求确定）：
// - 无论是否配置脚本，本分区**不输出任何提示**：没有空态引导文案、没有徽标、没有 Toast、没有红点。
//   未配置时只是一个中性空位（"解析脚本：未安装" + 一个「编辑脚本」导航入口）。
// - 全 App 唯一的内置解析提示出口是「VIP 章节报错」时的跳转按钮（见 PlayerViews / BookDetailView）。
// - 只有「保存/校验失败」与「用户主动点自检失败」会出声（属错误反馈，不是提示）。
// - 注意：由于父视图 PluginDetailAndCheckSheet 本身是一个 Sheet 且包含 NavigationStack，
//   所有二级页面（编辑脚本、查看日志）一律采用 NavigationLink 推入当前导航栈，
//   绝不在 Section 行视图上叠加嵌套 .sheet，避免 iOS Form/Sheet 焦点更新触发父级 Sheet 误关！

struct BuiltinParserSection: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: [SortDescriptor(\BuiltinParserRecord.importedAt, order: .reverse)])
    private var records: [BuiltinParserRecord]

    let plugin: PluginRecord

    @State private var errorAlertMessage: String?
    @State private var statusNote: String = ""
    @State private var showDeleteConfirm = false
    @State private var strategy: BuiltinParserStrategy = .fallback
    @State private var configValues: [String: String] = [:]

    /// 只对「喜马拉雅」类书源展示内置解析分区（其它书源不考虑）
    static func isSupportedSource(_ plugin: PluginRecord) -> Bool {
        let host = URL(string: plugin.siteURL)?.host?.lowercased() ?? ""
        if host.contains("ximalaya") || host.contains("xmcdn") { return true }
        return !BuiltinParserStore.installedParsers().filter {
            $0.meta.targets.matches(sourceID: plugin.id, sourceURL: plugin.siteURL)
        }.isEmpty
    }

    private var activeRecord: BuiltinParserRecord? {
        records.first { record in
            let hosts = record.targetHosts.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let sourceIDs = record.targetSourceIDs.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return BuiltinParserTargets(hosts: hosts, sourceIDs: sourceIDs)
                .matches(sourceID: plugin.id, sourceURL: plugin.siteURL)
        }
    }

    private var installedParser: InstalledBuiltinParser? {
        guard let id = activeRecord?.id else { return nil }
        return BuiltinParserStore.loadParser(in: BuiltinParserStore.directory(for: id))
    }

    var body: some View {
        Section(BuiltinParserStrings.sectionTitle) {
            if let record = activeRecord {
                installedRows(record)
            } else {
                // 中性空位：只有状态与编辑入口，没有任何引导性文案
                LabeledContent("解析脚本", value: BuiltinParserStrings.notInstalledValue)
                editScriptLink(title: "编辑脚本")
            }

            if !statusNote.isEmpty {
                LabeledContent("最近自检", value: statusNote)
            }
        }
        .alert("提示", isPresented: Binding(
            get: { errorAlertMessage != nil },
            set: { if !$0 { errorAlertMessage = nil } }
        )) {
            Button("知道了", role: .cancel) { errorAlertMessage = nil }
        } message: {
            Text(errorAlertMessage ?? "")
        }
        .confirmationDialog("确认删除该内置解析脚本？", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("删除解析脚本", role: .destructive) {
                Task { await deleteParser() }
            }
            Button("取消", role: .cancel) {}
        }
        .task {
            await refreshState()
        }
    }

    // MARK: 行

    @ViewBuilder
    private func installedRows(_ record: BuiltinParserRecord) -> some View {
        LabeledContent("解析脚本", value: "\(record.name) v\(record.version)")
        LabeledContent("目标域名", value: record.targetHostList.isEmpty ? "—" : record.targetHostList.joined(separator: ", "))
        if !record.author.isEmpty {
            LabeledContent("作者", value: record.author)
        }
        LabeledContent("文件", value: "\(record.fileName) · \(record.formattedSize)")
        LabeledContent("校验值", value: String(record.sha256.prefix(12)))
        LabeledContent("更新时间", value: Self.dateFormatter.string(from: record.importedAt))

        Toggle("启用", isOn: Binding(
            get: { record.isEnabled },
            set: { newValue in
                record.isEnabled = newValue
                try? modelContext.save()
                Task { await BuiltinParserRuntime.shared.setEnabled(newValue, for: record.id) }
            }
        ))

        Picker("解析策略", selection: $strategy) {
            ForEach(BuiltinParserStrategy.allCases, id: \.self) { item in
                Text(item.title).tag(item)
            }
        }
        .onChange(of: strategy) { _, newValue in
            Task { await BuiltinParserRuntime.shared.setStrategy(newValue, for: record.id) }
        }

        if let parser = installedParser {
            ForEach(parser.meta.config, id: \.key) { item in
                configRow(item, parserID: record.id)
            }
        }

        Button {
            Task { await runCheck(parserID: record.id) }
        } label: {
            Label("自检", systemImage: "stethoscope")
        }

        editScriptLink(title: "编辑脚本")

        NavigationLink {
            BuiltinParserLogView(parserID: record.id)
        } label: {
            Label("查看日志", systemImage: "text.alignleft")
        }

        if BuiltinParserStore.backupExists(parserID: record.id) {
            Button {
                Task { await rollback(parserID: record.id) }
            } label: {
                Label("回滚到上一版脚本", systemImage: "arrow.uturn.backward")
            }
        }

        Button(role: .destructive) {
            showDeleteConfirm = true
        } label: {
            Label("删除解析脚本", systemImage: "trash")
        }
    }

    @ViewBuilder
    private func configRow(_ item: BuiltinParserConfigItem, parserID: String) -> some View {
        switch item.kind {
        case "bool":
            Toggle(item.title, isOn: Binding(
                get: { (configValues[item.key] ?? item.defaultValue).lowercased() == "true" },
                set: { newValue in
                    let text = newValue ? "true" : "false"
                    configValues[item.key] = text
                    Task { await BuiltinParserRuntime.shared.setConfigValue(parserID: parserID, key: item.key, value: text) }
                }
            ))
        case "enum":
            Picker(item.title, selection: Binding(
                get: { configValues[item.key] ?? item.defaultValue },
                set: { newValue in
                    configValues[item.key] = newValue
                    Task { await BuiltinParserRuntime.shared.setConfigValue(parserID: parserID, key: item.key, value: newValue) }
                }
            )) {
                ForEach(item.options, id: \.self) { option in
                    Text(option).tag(option)
                }
            }
        default:
            LabeledContent(item.title) {
                TextField("", text: Binding(
                    get: { configValues[item.key] ?? item.defaultValue },
                    set: { newValue in
                        configValues[item.key] = newValue
                        Task { await BuiltinParserRuntime.shared.setConfigValue(parserID: parserID, key: item.key, value: newValue) }
                    }
                ))
                .multilineTextAlignment(.trailing)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            }
        }
    }

    private func editScriptLink(title: String) -> some View {
        let currentParser = installedParser
        let initialText = currentParser.flatMap { BuiltinParserStore.scriptText(for: $0) } ?? ""
        let initialFileName = currentParser?.fileName ?? "ximalaya_parser.js"

        return NavigationLink {
            BuiltinParserEditorPage(
                initialText: initialText,
                fileName: initialFileName,
                onInstalled: { parser in
                    BuiltinParserRegistrySync.upsert(context: modelContext, parser: parser)
                    strategy = BuiltinParserStrategy.fallback
                    configValues = [:]
                    Task { await refreshState() }
                }
            )
        } label: {
            Label(title, systemImage: "curlybraces.square")
        }
    }

    // MARK: 操作

    private func deleteParser() async {
        guard let record = activeRecord else { return }
        do {
            try await BuiltinParserRuntime.shared.uninstall(parserID: record.id)
            await MainActor.run {
                BuiltinParserRegistrySync.remove(context: modelContext, parserID: record.id)
                statusNote = ""
            }
            await refreshState()
        } catch {
            await MainActor.run {
                errorAlertMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func rollback(parserID: String) async {
        do {
            try BuiltinParserStore.rollbackScript(parserID: parserID)
            let parsers = await BuiltinParserRuntime.shared.reload()
            await MainActor.run {
                if let restored = parsers.first(where: { $0.id == parserID }) {
                    BuiltinParserRegistrySync.upsert(context: modelContext, parser: restored)
                }
                errorAlertMessage = nil
            }
            await refreshState()
        } catch {
            await MainActor.run {
                errorAlertMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func runCheck(parserID: String) async {
        do {
            let status = try await BuiltinParserRuntime.shared.checkStatus(parserID: parserID)
            await MainActor.run {
                statusNote = status.ok
                    ? "通过 · \(status.latencyMs)ms\(status.nickname.isEmpty ? "" : " · \(status.nickname)")\(status.vipExpireAt.isEmpty ? "" : " · VIP 到期 \(status.vipExpireAt)")"
                    : "失败 · \(status.message)"
                if let record = activeRecord {
                    record.lastCheckStatus = status.ok ? "ok" : "failed"
                    record.lastCheckMessage = status.message
                    record.lastLatencyMs = status.latencyMs
                    record.lastCheckedAt = .now
                    record.lastAccountNickname = status.nickname
                    record.lastAccountExpireAt = status.vipExpireAt
                    try? modelContext.save()
                }
            }
        } catch {
            await MainActor.run {
                // 用户主动点了自检 → 失败属错误反馈，允许显示
                statusNote = "失败 · \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
            }
        }
    }

    private func refreshState() async {
        guard let record = activeRecord else {
            await MainActor.run { configValues = [:] }
            return
        }
        let strategyValue = await BuiltinParserRuntime.shared.strategy(for: record.id)
        var values: [String: String] = [:]
        if let parser = installedParser {
            for item in parser.meta.config {
                let value = await BuiltinParserRuntime.shared.configValue(parserID: record.id, key: item.key)
                values[item.key] = value ?? item.defaultValue
            }
        }
        // 不主动回填历史自检结果（避免产生提示感），仅在用户点「自检」后展示
        await MainActor.run {
            strategy = strategyValue
            configValues = values
        }
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()
}

// MARK: - 脚本编辑器页面（通过 NavigationLink 推入当前详情 Sheet 的导航栈，杜绝嵌套 Sheet 闪退）

struct BuiltinParserEditorPage: View {
    let initialText: String
    let fileName: String
    let onInstalled: (InstalledBuiltinParser) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var scriptText: String = ""
    @State private var didLoadInitial: Bool = false
    @State private var isAnalyzing: Bool = false
    @State private var preview: BuiltinParserPreview?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let preview {
                previewConfirmView(preview)
            } else {
                editorMainView
            }
        }
        .navigationTitle(preview == nil ? "编辑脚本" : "确认保存")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if preview != nil {
                ToolbarItem(placement: .cancellationAction) {
                    Button("返回编辑") {
                        self.preview = nil
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(preview?.isUpdate == true ? "覆盖保存" : "确认保存") {
                        if let currentPreview = self.preview {
                            Task { await performInstall(currentPreview) }
                        }
                    }
                    .fontWeight(.semibold)
                    .disabled(isAnalyzing)
                }
            } else {
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await validateScript() }
                    } label: {
                        if isAnalyzing {
                            ProgressView()
                        } else {
                            Text("校验并保存")
                                .fontWeight(.semibold)
                        }
                    }
                    .disabled(isAnalyzing || scriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .alert("提示", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("知道了", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .onAppear {
            if !didLoadInitial {
                didLoadInitial = true
                scriptText = initialText
            }
        }
    }

    private var editorMainView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button {
                    if let clip = UIPasteboard.general.string, !clip.isEmpty {
                        scriptText = clip
                    } else {
                        errorMessage = "剪贴板为空，请先复制脚本内容"
                    }
                } label: {
                    Label("从剪贴板粘贴", systemImage: "doc.on.clipboard")
                        .font(.subheadline.weight(.medium))
                }
                .buttonStyle(.bordered)

                Button(role: .destructive) {
                    scriptText = ""
                } label: {
                    Label("清空", systemImage: "xmark.circle")
                        .font(.subheadline)
                }
                .buttonStyle(.bordered)
                .disabled(scriptText.isEmpty)

                Spacer()

                Text("\(scriptText.utf8.count) 字节")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(.secondarySystemBackground))

            Divider()

            ZStack(alignment: .topLeading) {
                TextEditor(text: $scriptText)
                    .font(.system(.footnote, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .scrollContentBackground(.hidden)
                    .padding(12)

                if scriptText.isEmpty {
                    Text("在此粘贴内置解析脚本内容（调用 registerBuiltinParser({...}) 的 JavaScript 代码）…")
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 17)
                        .padding(.vertical, 20)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    private func previewConfirmView(_ preview: BuiltinParserPreview) -> some View {
        Form {
            Section("解析脚本") {
                LabeledContent("名称", value: preview.meta.name)
                LabeledContent("版本", value: preview.meta.displayVersion)
                if !preview.meta.author.isEmpty {
                    LabeledContent("作者", value: preview.meta.author)
                }
                LabeledContent("文件", value: preview.fileName)
                LabeledContent("大小", value: String(format: "%.1f KB", Double(preview.sizeBytes) / 1024.0))
                LabeledContent("SHA-256", value: String(preview.sha256.prefix(16)))
            }

            Section("目标书源") {
                if !preview.meta.targets.hosts.isEmpty {
                    LabeledContent("域名", value: preview.meta.targets.hosts.joined(separator: ", "))
                }
                if !preview.meta.targets.sourceIDs.isEmpty {
                    LabeledContent("sourceID", value: preview.meta.targets.sourceIDs.joined(separator: ", "))
                }
                LabeledContent("能力", value: capabilitiesText(for: preview))
            }

            if !preview.meta.summary.isEmpty {
                Section("说明") {
                    Text(preview.meta.summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            if preview.isUpdate {
                Section {
                    LabeledContent("已安装版本", value: preview.installedVersion ?? "—")
                    Text("确认后将覆盖同名解析脚本，旧脚本会保留为备份以便回滚。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func capabilitiesText(for preview: BuiltinParserPreview) -> String {
        var parts: [String] = []
        if preview.meta.supportsPlayback { parts.append("播放") }
        if preview.meta.supportsDownload { parts.append("下载") }
        if preview.meta.requiresCookie { parts.append("需要 Cookie") }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }

    private func validateScript() async {
        let trimmed = scriptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = "脚本内容不能为空，请粘贴内置解析脚本代码"
            return
        }
        isAnalyzing = true
        do {
            let analyzed = try await BuiltinParserRuntime.shared.analyze(
                scriptText: scriptText,
                fileName: fileName.isEmpty ? "ximalaya_parser.js" : fileName
            )
            await MainActor.run {
                isAnalyzing = false
                preview = analyzed
            }
        } catch {
            await MainActor.run {
                isAnalyzing = false
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func performInstall(_ currentPreview: BuiltinParserPreview) async {
        isAnalyzing = true
        do {
            let installed = try await BuiltinParserRuntime.shared.install(preview: currentPreview)
            await MainActor.run {
                isAnalyzing = false
                onInstalled(installed)
                dismiss()
            }
        } catch {
            await MainActor.run {
                isAnalyzing = false
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}

// MARK: - 日志页面（通过 NavigationLink 推入，避免嵌套 Sheet 闪退）

struct BuiltinParserLogView: View {
    let parserID: String

    @State private var lines: [String] = []

    var body: some View {
        Group {
            if lines.isEmpty {
                ContentUnavailableView("暂无日志", systemImage: "text.alignleft")
            } else {
                List(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(.caption, design: .monospaced))
                }
            }
        }
        .navigationTitle("解析日志")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("清空") {
                    BuiltinParserLogStore.shared.clear(parserID)
                    lines = []
                }
                .disabled(lines.isEmpty)
            }
        }
        .task {
            lines = BuiltinParserLogStore.shared.lines(for: parserID)
        }
    }
}
