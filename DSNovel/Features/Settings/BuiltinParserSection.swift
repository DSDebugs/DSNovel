import SwiftUI
import SwiftData
import UniformTypeIdentifiers

// MARK: - 内置解析分区（书源详情的「内置解析」功能区）
//
// 交互约束（按需求确定）：
// - 无论是否导入脚本，本分区**不输出任何提示**：没有空态引导文案、没有徽标、没有 Toast、没有红点。
//   未导入时只是一个中性空位（"解析脚本：未安装" + 一个导入入口控件）。
// - 全 App 唯一的内置解析提示出口是「VIP 章节报错」时的跳转按钮（见 PlayerViews / BookDetailView）。
// - 只有「导入/更新失败」与「用户主动点自检失败」会出声（属错误反馈，不是提示）。

struct BuiltinParserSection: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: [SortDescriptor(\BuiltinParserRecord.importedAt, order: .reverse)])
    private var records: [BuiltinParserRecord]

    let plugin: PluginRecord

    @State private var showFileImporter = false
    @State private var isImporting = false
    @State private var pendingPreview: BuiltinParserPreview?
    @State private var errorAlertMessage: String?
    @State private var statusNote: String = ""
    @State private var showLogSheet = false
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

    private var activeRecord: BuiltinParserRecord? { records.first }

    private var installedParser: InstalledBuiltinParser? {
        guard let id = activeRecord?.id else { return nil }
        return BuiltinParserStore.loadParser(in: BuiltinParserStore.directory(for: id))
    }

    var body: some View {
        Section(BuiltinParserStrings.sectionTitle) {
            if let record = activeRecord {
                installedRows(record)
            } else {
                // 中性空位：只有状态与导入入口，没有任何引导性文案
                LabeledContent("解析脚本", value: BuiltinParserStrings.notInstalledValue)
                importButton(title: "导入脚本（.js）")
            }

            if !statusNote.isEmpty {
                LabeledContent("最近自检", value: statusNote)
            }
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: Self.parserContentTypes,
            allowsMultipleSelection: false
        ) { result in
            handleFileImport(result)
        }
        .sheet(item: $pendingPreview) { preview in
            BuiltinParserPreviewSheet(preview: preview) {
                pendingPreview = nil
            } onConfirm: {
                pendingPreview = nil
                Task { await install(preview: preview) }
            }
        }
        .sheet(isPresented: $showLogSheet) {
            BuiltinParserLogSheet(parserID: activeRecord?.id ?? "")
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
        LabeledContent("导入时间", value: Self.dateFormatter.string(from: record.importedAt))

        Toggle("启用", isOn: Binding(
            get: { record.isEnabled },
            set: { newValue in
                record.isEnabled = newValue
                try? modelContext.save()
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

        importButton(title: "更新脚本（.js）")

        Button {
            showLogSheet = true
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

    private func importButton(title: String) -> some View {
        Button {
            showFileImporter = true
        } label: {
            if isImporting {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("导入中…")
                }
            } else {
                Label(title, systemImage: "square.and.arrow.down")
            }
        }
        .disabled(isImporting)
    }

    // MARK: 导入

    private static var parserContentTypes: [UTType] {
        var types: [UTType] = [.javaScript, .plainText, .sourceCode, .json, .data]
        if let js = UTType(filenameExtension: "js") { types.insert(js, at: 0) }
        return types
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            errorAlertMessage = "读取失败：\(error.localizedDescription)"
        case .success(let urls):
            guard let url = urls.first else { return }
            isImporting = true
            Task {
                do {
                    let (text, fileName) = try await Self.readImportedFile(url)
                    let preview = try await BuiltinParserRuntime.shared.analyze(scriptText: text, fileName: fileName)
                    isImporting = false
                    pendingPreview = preview
                } catch {
                    isImporting = false
                    errorAlertMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            }
        }
    }

    /// 后台线程 + 安全作用域 + 文件协调读取（与书源导入同一套做法）
    private static func readImportedFile(_ url: URL) async throws -> (text: String, fileName: String) {
        try await Task.detached(priority: .userInitiated) { () -> (String, String) in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }

            var coordinatorError: NSError?
            var data: Data?
            let coordinator = NSFileCoordinator()
            coordinator.coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinatorError) { target in
                data = try? Data(contentsOf: target, options: .mappedIfSafe)
            }
            if let coordinatorError { throw coordinatorError }
            guard let data else { throw BuiltinParserError.scriptInvalid("无法读取所选文件") }
            guard let text = PluginRuntimeDecoding.decodeScriptText(data) else {
                throw BuiltinParserError.scriptInvalid("无法解码脚本内容（支持 UTF-8 / UTF-16 / GB18030）")
            }
            return (text, url.lastPathComponent)
        }.value
    }

    private func install(preview: BuiltinParserPreview) async {
        do {
            let parser = try await BuiltinParserRuntime.shared.install(preview: preview)
            await MainActor.run {
                BuiltinParserRegistrySync.upsert(context: modelContext, parser: parser)
                strategy = BuiltinParserStrategy.fallback
                configValues = [:]
            }
            await refreshState()
            // 安装成功不弹任何提示（按需求：内置解析不做提示）
        } catch {
            await MainActor.run {
                errorAlertMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
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
            await BuiltinParserRuntime.shared.reload()
            await MainActor.run { errorAlertMessage = nil }
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

// MARK: - 导入预览（写入前的确认弹窗，不是提示）

struct BuiltinParserPreviewSheet: View {
    let preview: BuiltinParserPreview
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        NavigationStack {
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
                    LabeledContent("能力", value: capabilitiesText)
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
            .navigationTitle("确认导入")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(preview.isUpdate ? "覆盖安装" : "安装", action: onConfirm)
                }
            }
        }
    }

    private var capabilitiesText: String {
        var parts: [String] = []
        if preview.meta.supportsPlayback { parts.append("播放") }
        if preview.meta.supportsDownload { parts.append("下载") }
        if preview.meta.requiresCookie { parts.append("需要 Cookie") }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }
}

// MARK: - 日志（仅用户主动打开时展示）

struct BuiltinParserLogSheet: View {
    let parserID: String

    @Environment(\.dismiss) private var dismiss
    @State private var lines: [String] = []

    var body: some View {
        NavigationStack {
            Group {
                if lines.isEmpty {
                    ContentUnavailableView("暂无日志", systemImage: "text.alignleft")
                } else {
                    List(lines, id: \.self) { line in
                        Text(line)
                            .font(.system(.caption, design: .monospaced))
                    }
                }
            }
            .navigationTitle("解析日志")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("清空") {
                        BuiltinParserLogStore.shared.clear(parserID)
                        lines = []
                    }
                }
            }
            .task {
                lines = BuiltinParserLogStore.shared.lines(for: parserID)
            }
        }
    }
}
