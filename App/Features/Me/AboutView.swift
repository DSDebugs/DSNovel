import DSCore
import DSDesignSystem
import DSStorage
import SwiftUI

/// 无按压视觉反馈的静默按钮样式（用于极致隐蔽的版本号行）
private struct SilentVersionRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

/// 关于页面（去框化品牌头图 + 双精修卡片 [信息整合卡 / 恢复默认设置卡] + 静默三击版本行触发内置解析）
struct AboutView: View {
    @Environment(AppContainer.self) private var container
    @Environment(AppSettingsStore.self) private var settings
    @Environment(DSBannerCoordinator.self) private var banner

    @State private var versionTapCount = 0
    @State private var lastVersionTapAt: Date = .distantPast
    @State private var lastToggleAt: Date = .distantPast
    @State private var isActivatingParser = false
    @State private var showResetConfirm = false
    @State private var showDisclaimerSheet = false

    private var authorDetailText: String {
        "\(AuthorInfo.name) · \(AuthorInfo.role)"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: DSSpacing.md) {
                brandHeroHeader

                infoCard

                resetSection

                Text(AuthorInfo.copyrightText)
                    .font(DSTypography.numericFootnote)
                    .foregroundStyle(DSColors.inkSecondary.opacity(0.72))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, DSSpacing.sm)
            }
            .padding(.horizontal, DSSpacing.pageHorizontal)
            .padding(.top, DSSpacing.xs)
            .padding(.bottom, DSSpacing.lg)
        }
        .background(DSColors.surfaceBase)
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

    private var brandHeroHeader: some View {
        VStack(spacing: DSSpacing.sm) {
            Image("AppIconPreview")
                .resizable()
                .scaledToFill()
                .frame(width: 72, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: DSRadius.card, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: DSRadius.card, style: .continuous)
                        .strokeBorder(DSColors.separator.opacity(0.25), lineWidth: 0.5)
                )
                .shadow(color: DSColors.accent.opacity(0.18), radius: 14, y: 6)
                .accessibilityHidden(true)

            VStack(spacing: 4) {
                Text("DSNovel")
                    .font(DSTypography.bookTitleLarge)
                    .foregroundStyle(DSColors.inkPrimary)
                Text("插件化有声书聚合播放器")
                    .font(DSTypography.caption)
                    .foregroundStyle(DSColors.inkSecondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, DSSpacing.sm)
        .padding(.bottom, DSSpacing.xs)
    }

    private var infoCard: some View {
        cardContainer {
            VStack(spacing: 0) {
                HStack(spacing: DSSpacing.sm) {
                    rowBadgeIcon(
                        "person.fill",
                        tint: DSColors.accent,
                        background: DSColors.accent.opacity(0.14)
                    )
                    Text("应用作者")
                        .font(DSTypography.subheadline)
                        .foregroundStyle(DSColors.inkPrimary)
                    Spacer(minLength: 8)
                    Text(authorDetailText)
                        .font(DSTypography.footnote)
                        .foregroundStyle(DSColors.inkSecondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, DSSpacing.s5)
                .frame(minHeight: 48)
                .accessibilityElement(children: .combine)

                insetDivider

                Button {
                    DSHaptics.selection()
                    showDisclaimerSheet = true
                } label: {
                    HStack(spacing: DSSpacing.sm) {
                        rowBadgeIcon(
                            "doc.text.fill",
                            tint: DSColors.inkSecondary,
                            background: DSColors.inkSecondary.opacity(0.12)
                        )
                        Text("书源免责声明")
                            .font(DSTypography.subheadline)
                            .foregroundStyle(DSColors.inkPrimary)
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .font(DSTypography.caption2.weight(.semibold))
                            .foregroundStyle(DSColors.inkSecondary.opacity(0.70))
                    }
                    .padding(.horizontal, DSSpacing.s5)
                    .frame(minHeight: 48)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                insetDivider

                Button {
                    handleVersionTap()
                } label: {
                    HStack(spacing: DSSpacing.sm) {
                        rowBadgeIcon(
                            "tag.fill",
                            tint: DSColors.inkSecondary,
                            background: DSColors.inkSecondary.opacity(0.12)
                        )
                        HStack(spacing: DSSpacing.xs) {
                            Text("版本号")
                                .font(DSTypography.subheadline)
                                .foregroundStyle(DSColors.inkPrimary)
                            Text(AuthorInfo.appVersionDisplay)
                                .font(DSTypography.numericFootnote)
                                .foregroundStyle(DSColors.inkSecondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                    }
                    .padding(.horizontal, DSSpacing.s5)
                    .frame(minHeight: 48)
                    .contentShape(Rectangle())
                }
                .buttonStyle(SilentVersionRowButtonStyle())
                .simultaneousGesture(TapGesture(count: 3).onEnded { activateBuiltinParserFromVersionTap() })
                .accessibilityIdentifier("about_version_label")
            }
        }
    }

    private var resetSection: some View {
        VStack(spacing: DSSpacing.xs) {
            cardContainer {
                Button(role: .destructive) {
                    DSHaptics.selection()
                    showResetConfirm = true
                } label: {
                    HStack(spacing: DSSpacing.sm) {
                        rowBadgeIcon(
                            "arrow.counterclockwise",
                            tint: DSColors.danger,
                            background: DSColors.danger.opacity(0.12)
                        )
                        Text("恢复默认设置")
                            .font(DSTypography.subheadline)
                            .foregroundStyle(DSColors.danger)
                        Spacer(minLength: 8)
                    }
                    .padding(.horizontal, DSSpacing.s5)
                    .frame(minHeight: 48)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Text("仅恢复偏好设置，不影响书架、书源、下载记录和单书设置。")
                .font(DSTypography.caption)
                .foregroundStyle(DSColors.inkSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, DSSpacing.sm)
        }
    }

    private func cardContainer<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .background(
                RoundedRectangle(cornerRadius: DSRadius.card, style: .continuous)
                    .fill(DSColors.surfaceCard)
                    .overlay(
                        RoundedRectangle(cornerRadius: DSRadius.card, style: .continuous)
                            .strokeBorder(DSColors.separator.opacity(0.28), lineWidth: 0.5)
                    )
                    .shadow(color: Color.black.opacity(0.035), radius: 8, y: 2)
            )
    }

    private var insetDivider: some View {
        Divider()
            .overlay(DSColors.separator.opacity(0.28))
            .padding(.leading, 60)
    }

    private func rowBadgeIcon(_ systemName: String, tint: Color, background: Color) -> some View {
        Image(systemName: systemName)
            .font(DSTypography.caption.weight(.semibold))
            .foregroundStyle(tint)
            .frame(width: 28, height: 28)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(background)
            )
            .accessibilityHidden(true)
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
        let now = Date()
        guard !isActivatingParser, now.timeIntervalSince(lastToggleAt) > 0.8 else { return }
        lastToggleAt = now
        versionTapCount = 0

        if settings.builtinParserUnlocked {
            settings.builtinParserUnlocked = false
            DSHaptics.selection()
            banner.show("已隐藏音频解析入口（内置脚本保持运行）", tone: .info)
            return
        }

        isActivatingParser = true
        Task {
            defer { isActivatingParser = false }
            do {
                let outcome = try await BundledParserLoader.activateBundledXimalayaParser(engine: container.builtinParser)
                settings.builtinParserUnlocked = true
                await container.refreshBuiltinParserActiveState()
                DSHaptics.selection()
                banner.show(outcome.bannerMessage, tone: .success)
            } catch {
                banner.show("启用音频解析失败：\(error.localizedDescription)", tone: .error)
            }
        }
    }

    private func resetPreferencesToDefault() {
        settings.themeMode = .system
        settings.nightDimEnabled = false
        settings.shelfLayout = .grid
        settings.preferredQuality = .auto
        settings.clearBookQualities()
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
