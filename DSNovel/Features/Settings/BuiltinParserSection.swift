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
// - 所有二级页面（编辑脚本、查看日志）一律采用 NavigationLink 推入当前导航栈，不叠加嵌套 .sheet。

struct BuiltinParserSection: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: [SortDescriptor(\BuiltinParserRecord.importedAt, order: .reverse)])
    private var records: [BuiltinParserRecord]

    let plugin: PluginRecord

    init(plugin: PluginRecord) {
        self.plugin = plugin
    }

    @State private var errorAlertMessage: String?
    @State private var statusNote: String = ""
    @State private var showDeleteConfirm = false
    /// P2-02：异步加载的已安装解析器与备份标记，消除 SwiftUI 渲染期主线程同步扫盘 I/O
    @State private var cachedInstalledParser: InstalledBuiltinParser?
    @State private var cachedScriptText: String = ""
    @State private var hasBackup: Bool = false
    /// P2-02：本地状态镜像 Keychain 配置值，确保 Toggle / Picker / TextField 编辑后界面即时刷新
    @State private var configValues: [String: String] = [:]

    /// 只对「喜马拉雅」类书源或已匹配的内置解析书源展示内置解析分区
    static func isSupportedSource(_ plugin: PluginRecord) -> Bool {
        let host = URL(string: plugin.siteURL)?.host?.lowercased() ?? ""
        if host == "ximalaya.com" || host.hasSuffix(".ximalaya.com")
            || host == "xmcdn.com" || host.hasSuffix(".xmcdn.com") {
            return true
        }
        return BuiltinParserStore.installedParsers().contains {
            $0.meta.targets.matches(sourceID: plugin.id, sourceURL: plugin.siteURL)
        }
    }

    private var activeRecord: BuiltinParserRecord? {
        records.first { record in
            let hosts = Self.parseCSV(record.targetHosts)
            let sourceIDs = Self.parseCSV(record.targetSourceIDs)
            return BuiltinParserTargets(hosts: hosts, sourceIDs: sourceIDs)
                .matches(sourceID: plugin.id, sourceURL: plugin.siteURL)
        }
    }

    private static func parseCSV(_ raw: String) -> [String] {
        var result: [String] = []
        for part in raw.split(separator: ",") {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { result.append(trimmed) }
        }
        return result
    }

    private var visibleConfigItems: [BuiltinParserConfigItem] {
        guard let parser = cachedInstalledParser else { return [] }
        var items: [BuiltinParserConfigItem] = []
        for item in parser.meta.config {
            if !QualityPolicy.managedParserConfigKeys.contains(item.key) {
                items.append(item)
            }
        }
        return items
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
        .background {
            Color.clear
                .alert("删除内置解析脚本", isPresented: $showDeleteConfirm) {
                    Button("取消", role: .cancel) {}
                    Button("删除解析脚本", role: .destructive) {
                        Task { await deleteParser() }
                    }
                } message: {
                    Text("确认删除该内置解析脚本？")
                }
        }
        .task(id: activeRecord?.id) {
            await loadCachedState()
        }
    }

    // MARK: 行

    @ViewBuilder
    private func installedRows(_ record: BuiltinParserRecord) -> some View {
        LabeledContent("解析脚本", value: "\(record.name) v\(record.version)")
        LabeledContent("更新时间", value: Self.dateFormatter.string(from: record.importedAt))

        Toggle("启用", isOn: Binding(
            get: { record.isEnabled },
            set: { newValue in
                record.isEnabled = newValue
                try? modelContext.save()
                Task { await BuiltinParserRuntime.shared.setEnabled(newValue, for: record.id) }
            }
        ))

        ForEach(visibleConfigItems, id: \.key) { item in
            configRow(item, parserID: record.id)
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

        if hasBackup {
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
        let currentValue = configValues[item.key] ?? item.defaultValue
        switch item.kind {
        case "bool":
            Toggle(item.title, isOn: Binding(
                get: { currentValue.lowercased() == "true" },
                set: { newValue in
                    let encoded = newValue ? "true" : "false"
                    configValues[item.key] = encoded
                    BuiltinParserRuntime.shared.setConfigValue(parserID: parserID, key: item.key, value: encoded)
                }
            ))
        case "enum":
            Picker(selection: Binding(
                get: { currentValue },
                set: { newValue in
                    configValues[item.key] = newValue
                    BuiltinParserRuntime.shared.setConfigValue(parserID: parserID, key: item.key, value: newValue)
                }
            )) {
                ForEach(item.options, id: \.self) { option in
                    Text(option).tag(option)
                }
            } label: {
                Text(item.title)
            }
        default:
            LabeledContent(item.title) {
                TextField("", text: Binding(
                    get: { currentValue },
                    set: { newValue in
                        configValues[item.key] = newValue
                        BuiltinParserRuntime.shared.setConfigValue(parserID: parserID, key: item.key, value: newValue)
                    }
                ))
                .multilineTextAlignment(.trailing)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            }
        }
    }

    private func editScriptLink(title: String) -> some View {
        let initialFileName = cachedInstalledParser?.fileName ?? "ximalaya_parser.js"
        let versionLabel = cachedInstalledParser?.meta.displayVersion ?? "未安装"

        return NavigationLink {
            BuiltinParserEditorPage(
                initialText: cachedScriptText,
                fileName: initialFileName,
                installedVersion: versionLabel,
                onInstalled: { parser in
                    BuiltinParserRegistrySync.upsert(context: modelContext, parser: parser)
                    Task { await loadCachedState() }
                }
            )
        } label: {
            Label(title, systemImage: "curlybraces.square")
        }
    }

    // MARK: 操作

    private func loadCachedState() async {
        guard let id = activeRecord?.id else {
            await MainActor.run {
                cachedInstalledParser = nil
                cachedScriptText = ""
                hasBackup = false
                configValues = [:]
            }
            return
        }
        let snapshot = await Task.detached(priority: .userInitiated) { () -> (InstalledBuiltinParser?, String, Bool, [String: String]) in
            let parser = BuiltinParserStore.loadParser(in: BuiltinParserStore.directory(for: id))
            let text = parser.flatMap { BuiltinParserStore.scriptText(for: $0, verifyIntegrity: false) } ?? ""
            let backup = BuiltinParserStore.backupExists(parserID: id)
            var values: [String: String] = [:]
            if let parser {
                for item in parser.meta.config {
                    values[item.key] = BuiltinParserRuntime.readConfigValue(
                        parserID: id,
                        key: item.key,
                        defaultValue: item.defaultValue
                    )
                }
            }
            return (parser, text, backup, values)
        }.value

        await MainActor.run {
            cachedInstalledParser = snapshot.0
            cachedScriptText = snapshot.1
            hasBackup = snapshot.2
            configValues = snapshot.3
        }
    }

    private func deleteParser() async {
        guard let record = activeRecord else { return }
        do {
            try await BuiltinParserRuntime.shared.uninstall(parserID: record.id)
            await MainActor.run {
                BuiltinParserRegistrySync.remove(context: modelContext, parserID: record.id)
                statusNote = ""
            }
            await loadCachedState()
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
            await loadCachedState()
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
            let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            await MainActor.run {
                statusNote = "失败 · \(reason)"
                // P2-02 修复：自检抛错时也同步更新 SwiftData 持久化状态
                if let record = activeRecord {
                    record.lastCheckStatus = "failed"
                    record.lastCheckMessage = reason
                    record.lastCheckedAt = .now
                    try? modelContext.save()
                }
            }
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
    let installedVersion: String
    let onInstalled: (InstalledBuiltinParser) -> Void

    init(
        initialText: String,
        fileName: String,
        installedVersion: String = "未安装",
        onInstalled: @escaping (InstalledBuiltinParser) -> Void
    ) {
        self.initialText = initialText
        self.fileName = fileName
        self.installedVersion = installedVersion
        self.onInstalled = onInstalled
    }

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
            scriptEditorHeader

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

    /// 工具条：从剪贴板填入 / 清空 / 只读统计（已安装版本 · 字节数 · 行数）
    private var scriptEditorHeader: some View {
        let byteCount = scriptText.utf8.count
        let lineCount = scriptText.isEmpty ? 0 : scriptText.components(separatedBy: "\n").count

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Button {
                    fillFromClipboard()
                } label: {
                    Label("从剪贴板填入", systemImage: "doc.on.clipboard")
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
            }

            HStack(spacing: 10) {
                Text("已安装版本 \(installedVersion)")
                Text("·")
                Text("\(byteCount) 字节")
                Text("·")
                Text("\(lineCount) 行")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemBackground))
    }

    private func fillFromClipboard() {
        guard let clip = UIPasteboard.general.string, !clip.isEmpty else { return }
        scriptText = clip
        errorMessage = nil
        DSHapticPolicy.fire(.selection)
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

            Section("目标书源与权限边界") {
                if !preview.meta.targets.hosts.isEmpty {
                    LabeledContent("允许域名", value: preview.meta.targets.hosts.joined(separator: ", "))
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
        if QualityPolicy.parserDeclaresLossless(preview.meta.qualities) { parts.append("无损") }
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

// MARK: - 日志页面（含脱敏导出与统计摘要；⑦ 可观测性）

struct BuiltinParserLogView: View {
    let parserID: String

    init(parserID: String) {
        self.parserID = parserID
    }

    @State private var lines: [String] = []
    @State private var stats: BuiltinParserLogStats = BuiltinParserLogStats(totalResolves: 0, successes: 0, failures: 0, cacheHits: 0)
    @State private var copiedNotice: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            if !lines.isEmpty {
                summaryRow
                Divider()
            }

            if lines.isEmpty {
                ContentUnavailableView("暂无日志", systemImage: "text.alignleft")
            } else {
                List(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(.caption, design: .monospaced))
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("解析日志")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .confirmationAction) {
                Button(copiedNotice ? "已复制" : "导出脱敏") {
                    let exported = BuiltinParserLogStore.shared.desensitizedExportText(for: parserID)
                    if !exported.isEmpty {
                        UIPasteboard.general.string = exported
                        copiedNotice = true
                        DSHapticPolicy.fire(.selection)
                    }
                }
                .disabled(lines.isEmpty)

                Button("清空") {
                    BuiltinParserLogStore.shared.clear(parserID)
                    lines = []
                    stats = BuiltinParserLogStats(totalResolves: 0, successes: 0, failures: 0, cacheHits: 0)
                    copiedNotice = false
                }
                .disabled(lines.isEmpty)
            }
        }
        .task {
            refreshLines()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { break }
                refreshLines()
            }
        }
    }

    private func refreshLines() {
        let latest = BuiltinParserLogStore.shared.lines(for: parserID)
        if latest != lines {
            lines = latest
            stats = BuiltinParserLogStore.shared.stats(for: parserID)
        }
    }

    /// 只读摘要：最近一次解析 + 成功率/缓存统计
    private var summaryRow: some View {
        let parsed = Self.parseLastLine(lines.last)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("最近一次解析")
                    .foregroundStyle(.secondary)
                Text("\(parsed.time) · \(parsed.result)")
                    .font(.caption.monospacedDigit())
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            if stats.totalResolves > 0 {
                Text("统计：成功率 \(stats.successRatePercent)% · 成功 \(stats.successes) · 失败 \(stats.failures) · 缓存命中 \(stats.cacheHits)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemBackground))
    }

    private static func parseLastLine(_ line: String?) -> (time: String, result: String) {
        guard let line, !line.isEmpty else { return ("—", "—") }
        var time = "—"
        var body = line
        if line.hasPrefix("["), let closing = line.firstIndex(of: "]") {
            let stamp = String(line[line.index(after: line.startIndex)..<closing]).trimmingCharacters(in: .whitespaces)
            if !stamp.isEmpty { time = stamp }
            body = String(line[line.index(after: closing)...]).trimmingCharacters(in: .whitespaces)
        }
        let summary = body.count > 60 ? String(body.prefix(60)) + "…" : body
        return (time, summary.isEmpty ? "—" : summary)
    }
}
