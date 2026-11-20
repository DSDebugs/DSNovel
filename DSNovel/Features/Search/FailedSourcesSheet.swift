import SwiftUI

struct FailedSourcesSheet: View {
    let failedSources: [FailedSourceItem]
    private let onLogin: (FailedSourceItem) -> Void
    private let onRetryAll: () -> Void
    private let onSkipSource: (FailedSourceItem) -> Void
    private let onClose: () -> Void

    init(
        failedSources: [FailedSourceItem],
        onLogin: @escaping (FailedSourceItem) -> Void,
        onRetryAll: @escaping () -> Void,
        onSkipSource: @escaping (FailedSourceItem) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.failedSources = failedSources
        self.onLogin = onLogin
        self.onRetryAll = onRetryAll
        self.onSkipSource = onSkipSource
        self.onClose = onClose
    }

    var body: some View {
        DSSheetScaffold(title: "失败书源详情", onClose: onClose) {
            List {
                ForEach(failedSources) { item in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.sourceName)
                                .font(DSTypography.rowTitle)
                            Text(item.reason)
                                .font(DSTypography.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        Spacer()
                        actionButtons(for: item)
                    }
                    .listRowBackground(Color.dsSurfaceCard)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Color.dsSurfaceGrouped)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("全部重试") {
                        onClose()
                        onRetryAll()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func actionButtons(for item: FailedSourceItem) -> some View {
        HStack(spacing: Spacing.s2) {
            switch item.stateKind {
            case .needLogin, .needVerify:
                Button("去登录") {
                    onLogin(item)
                }
                .font(DSTypography.caption.weight(.semibold))
                .foregroundStyle(Color.dsAccent)
            default:
                EmptyView()
            }
            Button("暂时跳过") {
                onSkipSource(item)
            }
            .font(DSTypography.caption)
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
    }
}
