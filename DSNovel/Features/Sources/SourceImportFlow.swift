import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import UIKit

enum SourceImportStep {
    case chooseOrigin
    case preview(PluginImportPreview)
    case completed(installedCount: Int)
}

struct SourceImportFlow: View {
    @Environment(\.modelContext) private var modelContext
    @State private var step: SourceImportStep = .chooseOrigin
    @State private var remoteURLString: String = ""
    @State private var showFileImporter = false
    @State private var isLoading = false
    @State private var errorMessage: String?
    private let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    static let maxRemoteDownloadBytes = 5 * 1024 * 1024

    private static var importContentTypes: [UTType] {
        var types: [UTType] = [.data, .zip, .json]
        if let js = UTType(filenameExtension: "js") { types.append(js) }
        return types
    }

    /// 10-1：校验远程书源导入链接（仅允许 https 协议且具备有效主机名）
    static func validateRemoteURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty else {
            return nil
        }
        return url
    }

    /// 10-1：原地覆盖升级已有 PluginRecord（保留用户分组、置顶、顺序、启用态、登录态与自定义配置），对 packageID 做安全清洗并收集旧孤儿包 ID
    @MainActor
    static func upsertPluginRecords(
        metas: [ParsedSourceMeta],
        preview: PluginImportPreview,
        into modelContext: ModelContext
    ) -> (installedCount: Int, orphanPackageIDs: [String]) {
        let safePackageID = PluginRuntime.sanitizePackageID(preview.packageID)
        let existingRecords = (try? modelContext.fetch(FetchDescriptor<PluginRecord>())) ?? []
        var existingByID: [String: PluginRecord] = [:]
        existingByID.reserveCapacity(existingRecords.count)
        for rec in existingRecords {
            existingByID[rec.id] = rec
        }

        var nextOrder = (existingRecords.map(\.order).max() ?? -1) + 1
        var candidateOrphanPackages = Set<String>()

        for meta in metas {
            if let existing = existingByID[meta.id] {
                let oldPackageID = existing.packageID
                if !oldPackageID.isEmpty && oldPackageID != safePackageID {
                    candidateOrphanPackages.insert(oldPackageID)
                }
                // 原地更新元信息，保留 groupID / order / isPinned / isEnabled / loggedIn / settingsJSON
                existing.packageID = safePackageID
                existing.name = meta.name
                existing.version = preview.version
                existing.author = preview.author
                existing.siteURL = meta.url
                existing.summary = meta.summary
                existing.searchable = meta.searchable
                existing.discoverable = meta.discoverable
                existing.requiresLogin = !meta.loginURL.isEmpty
                existing.loginURL = meta.loginURL
            } else {
                let record = PluginRecord(
                    id: meta.id,
                    packageID: safePackageID,
                    name: meta.name,
                    version: preview.version,
                    author: preview.author,
                    siteURL: meta.url,
                    summary: meta.summary,
                    order: nextOrder,
                    isEnabled: meta.enabledByDefault,
                    searchable: meta.searchable,
                    discoverable: meta.discoverable,
                    requiresLogin: !meta.loginURL.isEmpty,
                    loginURL: meta.loginURL
                )
                nextOrder += 1
                modelContext.insert(record)
                existingByID[meta.id] = record
            }
        }

        try? modelContext.save()

        let activePackageIDs = Set(existingByID.values.map(\.packageID))
        let orphans = candidateOrphanPackages.filter { !activePackageIDs.contains($0) }.sorted()
        return (metas.count, orphans)
    }

    var body: some View {
        DSSheetScaffold(title: "导入书源", onClose: onClose) {
            Group {
                switch step {
                case .chooseOrigin:
                    chooseOriginView
                case .preview(let preview):
                    previewView(preview)
                case .completed(let count):
                    completedView(count: count)
                }
            }
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: Self.importContentTypes,
                allowsMultipleSelection: false
            ) { result in
                handleFilePick(result)
            }
            .alert("导入失败", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("知道了", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private var chooseOriginView: some View {
        Form {
            Section("从本地文件导入（支持 .zip / .js）") {
                Button {
                    showFileImporter = true
                } label: {
                    Label("选择书源文件…", systemImage: "folder.badge.plus")
                }
                .disabled(isLoading)
            }

            Section("从网络链接导入") {
                TextField("https://example.com/sources.zip", text: $remoteURLString)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .disabled(isLoading)
                Button("下载并预览") {
                    Task { await loadFromURL() }
                }
                .disabled(remoteURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLoading)
            }

            Section("从剪贴板导入") {
                Button {
                    Task { await loadFromPasteboard() }
                } label: {
                    Label("读取剪贴板脚本或链接", systemImage: "doc.on.clipboard")
                }
                .disabled(isLoading)
            }

            if isLoading {
                Section {
                    HStack(spacing: Spacing.s2) {
                        ProgressView()
                            .controlSize(.small)
                        Text("正在下载并解析…")
                            .font(DSTypography.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func previewView(_ preview: PluginImportPreview) -> some View {
        Form {
            Section("书源包信息") {
                LabeledContent("包名", value: preview.name)
                LabeledContent("版本", value: preview.version)
                LabeledContent("作者", value: preview.author.isEmpty ? "未知" : preview.author)
                LabeledContent("包含书源", value: "\(preview.sources.count) 个")
            }

            Section("该书源包将访问以下网站") {
                DisclosureGroup("访问域名（\(max(preview.domains.count, preview.sources.count)) 项）") {
                    if !preview.domains.isEmpty {
                        ForEach(preview.domains, id: \.self) { domain in
                            Text(domain).font(DSTypography.caption)
                        }
                    } else {
                        ForEach(preview.sources, id: \.id) { meta in
                            LabeledContent(meta.name, value: meta.url)
                        }
                    }
                }
            }

            Section {
                DSActionButton(
                    title: "确认安装 \(preview.sources.count) 个书源",
                    icon: "checkmark.circle.fill",
                    role: isLoading ? .loading : .primary
                ) {
                    Task { await installPreview(preview) }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("返回重选") {
                    step = .chooseOrigin
                }
                .disabled(isLoading)
            }
        }
    }

    private func completedView(count: Int) -> some View {
        VStack(spacing: Spacing.s5) {
            Image(systemName: "checkmark.circle.fill")
                .font(.largeTitle)
                .foregroundStyle(.green)

            Text("已安装 \(count) 个书源")
                .font(DSTypography.sectionHeader)

            HStack(spacing: Spacing.s3) {
                DSActionButton(title: "立即检测", icon: "stethoscope", role: .secondary) {
                    onClose()
                    Task { await SourceStore.shared.checkSources() }
                }

                DSActionButton(title: "去发现", icon: "safari", role: .primary) {
                    onClose()
                    AppRouter.shared.selectedTab = .discover
                }
            }
            .padding(.horizontal, Spacing.pageHorizontal)
        }
        .padding(Spacing.s6)
    }

    private func handleFilePick(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            errorMessage = "无法读取所选文件"
            return
        }
        Task { await analyzeData(data) }
    }

    private func loadFromURL() async {
        let trimmed = remoteURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let rawURL = URL(string: trimmed), let scheme = rawURL.scheme?.lowercased() else {
            errorMessage = "链接格式无效"
            return
        }
        guard scheme == "https", let url = Self.validateRemoteURL(trimmed) else {
            errorMessage = "为保障安全，仅支持 HTTPS 链接导入书源"
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            var request = URLRequest(url: url, timeoutInterval: 20)
            request.httpMethod = "GET"
            let (asyncBytes, response) = try await URLSession.shared.bytes(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                errorMessage = "服务器响应无效"
                return
            }
            guard (200..<300).contains(httpResponse.statusCode) else {
                errorMessage = "下载失败（HTTP \(httpResponse.statusCode)）"
                return
            }
            if httpResponse.expectedContentLength > Int64(Self.maxRemoteDownloadBytes) {
                errorMessage = "书源文件超过 5MB 体积上限，已取消下载"
                return
            }
            var data = Data()
            if httpResponse.expectedContentLength > 0 {
                data.reserveCapacity(min(Int(httpResponse.expectedContentLength), Self.maxRemoteDownloadBytes))
            }
            for try await byte in asyncBytes {
                data.append(byte)
                if data.count > Self.maxRemoteDownloadBytes {
                    errorMessage = "书源文件超过 5MB 体积上限，已取消下载"
                    return
                }
            }
            await analyzeData(data)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadFromPasteboard() async {
        guard let text = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            errorMessage = "剪贴板为空"
            return
        }
        if text.lowercased().hasPrefix("http://") || text.lowercased().hasPrefix("https://") {
            remoteURLString = text
            await loadFromURL()
        } else {
            await analyzeData(Data(text.utf8))
        }
    }

    private func analyzeData(_ data: Data) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let preview = try await PluginRuntime.shared.prepareImportPreview(from: data)
            step = .preview(preview)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func installPreview(_ preview: PluginImportPreview) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let safePackageID = PluginRuntime.sanitizePackageID(preview.packageID)
            var sanitizedPreview = preview
            sanitizedPreview.packageID = safePackageID
            let metas = try await PluginRuntime.shared.installPackage(sanitizedPreview)
            let upsertResult = Self.upsertPluginRecords(metas: metas, preview: sanitizedPreview, into: modelContext)
            if !upsertResult.orphanPackageIDs.isEmpty {
                let allRecords = (try? modelContext.fetch(FetchDescriptor<PluginRecord>())) ?? []
                let activePackageIDs = Set(allRecords.map(\.packageID))
                for oldPkgID in upsertResult.orphanPackageIDs {
                    await PluginRuntime.shared.cleanupOrphanPackageDirectory(
                        oldPackageID: oldPkgID,
                        activePackageIDs: activePackageIDs
                    )
                }
            }
            SourceStore.shared.refreshNow()
            DSHapticPolicy.fire(.success)
            step = .completed(installedCount: upsertResult.installedCount)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
