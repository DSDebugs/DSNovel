import DSCore
import DSDesignSystem
import SwiftUI

/// 书籍详情交互与数据加载逻辑（拆分自 BookDetailView.swift 以保持单文件 ≤ 385 行）
extension BookDetailView {
    /// 点击章节严格传入 chapters 数组真实下标 `snap.arrayIndex`，严禁用 `chapterIndexByID[chapter.id]`
    func handleChapterSelect(_ snap: ChapterRowSnapshot) {
        guard chapters.indices.contains(snap.arrayIndex) else { return }
        DSHaptics.selection()
        if isPlayingThisBook && playback.currentChapterIndex == snap.arrayIndex {
            playback.togglePlayPause()
        } else {
            playback.play(book: currentBook, chapters: chapters, startIndex: snap.arrayIndex, autoPlay: true)
        }
    }

    func handleChapterDownloadTap(_ snap: ChapterRowSnapshot) {
        switch snap.downloadState {
        case .completed:
            pendingDeleteSnapshot = snap
        case .failed:
            guard !snap.downloadRecordID.isEmpty else { return }
            Task {
                await downloads.resume(id: snap.downloadRecordID)
                banner.show("已重新加入下载队列", tone: .info)
            }
        case .downloading:
            banner.show("该章节已在下载队列中", tone: .info)
        case .notDownloaded:
            Task {
                await downloads.enqueueManual(book: currentBook, chapters: [snap.chapter], quality: container.resolvedQuality(for: currentBook))
                banner.show("已加入下载 1 章", tone: .success)
            }
        }
    }

    func retryFailedForBook(_ overview: BookDownloadOverview) async {
        var retried = 0
        for rec in overview.recordsByChapterID.values where rec.state == .failed {
            await downloads.resume(id: rec.id)
            retried += 1
        }
        if retried > 0 { banner.show("已重试 \(retried) 章失败下载", tone: .info) }
    }

    func startOrResumePlayback() {
        if chapters.isEmpty {
            DSHaptics.selection()
            Task { await loadDetail(forceRemote: true) }
            return
        }
        DSHaptics.lightImpact()
        if isPlayingThisBook {
            playback.togglePlayPause()
            return
        }
        let targetIdx = min(max(0, activeChapterIndex ?? 0), chapters.count - 1)
        playback.play(book: currentBook, chapters: chapters, startIndex: targetIdx, autoPlay: true)
    }

    func enqueueRange(startZeroBased: Int, endZeroBased: Int) {
        guard !chapters.isEmpty else { return }
        let s = min(max(0, startZeroBased), chapters.count - 1)
        let e = min(max(s, endZeroBased), chapters.count - 1)
        let slice = Array(chapters[s...e])
        Task {
            await downloads.enqueueManual(book: currentBook, chapters: slice, quality: container.resolvedQuality(for: currentBook))
            banner.show("已加入下载 \(slice.count) 章", tone: .success)
        }
    }

