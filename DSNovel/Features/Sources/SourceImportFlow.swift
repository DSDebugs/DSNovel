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

    private static var importContentTypes: [UTType] {
        var types: [UTType] = [.data, .zip, .json]
        if let js = UTType(filenameExtension: "js") { types.append(js) }
        return types
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
            }

            Section("从网络链接导入") {
                TextField("https://example.com/sources.zip", text: $remoteURLString)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
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
        guard let url = URL(string: remoteURLString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            errorMessage = "链接格式无效"
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
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
            let metas = try await PluginRuntime.shared.installPackage(preview)
            for (idx, meta) in metas.enumerated() {
                let record = PluginRecord(
                    id: meta.id,
                    packageID: preview.packageID,
                    name: meta.name,
                    version: preview.version,
                    author: preview.author,
                    siteURL: meta.url,
                    summary: meta.summary,
                    order: SourceStore.shared.allSources.count + idx,
                    isEnabled: meta.enabledByDefault,
                    searchable: meta.searchable,
                    discoverable: meta.discoverable,
                    requiresLogin: !meta.loginURL.isEmpty,
                    loginURL: meta.loginURL
                )
                modelContext.insert(record)
            }
            try? modelContext.save()
            SourceStore.shared.refreshNow()
            DSHapticPolicy.fire(.success)
            step = .completed(installedCount: metas.count)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
