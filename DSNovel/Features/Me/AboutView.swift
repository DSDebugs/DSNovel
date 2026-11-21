import SwiftUI
import UIKit

struct AboutView: View {
    @Environment(\.sizeCategory) private var sizeCategory
    @Environment(\.openURL) private var openURL
    @ScaledMetric(relativeTo: .title2) private var authorAvatarSize: CGFloat = 44

    @Bindable var settings: AppSettingsStore
    @State private var showResetConfirm = false
    @State private var showDisclaimerSheet = false

    init(settings: AppSettingsStore = .shared) {
        self.settings = settings
    }

    var body: some View {
        List {
            Section {
                appHeroCard
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }

            Section("应用作者") {
                authorCard
                    .listRowBackground(Color.dsSurfaceCard)

                if let url = AuthorInfo.homepageURL {
                    Button {
                        openURL(url)
                    } label: {
                        DSSettingsRow(
                            icon: "link",
                            title: "作者主页",
                            valueText: url.host ?? url.absoluteString,
                            style: .navigation
                        )
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("复制链接") {
                            UIPasteboard.general.string = url.absoluteString
                            BannerCenter.shared.show("已复制链接", kind: .info)
                        }
                    }
                    .listRowBackground(Color.dsSurfaceCard)
                }

                if let email = AuthorInfo.email, !email.isEmpty {
                    Button {
                        if let mailURL = URL(string: "mailto:\(email)") {
                            openURL(mailURL)
                        }
                    } label: {
                        DSSettingsRow(
                            icon: "envelope",
                            title: "联系邮箱",
                            valueText: email,
                            style: .navigation
                        )
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("复制邮箱") {
                            UIPasteboard.general.string = email
                            BannerCenter.shared.show("已复制邮箱", kind: .info)
                        }
                    }
                    .listRowBackground(Color.dsSurfaceCard)
                }
            }

            Section("信息") {
                Button {
                    showDisclaimerSheet = true
                } label: {
                    DSSettingsRow(
                        icon: "doc.text",
                        title: "书源免责声明",
                        style: .navigation
                    )
                }
                .buttonStyle(.plain)
                .listRowBackground(Color.dsSurfaceCard)

                // 隐私政策与用户协议预留入口（待提供正式文案或链接后启用）
            }

            Section {
                Button(role: .destructive) {
                    showResetConfirm = true
                } label: {
                    DSSettingsRow(
                        icon: "arrow.counterclockwise",
                        title: "恢复默认设置",
                        style: .destructive
                    )
                }
                .buttonStyle(.plain)
                .listRowBackground(Color.dsSurfaceCard)
            } footer: {
                Text("仅恢复偏好设置（播放、下载、外观等），不影响书架、书源、下载记录和每本书的单独设置。")
                    .font(DSTypography.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Text(AuthorInfo.copyrightText)
                    .font(DSTypography.numericFootnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(.compact)
        .scrollContentBackground(.hidden)
        .background(Color.dsSurfaceGrouped)
        .contentMargins(.top, Spacing.s2, for: .scrollContent)
        .contentMargins(.bottom, Spacing.s4, for: .scrollContent)
        .navigationTitle("关于 DSNovel")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showDisclaimerSheet) {
            DSSheetScaffold(title: "书源免责声明", onClose: { showDisclaimerSheet = false }) {
                ScrollView {
                    VStack(alignment: .leading, spacing: Spacing.s4) {
                        Text("内容均由用户启用或导入的书源实时解析提供。")
                            .font(DSTypography.body.weight(.medium))
                            .foregroundStyle(.primary)
                        Text("DSNovel 是一款插件化有声书聚合播放器，应用本身不存储、不托管也不分发任何音频或文字作品。所有音频流、章节目录与元数据均由用户自行启用或导入的书源脚本在本地实时解析获取。")
                            .font(DSTypography.body)
                            .foregroundStyle(.secondary)
                        Text("请遵守所在地区的法律法规与内容版权规范，仅在合法授权范围内使用书源功能。")
                            .font(DSTypography.body)
                            .foregroundStyle(.secondary)
                    }
                    .padding(Spacing.pageHorizontal)
                    .padding(.vertical, Spacing.s4)
                }
                .background(Color.dsSurfaceGrouped)
            }
            .presentationDetents([.medium])
        }
        .alert("恢复默认设置", isPresented: $showResetConfirm) {
            Button("取消", role: .cancel) {}
            Button("恢复默认设置", role: .destructive) {
                settings.resetAll()
                // 10-2：恢复默认设置后通过现有接口同步刷新播放器与下载器运行时配置
                PlayerEngine.shared.syncGlobalAudioPreferencesFromSettings()
                PlayerEngine.shared.setSpeed(settings.defaultSpeed, persist: false, alsoSetDefault: false)
                let wifiOnly = settings.wifiOnlyDownload
                Task {
                    await DownloadManager.shared.handleWiFiOnlySettingChanged(wifiOnly)
                }
                DSHapticPolicy.fire(.success)
                BannerCenter.shared.show("已恢复默认偏好设置", kind: .success)
            }
        } message: {
            Text("仅恢复偏好设置（播放、下载、外观等），不影响书架、书源、下载记录和每本书的单独设置。")
        }
    }

    private var appHeroCard: some View {
        VStack(spacing: Spacing.s3) {
            Image("AppIconPreview")
                .resizable()
                .scaledToFill()
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                        .strokeBorder(Color.dsSeparator.opacity(0.25), lineWidth: 0.5)
                )
                .shadow(color: Color.black.opacity(0.12), radius: 10, y: 4)
            .accessibilityHidden(true)

            VStack(spacing: 4) {
                Text("DSNovel")
                    .font(DSTypography.bookTitleMedium)
                    .foregroundStyle(.primary)
                Text("插件化有声书聚合播放器")
                    .font(DSTypography.caption)
                    .foregroundStyle(.secondary)
            }

            Text(AuthorInfo.appVersionDisplay)
                .font(DSTypography.numericCaption.weight(.medium))
                .foregroundStyle(Color.dsAccent)
                .padding(.horizontal, Spacing.s3)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.dsAccent.opacity(0.12)))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.s5)
        .padding(.horizontal, Spacing.s4)
        .background(
            RoundedRectangle(cornerRadius: Radius.heroCard, style: .continuous)
                .fill(Color.dsSurfaceCard)
        )
    }

    @ViewBuilder
    private var authorCard: some View {
        if sizeCategory.isAccessibilityCategory {
            VStack(alignment: .leading, spacing: Spacing.s2) {
                authorAvatar
                authorLabels
            }
            .padding(.vertical, Spacing.s1)
            .accessibilityElement(children: .combine)
        } else {
            HStack(spacing: Spacing.s3) {
                authorAvatar
                authorLabels
                Spacer()
            }
            .padding(.vertical, Spacing.s1)
            .accessibilityElement(children: .combine)
        }
    }

    private var authorAvatar: some View {
        Text(AuthorInfo.initials)
            .font(DSTypography.cardTitle)
            .foregroundStyle(Color.dsOnAccent)
            .frame(width: authorAvatarSize, height: authorAvatarSize)
            .background(Circle().fill(Color.dsAccent))
            .accessibilityHidden(true)
    }

    private var authorLabels: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(AuthorInfo.name)
                .font(DSTypography.rowTitle)
                .foregroundStyle(.primary)
            Text(AuthorInfo.role)
                .font(DSTypography.caption)
                .foregroundStyle(.secondary)
        }
    }
}
