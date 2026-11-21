import DSDesignSystem
import SwiftUI

/// 搜索页热门推荐词组件
struct HotBooksPanel: View {
    private let keywords: [String]
    private let onPick: (String) -> Void

    init(
        keywords: [String] = ["凡人修仙传", "三体", "雪中悍刀行", "诡秘之主", "盗墓笔记", "明朝那些事儿"],
        onPick: @escaping (String) -> Void
    ) {
        self.keywords = keywords
        self.onPick = onPick
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.xs) {
            Text("热门有声书")
                .font(DSTypography.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: DSSpacing.xs)], spacing: DSSpacing.xs) {
                ForEach(keywords, id: \.self) { kw in
                    Button {
                        onPick(kw)
                    } label: {
                        Text(kw)
                            .font(DSTypography.footnote)
                            .foregroundStyle(DSColors.inkPrimary)
                            .lineLimit(1)
                            .padding(.horizontal, DSSpacing.sm)
                            .frame(maxWidth: .infinity, minHeight: 36)
                            .background(DSColors.surfaceCard, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

/// 搜索跳过/失败书源详情弹窗（支持一键重试）
struct FailedSourcesSheet: View {
    private struct FailedSourceEntry: Identifiable {
        let id: String
        let name: String
    }

    @Environment(DSBannerCoordinator.self) private var banner
    private let failedEntries: [FailedSourceEntry]
    private let onRetryAll: () -> Void
    private let onDismiss: () -> Void

    init(failedSourceNames: [String], onRetryAll: @escaping () -> Void, onDismiss: @escaping () -> Void) {
        self.failedEntries = failedSourceNames.enumerated().map { idx, name in
            FailedSourceEntry(id: "\(idx)-\(name)", name: name)
        }
        self.onRetryAll = onRetryAll
        self.onDismiss = onDismiss
    }

    var body: some View {
        DSSheetScaffold(title: "未响应书源（\(failedEntries.count)）", banner: banner, onDismiss: onDismiss) {
            List {
                Section("本次搜索超时或解析异常的书源") {
                    ForEach(failedEntries, id: \.id) { entry in
                        HStack {
                            DSSourceAvatar(name: entry.name)
                            Text(entry.name)
                                .font(DSTypography.subheadline)
                            Spacer()
                            Text("已自动跳过")
                                .font(DSTypography.caption)
                                .foregroundStyle(DSColors.warning)
                        }
                        .frame(minHeight: 44)
                    }
                }
                Section {
                    Button("重新发起全源搜索") {
                        onRetryAll()
                        onDismiss()
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
        }
    }
}
