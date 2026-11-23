import DSCore
import DSDesignSystem
import DSPluginKit
import SwiftUI

extension SourceListView {
    var importSheetContent: some View {
        DSSheetScaffold(title: "导入第三方书源（ES5 JS）", banner: banner, onDismiss: { showImportSheet = false }) {
            VStack(spacing: DSSpacing.md) {
                Button {
                    showFileImporter = true
                } label: {
                    Label("从文件导入 .zip 书源包或 .js 脚本", systemImage: "folder")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .disabled(isImporting)

                TextEditor(text: $importScriptText)
                    .font(DSTypography.footnote)
                    .padding(DSSpacing.xs)
                    .background(DSColors.surfaceCard, in: RoundedRectangle(cornerRadius: DSRadius.md))

                Button {
                    Task { await previewAndImport() }
                } label: {
                    if isImporting {
                        ProgressView().frame(maxWidth: .infinity, minHeight: 44)
                    } else {
                        Text("安全预览并导入").frame(maxWidth: .infinity, minHeight: 44)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isImporting || importScriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(DSSpacing.md)
        }
    }

    func previewAndImport() async {
        guard !isImporting else { return }
        isImporting = true
        defer { isImporting = false }
        do {
            let preview = try await container.pluginRuntime.previewSources(scriptBody: importScriptText)
            guard !preview.sources.isEmpty else {
                banner.show("脚本未注册有效书源", tone: .warning)
                return
            }
            if preview.requiresCompatConfirmation {
                queuedCompatPreview = preview
                showImportSheet = false
            } else {
                showImportSheet = false
                await commitImport(preview)
            }
        } catch {
            banner.show("预览校验失败：\(error.localizedDescription)", tone: .error)
        }
    }

    func commitImport(_ preview: SourcePreviewResult) async {
        do {
            for meta in preview.sources {
                try await container.persistence.upsertSource(meta: meta, scriptBody: preview.scriptBody, isBundled: false)
            }
            if let all = try? await container.persistence.fetchAllSources() {
                await container.pluginRuntime.registerSources(all)
            }
            container.notifySourcesChanged()
            importScriptText = ""
            await reload()
            banner.show("已导入 \(preview.sources.count) 个书源", tone: .success)
        } catch {
            banner.show("导入失败：\(error.localizedDescription)", tone: .error)
        }
    }

    func resetBundledSources() async {
        guard !isSeedingSources else { return }
        isSeedingSources = true
        defer { isSeedingSources = false }
        await BundledSourceSeeder.seedIfNeeded(
            persistence: container.persistence,
            pluginRuntime: container.pluginRuntime,
            settings: container.settings,
            logger: container.logger,
            force: true
        )
        if let all = try? await container.persistence.fetchAllSources() {
            await container.pluginRuntime.registerSources(all)
        }
        container.notifySourcesChanged()
        await reload()
        banner.show("已重新加载随包内置书源", tone: .success)
    }

    func handleImportedFile(_ result: Result<[URL], Error>) async {
        let fileURL: URL
        switch result {
        case .success(let urls):
            guard let first = urls.first else { return }
            fileURL = first
        case .failure(let error):
            banner.show("读取书源文件失败：\(error.localizedDescription)", tone: .error)
            return
        }
        let isZip = fileURL.pathExtension.lowercased() == "zip"
        do {
            let extracted: String? = try await Task.detached(priority: .userInitiated) {
                let accessed = fileURL.startAccessingSecurityScopedResource()
                defer { if accessed { fileURL.stopAccessingSecurityScopedResource() } }
                let data = try Data(contentsOf: fileURL)
                if isZip { return try BundledSourceSeeder.extractOrderedScripts(from: data) }
                return String(data: BundledSourceSeeder.stripUTF8BOM(data), encoding: .utf8)
            }.value
            guard let script = extracted else {
                banner.show("文件不是有效的 UTF-8 编码", tone: .error)
                return
            }
            if isZip, script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                banner.show("ZIP 压缩包内未找到有效 JS 书源脚本", tone: .warning)
                return
            }
            importScriptText = script
            await previewAndImport()
        } catch {
            banner.show("读取书源文件失败：\(error.localizedDescription)", tone: .error)
        }
    }
}
