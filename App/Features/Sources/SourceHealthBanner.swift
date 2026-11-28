import DSCore
import DSDesignSystem
import SwiftUI

/// 书源管理一键检测进度与汇总条（独立拆分严守 384 行门禁）
struct SourceHealthBanner: View {
    let isRunning: Bool
    let completedCount: Int
    let totalCount: Int
    let currentSourceName: String
    let availableCount: Int
    let invalidCount: Int
    let enabledInvalidCount: Int
    let onCancel: () -> Void
    let onDisableInvalid: () -> Void

    var body: some View {
        HStack(spacing: DSSpacing.sm) {
            if isRunning {
                ProgressView()
                    .controlSize(.small)
                Text("正在检测 \(completedCount)/\(totalCount)\(currentSourceName.isEmpty ? "" : " · \(currentSourceName)")")
                    .font(DSTypography.caption.monospacedDigit())
                    .foregroundStyle(DSColors.inkPrimary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Button("取消", action: onCancel)
                    .font(DSTypography.caption.weight(.semibold))
                    .foregroundStyle(DSColors.inkSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(DSColors.surfaceGrouped))
                    .buttonStyle(.plain)
            } else {
                Image(systemName: invalidCount > 0 ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                    .font(DSTypography.caption)
                    .foregroundStyle(invalidCount > 0 ? DSColors.danger : DSColors.success)
                Text("检测完成：\(availableCount) 可用 · \(invalidCount) 已失效")
                    .font(DSTypography.caption.weight(.medium).monospacedDigit())
                    .foregroundStyle(DSColors.inkPrimary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if enabledInvalidCount > 0 {
                    Button(action: onDisableInvalid) {
                        Text("停用失效")
                            .font(DSTypography.caption.weight(.semibold))
                            .foregroundStyle(DSColors.onAccent)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(DSColors.accent))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, DSSpacing.sm)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: DSRadius.card, style: .continuous)
                .fill(DSColors.surfaceCard)
                .overlay(
                    RoundedRectangle(cornerRadius: DSRadius.card, style: .continuous)
                        .strokeBorder(DSColors.separator.opacity(0.26), lineWidth: 0.5)
                )
        )
        .padding(.horizontal, DSSpacing.pageHorizontal)
        .padding(.bottom, DSSpacing.xs)
    }
}

/// 书源行内第二行健康状态微标
struct SourceHealthBadge: View {
    let text: String
    let state: SourceHealthState

    private var fgColor: Color {
        switch state {
        case .available: return DSColors.success
        case .invalid: return DSColors.danger
        case .needsLogin: return DSColors.warning
        case .checking, .unknown: return DSColors.inkSecondary
        }
    }

    private var bgColor: Color {
        switch state {
        case .available: return DSColors.success.opacity(0.14)
        case .invalid: return DSColors.danger.opacity(0.14)
        case .needsLogin: return DSColors.warning.opacity(0.15)
        case .checking, .unknown: return DSColors.surfaceGrouped
        }
    }

    var body: some View {
        Text(text)
            .font(DSTypography.caption2.weight(.semibold).monospacedDigit())
            .foregroundStyle(fgColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(bgColor))
            .layoutPriority(1)
    }
}

extension SourceListView {
    @ViewBuilder
    var healthStatusBanner: some View {
        if healthEngine.isRunning || healthEngine.hasCompletedBatch {
            SourceHealthBanner(
                isRunning: healthEngine.isRunning,
                completedCount: healthEngine.completedCount,
                totalCount: healthEngine.totalCount,
                currentSourceName: healthEngine.currentSourceName,
                availableCount: healthEngine.availableCount(in: sources),
                invalidCount: healthEngine.invalidCount(in: sources),
                enabledInvalidCount: healthEngine.enabledInvalidSources(in: sources).count,
                onCancel: { healthEngine.cancel() },
                onDisableInvalid: { disableAllInvalidSources() }
            )
        }
    }

    func runBatchHealthCheck() {
        let runtime = container.pluginRuntime
        let loggedIn = container.sourceAuth.loggedInSourceIDs
        let targetSources = sources
        healthEngine.startBatchCheck(sources: targetSources, loggedInSourceIDs: loggedIn) { meta in
            await SourceHealthCheckEngine.probeSource(meta: meta, runtime: runtime)
        }
    }

    func checkSingleSource(_ src: SourceMetaDTO) async {
        let runtime = container.pluginRuntime
        let loggedIn = container.sourceAuth.loggedInSourceIDs
        let rec = await healthEngine.checkSingle(source: src, loggedInSourceIDs: loggedIn) { meta in
            await SourceHealthCheckEngine.probeSource(meta: meta, runtime: runtime)
        }
        if rec.state == .available {
            banner.show("《\(src.name)》检测可用", tone: .success)
        } else if rec.state == .invalid {
            banner.show("《\(src.name)》已失效（\(rec.reason ?? "不可用")）", tone: .warning)
        }
    }

    func disableAllInvalidSources() {
        let targets = healthEngine.enabledInvalidSources(in: sources)
        guard !targets.isEmpty else { return }
        DSHaptics.selection()
        for src in targets {
            enqueueSourceUpdate(src.id, isEnabled: false, isPinned: nil, groupName: nil)
        }
        banner.show("已停用 \(targets.count) 个失效书源", tone: .info)
    }
}
