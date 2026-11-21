import DSDesignSystem
import DSStorage
import SwiftUI

/// 首次启动纯竖屏引导页（展示核心能力与本地隐私承诺，一键进入主界面；支持大字体滚动与底部安全区固定按钮）
struct OnboardingView: View {
    @Environment(AppSettingsStore.self) private var settings

    var body: some View {
        ScrollView {
            VStack(spacing: DSSpacing.lg) {
                Image("AppIconPreview")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 88, height: 88)
                    .clipShape(RoundedRectangle(cornerRadius: DSRadius.lg, style: .continuous))
                    .shadow(color: DSColors.accent.opacity(0.35), radius: 16, y: 8)
                    .padding(.top, DSSpacing.xl)

                VStack(spacing: DSSpacing.xs) {
                    Text("欢迎使用 DSNovel v3")
                        .font(DSTypography.largeTitle)
                        .foregroundStyle(DSColors.inkPrimary)
                        .multilineTextAlignment(.center)
                    Text("专为 iPhone 竖屏打造的纯净有声书播放器")
                        .font(DSTypography.subheadline)
                        .foregroundStyle(DSColors.inkSecondary)
                        .multilineTextAlignment(.center)
                }

                VStack(alignment: .leading, spacing: DSSpacing.md) {
                    featureRow(icon: "waveform", title: "实时 5 段均衡器与单本跳过", subtitle: "自动识别 HLS 流并支持单本独立片头片尾跳过")
                    featureRow(icon: "arrow.down.circle", title: "后台双池离线下载", subtitle: "手动下载优先于预缓存，断网也可随时续听")
                    featureRow(icon: "lock.shield", title: "插件沙箱与本地隐私", subtitle: "所有进度与书源数据均保留在本机，强制拦截内网 SSRF")
                }
                .padding(DSSpacing.md)
                .background(DSColors.surfaceCard, in: RoundedRectangle(cornerRadius: DSRadius.lg, style: .continuous))
            }
            .padding(DSSpacing.lg)
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                settings.onboardingCompleted = true
            } label: {
                Text("开始听书")
                    .font(DSTypography.headline)
                    .frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("onboarding_start_button")
            .padding(.horizontal, DSSpacing.lg)
            .padding(.vertical, DSSpacing.md)
            .background(DSColors.surfaceBase)
        }
        .background(DSColors.surfaceBase.ignoresSafeArea())
    }

    private func featureRow(icon: String, title: String, subtitle: String) -> some View {
        HStack(alignment: .top, spacing: DSSpacing.sm) {
            Image(systemName: icon)
                .font(DSTypography.title)
                .foregroundStyle(DSColors.accent)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(DSTypography.headline)
                    .foregroundStyle(DSColors.inkPrimary)
                Text(subtitle)
                    .font(DSTypography.footnote)
                    .foregroundStyle(DSColors.inkSecondary)
            }
        }
    }
}
