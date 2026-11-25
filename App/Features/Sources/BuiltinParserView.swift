import DSCore
import DSDesignSystem
import DSPluginKit
import SwiftUI
import UniformTypeIdentifiers

/// 音频解析管理页（仅由喜马拉雅书源详情页进入：状态概览 / 解析器启停与自检 / 播放与脚本诊断日志）
struct BuiltinParserView: View {
    @Environment(AppContainer.self) var container
    @Environment(DSBannerCoordinator.self) var banner

    @State var parsers: [BuiltinParserMetaDTO] = []
    struct ParserLogItem: Identifiable, Equatable {
        let id: String
        let text: String
    }

    @State var logItems: [ParserLogItem] = []
    @State var showClearLogsConfirm = false
    @State var checkResults: [String: BuiltinParserStatusDTO] = [:]
    @State var checkingParserID: String?
    @State var showInstallSheet = false
    @State var showFileImporter = false
    @State var installScriptText = ""
    @State var pendingRemoveTarget: BuiltinParserMetaDTO?

    var activeParser: BuiltinParserMetaDTO? {
        parsers.first(where: \.isEnabled)
    }

    var body: some View {
        List {
            Section {
                statusOverviewCard
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }

            Section {
                if parsers.isEmpty {
                    VStack(alignment: .leading, spacing: DSSpacing.xs) {
                        Text("尚未安装音频解析脚本")
                            .font(DSTypography.rowTitle)
                            .foregroundStyle(DSColors.inkPrimary)
                        Text("点击右上角 + 可从本地导入或粘贴解析脚本，系统会自动复用喜马拉雅账号登录态。")
                            .font(DSTypography.footnote)
                            .foregroundStyle(DSColors.inkSecondary)
                    }
                    .padding(.vertical, DSSpacing.xs)
                    .listRowBackground(DSColors.surfaceCard)
                } else {
                    ForEach(parsers) { parser in
                        parserCardRow(parser)
                            .listRowBackground(DSColors.surfaceCard)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button("移除", role: .destructive) {
                                    pendingRemoveTarget = parser
                                }
                            }
                    }
                }
            } header: {
                Text(parsers.isEmpty ? "解析脚本" : "已安装解析脚本（\(parsers.count)）")
            } footer: {
                if !parsers.isEmpty {
                    Text("左滑条目可移除脚本；登录态自动复用喜马拉雅书源账号，无需手工填写。")
                        .font(DSTypography.caption)
                        .foregroundStyle(DSColors.inkSecondary)
                }
            }

            Section {
                if logItems.isEmpty {
                    Text("暂无记录。播放或下载喜马拉雅音频、或运行自检后，解析决策与结果会自动记录在这里。")
                        .font(DSTypography.footnote)
                        .foregroundStyle(DSColors.inkSecondary)
                        .padding(.vertical, DSSpacing.xs)
                        .listRowBackground(DSColors.surfaceCard)
                } else {
                    ForEach(logItems) { item in
                        logRow(item.text)
                            .listRowBackground(DSColors.surfaceCard)
                    }
                }
            } header: {
                logSectionHeader
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(.compact)
        .scrollContentBackground(.hidden)
        .background(DSColors.surfaceGrouped)
        .navigationTitle("音频解析")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showInstallSheet = true
                } label: {
                    Image(systemName: "plus")
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("导入音频解析脚本")
            }
        }
        .sheet(isPresented: $showInstallSheet) {
            installSheetContent
                .fileImporter(
                    isPresented: $showFileImporter,
                    allowedContentTypes: [.javaScript, .plainText],
                    allowsMultipleSelection: false
                ) { result in
                    handleImportedScriptFile(result)
                }
        }
        .alert("确认移除解析脚本？", isPresented: Binding(
            get: { pendingRemoveTarget != nil },
            set: { if !$0 { pendingRemoveTarget = nil } }
        )) {
            Button("取消", role: .cancel) { pendingRemoveTarget = nil }
            Button("移除", role: .destructive) {
                if let target = pendingRemoveTarget {
                    pendingRemoveTarget = nil
                    Task { await removeParser(target.id) }
                }
            }
        } message: {
            Text("移除后将不再使用「\(pendingRemoveTarget?.name ?? "")」进行音频解析，可在关于页重新激活内置脚本。")
        }
        .alert("确认清空诊断日志？", isPresented: $showClearLogsConfirm) {
            Button("取消", role: .cancel) {}
            Button("清空", role: .destructive) {
                Task { await clearLogs() }
            }
        } message: {
            Text("清空后将移除当前显示的解析与脚本诊断记录，后续播放或自检会自动记录新日志。")
        }
        .onAppear { Task { await refreshLogsOnly(haptic: false) } }
        .task { await reload() }
    }
}
