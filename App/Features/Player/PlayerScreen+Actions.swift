import DSCore
import DSDesignSystem
import DSDownloads
import DSPlayback
import SwiftUI

extension PlayerScreen {
    var emptyBookState: some View {
        VStack(spacing: DSSpacing.md) {
            Image(systemName: "headphones.circle")
                .font(DSTypography.largeTitle)
                .foregroundStyle(.white.opacity(0.72))
            Text("还没有正在收听的书籍")
                .font(DSTypography.headline)
                .foregroundStyle(.white)
            Button("前往书架选书") {
                dismiss()
                router.selectTab(.library)
            }
            .buttonStyle(.borderedProminent)
            .frame(minHeight: 44)
        }
        .padding(DSSpacing.lg)
    }

    func failedInlineBanner(message: String) -> some View {
        HStack(spacing: DSSpacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(DSColors.danger)
            Text(message)
                .font(DSTypography.caption)
                .foregroundStyle(.white)
                .lineLimit(2)
            Spacer(minLength: 4)
            Button("重试") {
                playback.retryCurrentChapter()
            }
            .font(DSTypography.caption.weight(.semibold))
            .buttonStyle(.borderedProminent)
            .tint(DSColors.accent)
            .frame(minHeight: 36)
        }
        .padding(.horizontal, DSSpacing.sm)
        .padding(.vertical, DSSpacing.xs)
        .background(RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous).fill(Color.black.opacity(0.55)))
        .overlay(RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous).strokeBorder(DSColors.danger.opacity(0.45), lineWidth: 0.6))
    }

    @ViewBuilder
    func sheetContent(_ route: PlayerSheetRoute) -> some View {
        switch route {
        case .chapters:
            ChapterListSheet(
                onOpenBatchDownload: { switchToSheetAfterDismiss(.download) },
                onDismiss: { activeSheet = nil }
            )
        case .sleep:
            SleepTimerSheet { activeSheet = nil }
        case .speed:
            SpeedSheet { activeSheet = nil }
        case .skip:
            SkipSheet { activeSheet = nil }
        case .effects:
            AudioEffectsSheet { activeSheet = nil }
        case .quality:
            AudioQualitySheet { activeSheet = nil }
        case .download:
            PlayerDownloadSheet(
                onOpenGlobalDownloads: {
                    dismiss()
                    router.push(.downloads)
                },
                onDismiss: { activeSheet = nil }
            )
        case .more:
            MoreSheet(
                supportsQualitySelection: supportsQualitySelection,
                onOpenAudioEffects: { switchToSheetAfterDismiss(.effects) },
                onOpenQuality: { switchToSheetAfterDismiss(.quality) },
                onOpenDownloads: { switchToSheetAfterDismiss(.download) },
                onOpenSkip: { switchToSheetAfterDismiss(.skip) },
                onOpenBookDetail: {
                    guard let book = playback.currentBook else { return }
                    dismiss()
                    router.push(.bookDetail(book))
                },
                onDismiss: { activeSheet = nil }
            )
        }
    }

    func switchToSheetAfterDismiss(_ next: PlayerSheetRoute) {
        pendingSheet = next
        activeSheet = nil
    }

    func refreshBookContext() async {
        await refreshShelfStatus()
        guard let book = playback.currentBook else {
            sourceName = ""
            ambientColor = DSColors.accent
            return
        }
        if let cached = container.coverPipeline.cachedImageSync(for: book.coverURL) {
            ambientColor = CoverAmbientColor.color(from: cached, cacheKey: book.id)
        }
        if let all = try? await container.persistence.fetchAllSources(),
           let matched = all.first(where: { $0.meta.id == book.sourceID }) {
            sourceName = matched.meta.name
        } else {
            sourceName = ""
        }
    }

    func refreshShelfStatus() async {
        guard let bookID = playback.currentBook?.id else {
            isInShelf = false
            return
        }
        if let shelf = try? await container.persistence.fetchShelfBooks() {
            isInShelf = shelf.contains(where: { $0.id == bookID })
        }
    }

    func toggleCurrentBookShelf(_ book: BookSummaryDTO) async {
        let next = !isInShelf
        do {
            try await container.persistence.upsertBook(book, addToShelf: next)
            isInShelf = next
            heartBounceCount &+= 1
            DSHaptics.selection()
            container.notifyLibraryChanged()
            banner.show(next ? "已加入书架" : "已移出书架", tone: .success)
        } catch {
            banner.show("更新书架失败：\(error.localizedDescription)", tone: .error)
        }
    }

    func handleCurrentChapterDownloadTap() {
        guard let book = playback.currentBook, let chapter = playback.currentChapter else { return }
        switch currentChapterDownloadState {
        case .notDownloaded:
            downloadBounceCount &+= 1
            DSHaptics.selection()
            Task {
                await downloads.enqueueManual(book: book, chapters: [chapter], quality: container.resolvedQuality(for: book))
                banner.show("已开始下载当前章节，再次点击可管理离线章节", tone: .success)
            }
        case .downloading, .completed, .failed:
            activeSheet = .download
        }
    }
}
