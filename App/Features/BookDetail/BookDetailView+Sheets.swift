import DSCore
import DSDesignSystem
import DSDownloads
import DSStorage
import SwiftUI

/// 范围批量下载弹窗（从 BookDetailView.swift 拆分以保持单文件 ≤ 385 行）
struct RangeDownloadSheet: View {
    @Environment(AppSettingsStore.self) private var settings
    @Environment(DownloadCoordinator.self) private var downloads
    @Environment(DSBannerCoordinator.self) private var banner

    private let book: BookSummaryDTO
    private let chapters: [ChapterDTO]
    private let onDismiss: () -> Void

    @State private var startIndex: Int = 0
    @State private var endIndex: Int = 0
    @State private var isEnqueuing = false

    init(book: BookSummaryDTO, chapters: [ChapterDTO], onDismiss: @escaping () -> Void) {
        self.book = book
        self.chapters = chapters
        self.onDismiss = onDismiss
        _endIndex = State(initialValue: min(max(0, chapters.count - 1), 19))
    }

    var body: some View {
        DSSheetScaffold(title: "批量下载章节", banner: banner, onDismiss: onDismiss) {
            Form {
                if chapters.isEmpty {
                    Section {
                        Text("暂无可下载章节，请先返回刷新目录。")
                            .font(DSTypography.footnote)
                            .foregroundStyle(DSColors.inkSecondary)
                    }
                }
                Section("快捷范围") {
                    HStack(spacing: DSSpacing.xs) {
                        presetRangeButton("后 20 章", count: 20)
                        presetRangeButton("后 50 章", count: 50)
                        presetRangeButton("后 100 章", count: 100)
                        presetRangeButton("全部", count: chapters.count, resetStart: true)
                    }
                }
                Section("精确微调（共 \(chapters.count) 章）") {
                    Stepper("起始：第 \(startIndex + 1) 章", value: $startIndex, in: 0...max(0, chapters.count - 1))
                        .disabled(chapters.isEmpty || isEnqueuing)
                    Stepper("结束：第 \(endIndex + 1) 章", value: $endIndex, in: startIndex...max(startIndex, chapters.count - 1))
                        .disabled(chapters.isEmpty || isEnqueuing)
                }
                Section {
                    let selectedCount = chapters.isEmpty ? 0 : max(0, min(endIndex, chapters.count - 1) - startIndex + 1)
                    Button(isEnqueuing ? "正在加入队列..." : "加入下载队列（共 \(selectedCount) 章）") {
                        guard !isEnqueuing,
                              !chapters.isEmpty,
                              startIndex >= 0,
                              startIndex <= endIndex,
                              endIndex < chapters.count else { return }
                        isEnqueuing = true
                        let slice = Array(chapters[startIndex...endIndex])
                        Task {
                            defer { isEnqueuing = false }
                            await downloads.enqueueManual(book: book, chapters: slice, quality: settings.preferredQuality)
                            banner.show("已添加 \(slice.count) 章至下载队列", tone: .success)
                            onDismiss()
                        }
                    }
                    .disabled(chapters.isEmpty || isEnqueuing)
                    .frame(maxWidth: .infinity, minHeight: 44)
                }
            }
            .scrollContentBackground(.hidden)
            .onChange(of: startIndex) { _, next in
                if endIndex < next { endIndex = next }
            }
        }
    }

    private func presetRangeButton(_ title: String, count: Int, resetStart: Bool = false) -> some View {
        let maxIdx = max(0, chapters.count - 1)
        let targetEnd = resetStart ? maxIdx : min(maxIdx, startIndex + max(0, count - 1))
        let isSelected: Bool
        if chapters.isEmpty {
            isSelected = false
        } else if resetStart {
            isSelected = (startIndex == 0 && endIndex == maxIdx)
        } else if chapters.count <= 20 {
            isSelected = false
        } else {
            isSelected = (endIndex == targetEnd)
        }
        return Button(title) {
            guard !chapters.isEmpty else { return }
            if resetStart { startIndex = 0 }
            endIndex = targetEnd
        }
        .font(DSTypography.caption)
        .buttonStyle(.bordered)
        .tint(isSelected ? DSColors.accent : DSColors.inkSecondary)
        .disabled(chapters.isEmpty || isEnqueuing)
        .frame(maxWidth: .infinity, minHeight: 36)
    }
}
