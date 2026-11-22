import DSCore
import DSDesignSystem
import DSStorage
import SwiftUI

/// 关于页面（1:1 复刻 v2.8 圆角 Hero 卡片 + 作者卡 + 免责声明 + 恢复默认设置；严格保留 v3.0 版本号三击解锁）
struct AboutView: View {
    @Environment(\.sizeCategory) private var sizeCategory
    @Environment(AppContainer.self) private var container
    @Environment(AppSettingsStore.self) private var settings
    @Environment(DSBannerCoordinator.self) private var banner
    @ScaledMetric(relativeTo: .title2) private var authorAvatarSize: CGFloat = 44

    @State private var versionTapCount = 0
    @State private var lastVersionTapAt: Date = .distantPast
    @State private var isActivatingParser = false
    @State private var showResetConfirm = false
    @State private var showDisclaimerSheet = false

    var body: some View {
        List {
            Section {
                appHeroCard
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }

            Section("应用作者") {
                authorCard
                    .listRowBackground(DSColors.surfaceCard)

                HStack {
                    Text("架构")
                    Spacer()
                    Text("Swift 6.0 · 6-Package 绿地架构")
                        .font(DSTypography.footnote)
                        .foregroundStyle(DSColors.inkSecondary)
                }
                .listRowBackground(DSColors.surfaceCard)
            }

            Section("信息") {
                Button {
                    showDisclaimerSheet = true
                } label: {
                    HStack {
                        Label("书源免责声明", systemImage: "doc.text")
                            .foregroundStyle(DSColors.inkPrimary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(DSTypography.caption)
                            .foregroundStyle(DSColors.inkSecondary)
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(DSColors.surfaceCard)
            }

            Section {
                Button(role: .destructive) {
                    showResetConfirm = true
                } label: {
                    Label("恢复默认设置", systemImage: "arrow.counterclockwise")
                        .foregroundStyle(DSColors.danger)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(DSColors.surfaceCard)
            } footer: {
                Text("仅恢复偏好设置（播放、下载、外观等），不影响书架、书源、下载记录和每本书的单独设置。")
                    .font(DSTypography.caption)
                    .foregroundStyle(DSColors.inkSecondary)
            }

            Section {
                Text(AuthorInfo.copyrightText)
                    .font(DSTypography.numericFootnote)
                    .foregroundStyle(DSColors.inkSecondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(.compact)
        .scrollContentBackground(.hidden)
        .background(DSColors.surfaceGrouped)
        .navigationTitle("关于 DSNovel")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showDisclaimerSheet) {
            DSSheetScaffold(title: "书源免责声明", banner: banner, onDismiss: { showDisclaimerSheet = false }) {
                ScrollView {
                    VStack(alignment: .leading, spacing: DSSpacing.md) {
                        Text("内容均由用户启用或导入的书源实时解析提供。")
                            .font(DSTypography.body.weight(.medium))
                            .foregroundStyle(DSColors.inkPrimary)
                        Text("DSNovel 是一款插件化有声书聚合播放器，应用本身不存储、不托管也不分发任何音频或文字作品。所有音频流、章节目录与元数据均由用户自行启用或导入的书源脚本在本地实时解析获取。")
                            .font(DSTypography.body)
                            .foregroundStyle(DSColors.inkSecondary)
                        Text("请遵守所在地区的法律法规与内容版权规范，仅在合法授权范围内使用书源功能。")
                            .font(DSTypography.body)
                            .foregroundStyle(DSColors.inkSecondary)
                    }
                    .padding(DSSpacing.pageHorizontal)
                    .padding(.vertical, DSSpacing.md)
                }
                .background(DSColors.surfaceGrouped)
            }
            .presentationDetents([.medium])
        }
        .alert("恢复默认设置", isPresented: $showResetConfirm) {
            Button("取消", role: .cancel) {}
            Button("恢复默认设置", role: .destructive) {
                resetPreferencesToDefault()
            }
        } message: {
            Text("仅恢复偏好设置（播放、下载、外观等），不影响书架、书源、下载记录和每本书的单独设置。")
        }
    }

    private var appHeroCard: some View {
        VStack(spacing: DSSpacing.sm) {
            Image("AppIconPreview")
                .resizable()
                .scaledToFill()
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: DSRadius.card, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: DSRadius.card, style: .continuous)
                        .strokeBorder(DSColors.separator.opacity(0.25), lineWidth: 0.5)
                )
                .shadow(color: Color.black.opacity(0.12), radius: 10, y: 4)
                .accessibilityHidden(true)

            VStack(spacing: 4) {
                Text("DSNovel")
                    .font(DSTypography.bookTitleMedium)
                    .foregroundStyle(DSColors.inkPrimary)
                Text("插件化有声书聚合播放器")
                    .font(DSTypography.caption)
                    .foregroundStyle(DSColors.inkSecondary)
            }

            Button {
                handleVersionTap()
            } label: {
                Text(AuthorInfo.appVersionDisplay)
                    .font(DSTypography.numericCaption.weight(.medium))
                    .foregroundStyle(DSColors.accent)
                    .padding(.horizontal, DSSpacing.sm)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(DSColors.accent.opacity(0.12)))
                    .frame(minWidth: 120, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .simultaneousGesture(TapGesture(count: 3).onEnded { activateBuiltinParserFromVersionTap() })
            .accessibilityIdentifier("about_version_label")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DSSpacing.s5)
        .padding(.horizontal, DSSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: DSRadius.heroCard, style: .continuous)
                .fill(DSColors.surfaceCard)
        )
    }

    @ViewBuilder
    private var authorCard: some View {
        if sizeCategory.isAccessibilityCategory {
            VStack(alignment: .leading, spacing: DSSpacing.xs) {
                authorAvatar
                authorLabels
            }
            .padding(.vertical, DSSpacing.xxs)
            .accessibilityElement(children: .combine)
        } else {
            HStack(spacing: DSSpacing.sm) {
                authorAvatar
                authorLabels
                Spacer()
            }
            .padding(.vertical, DSSpacing.xxs)
            .accessibilityElement(children: .combine)
        }
    }

    private var authorAvatar: some View {
        Text(AuthorInfo.name)
            .font(DSTypography.cardTitle)
            .foregroundStyle(DSColors.onAccent)
            .frame(width: authorAvatarSize, height: authorAvatarSize)
            .background(Circle().fill(DSColors.accent))
            .accessibilityHidden(true)
    }

    private var authorLabels: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(AuthorInfo.name)
                .font(DSTypography.rowTitle)
                .foregroundStyle(DSColors.inkPrimary)
            Text(AuthorInfo.role)
                .font(DSTypography.caption)
                .foregroundStyle(DSColors.inkSecondary)
        }
    }

    private func handleVersionTap() {
        guard !isActivatingParser else { return }
        let now = Date()
        if now.timeIntervalSince(lastVersionTapAt) > 1.2 {
            versionTapCount = 1
        } else {
            versionTapCount += 1
        }
        lastVersionTapAt = now
        guard versionTapCount >= 3 else { return }
        activateBuiltinParserFromVersionTap()
    }

    private func activateBuiltinParserFromVersionTap() {
        guard !isActivatingParser else { return }
        versionTapCount = 0
        isActivatingParser = true
        Task {
            defer { isActivatingParser = false }
            do {
                let outcome = try await BundledParserLoader.activateBundledXimalayaParser(engine: container.builtinParser)
                settings.builtinParserUnlocked = true
                await container.refreshBuiltinParserActiveState()
                banner.show(outcome.bannerMessage, tone: .success)
            } catch {
                banner.show("加载内置解析器失败：\(error.localizedDescription)", tone: .error)
            }
        }
    }

    private func resetPreferencesToDefault() {
        settings.themeMode = .system
        settings.nightDimEnabled = false
        settings.shelfLayout = .grid
        settings.preferredQuality = .auto
        settings.playbackRate = 1.0
        settings.wifiOnlyDownload = false
        settings.maxConcurrentDownloads = 3
        settings.precacheNextCount = 2
        settings.autoPlayNextChapter = true
        container.syncSettingsToEngines()
        DSHaptics.selection()
        banner.show("已恢复默认偏好设置", tone: .success)
    }
}