    func locateCurrentChapter(proxy: ScrollViewProxy) {
        DSHaptics.selection()
        guard !chapters.isEmpty else { return }
        let targetIdx = BookDetailHelper.locateTargetIndex(
            chaptersCount: chapters.count,
            currentPlayingIndex: isPlayingThisBook ? playback.currentChapterIndex : nil,
            resumeChapterIndex: resumeChapterIndex
        )
        let resolvedIdx = targetIdx ?? 0
        let targetSeg = resolvedIdx / 100
        var didSwitch = false
        if !searchKeyword.isEmpty { searchKeyword = ""; showInlineSearch = false; didSwitch = true }
        if isShowingDownloadedOnly { isShowingDownloadedOnly = false; didSwitch = true }
        if segments.indices.contains(targetSeg) && selectedSegmentIndex != targetSeg {
            selectedSegmentIndex = targetSeg
            didSwitch = true
        }
        if targetIdx == nil { banner.show("当前尚无收听进度，已定位至第 1 章", tone: .info) }
        if didSwitch {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(65))
                DSMotion.withResolved(DSMotion.snappy, reduceMotion: reduceMotion) {
                    proxy.scrollTo(resolvedIdx, anchor: .center)
                }
            }
        } else {
            DSMotion.withResolved(DSMotion.snappy, reduceMotion: reduceMotion) {
                proxy.scrollTo(resolvedIdx, anchor: .center)
            }
        }
    }

    func applyDetail(_ newDetail: BookDetailDTO) {
        detail = newDetail
        if !newDetail.summary.intro.isEmpty {
            cleanedIntro = BookDetailHelper.cleanHTML(newDetail.summary.intro)
        }
        segments = BookDetailHelper.buildSegments(totalCount: newDetail.chapters.count, pageSize: 100)
        if !segments.indices.contains(selectedSegmentIndex) { selectedSegmentIndex = 0 }
        if !didApplyInitialPresentation, !newDetail.chapters.isEmpty {
            didApplyInitialPresentation = true
            if let targetIdx = activeChapterIndex, newDetail.chapters.indices.contains(targetIdx) {
                let segIdx = targetIdx / 100
                if segments.indices.contains(segIdx) { selectedSegmentIndex = segIdx }
            }
        }
    }

    func refreshShelfStatus() async {
        if let shelfBooks = try? await container.persistence.fetchShelfBooks() {
            inShelf = shelfBooks.contains(where: { $0.id == initialBook.id })
        }
    }

    func loadDetail(forceRemote: Bool) async {
        loadGeneration &+= 1
        let gen = loadGeneration
        isLoading = true
        errorMessage = nil

        await refreshShelfStatus()
        if let last = await container.persistence.fetchBookLastPlayback(bookID: initialBook.id) {
            resumeChapterIndex = last.chapterIndex
            resumeChapterTitle = last.chapterTitle
        }

        if !forceRemote, let cached = await container.chapterCache.loadChaptersWithTimestamp(bookID: initialBook.id), !cached.chapters.isEmpty {
            let persistedSummary = (try? await container.persistence.fetchBook(id: initialBook.id)) ?? initialBook
            let effectiveSummary = !initialBook.intro.isEmpty ? initialBook : persistedSummary
            guard gen == loadGeneration else { return }
            applyDetail(BookDetailDTO(summary: effectiveSummary, chapters: cached.chapters))
            isLoading = false
            let isFinishedBook = effectiveSummary.statusText.contains("完结") || effectiveSummary.statusText.contains("完本")
            let ttl: TimeInterval = isFinishedBook ? (24 * 3600) : (30 * 60)
            if Date().timeIntervalSince(cached.updatedAt) < ttl && !effectiveSummary.intro.isEmpty {
                return
            }
        }

        do {
            let remote = try await container.pluginRuntime.bookDetail(sourceID: initialBook.sourceID, book: initialBook)
            guard gen == loadGeneration else { return }
            applyDetail(remote)
            isLoading = false
            try? await container.persistence.updateExistingBookMetadata(remote.summary)
            if !remote.chapters.isEmpty {
                try? await container.chapterCache.saveChapters(remote.chapters, bookID: remote.summary.id)
            }
        } catch {
            guard gen == loadGeneration else { return }
            isLoading = false
            if detail == nil || chapters.isEmpty {
                errorMessage = error.localizedDescription
            } else if forceRemote {
                banner.show("刷新目录失败：\(error.localizedDescription)", tone: .error)
            }
        }
    }

    func toggleShelf(_ book: BookSummaryDTO) async {
        let next = !inShelf
        do {
            try await container.persistence.upsertBook(book, addToShelf: next)
            inShelf = next
            container.notifyLibraryChanged()
            DSHaptics.selection()
            banner.show(next ? "已加入书架" : "已移出书架", tone: next ? .success : .info)
        } catch {
            banner.show("更新书架失败：\(error.localizedDescription)", tone: .error)
        }
    }
}
