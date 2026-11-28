import DSCore
import DSDesignSystem
import DSPlayback
import DSStorage
import SwiftUI

/// 播放器时间戳书签抽屉（支持当前秒一键打点、备注编辑、睡眠自动打点区分与精准跳转）
struct AudioBookmarksSheet: View {
    @Environment(AppContainer.self) private var container
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(DSBannerCoordinator.self) private var banner

    @State private var editingBookmark: AudioBookmarkDTO?
    @State private var noteDraft = ""
    private let onDismiss: () -> Void

    init(onDismiss: @escaping () -> Void) {
        self.onDismiss = onDismiss
    }

    private var currentBookID: String {
        playback.currentBook?.id ?? ""
    }

    private var currentPositionText: String {
        let sec = max(0, Int(playback.clock.currentSeconds))
        let h = sec / 3600
        let m = (sec % 3600) / 60
        let s = sec % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    var body: some View {
        let items = container.bookmarks.bookmarks(forBookID: currentBookID)
        DSSheetScaffold(title: "时间戳书签", banner: banner, onDismiss: onDismiss) {
            VStack(spacing: 0) {
                addBookmarkHeader
                    .padding(.horizontal, DSSpacing.pageHorizontal)
                    .padding(.vertical, DSSpacing.sm)

                if items.isEmpty {
                    Spacer()
                    VStack(spacing: DSSpacing.xs) {
                        Image(systemName: "bookmark")
                            .font(DSTypography.largeTitle)
                            .foregroundStyle(DSColors.inkSecondary)
                        Text("暂无书签记录")
                            .font(DSTypography.rowTitle)
                            .foregroundStyle(DSColors.inkPrimary)
                        Text("点击上方按钮记录精彩片段，睡眠定时暂停前也会自动打点")
                            .font(DSTypography.caption)
                            .foregroundStyle(DSColors.inkSecondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.horizontal, DSSpacing.lg)
                    Spacer()
                } else {
                    List {
                        ForEach(items) { item in
                            bookmarkRow(item)
                                .listRowInsets(EdgeInsets(top: 6, leading: DSSpacing.pageHorizontal, bottom: 6, trailing: DSSpacing.pageHorizontal))
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        DSHaptics.lightImpact()
                                        container.bookmarks.deleteBookmark(id: item.id)
                                        banner.show("已删除书签", tone: .info)
                                    } label: {
                                        Label("删除", systemImage: "trash")
                                    }
                                }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(DSColors.surfaceGrouped)
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.medium, .large])
        .alert("编辑书签备注", isPresented: Binding(
            get: { editingBookmark != nil },
            set: { if !$0 { editingBookmark = nil } }
        )) {
            TextField("输入简短备注（可选）", text: $noteDraft)
            Button("取消", role: .cancel) { editingBookmark = nil }
            Button("保存") {
                if let target = editingBookmark {
                    container.bookmarks.updateNote(id: target.id, note: noteDraft)
                    banner.show("已更新书签备注", tone: .success)
                }
                editingBookmark = nil
            }
        } message: {
            Text("为该时间点添加简短备注，方便日后回听。")
        }
    }

    private var addBookmarkHeader: some View {
        Button {
            addCurrentPositionBookmark()
        } label: {
            HStack(spacing: DSSpacing.xs) {
                Image(systemName: "bookmark.fill")
                    .font(DSTypography.subheadline.weight(.semibold))
                Text("在 \(currentPositionText) 添加书签")
                    .font(DSTypography.subheadline.weight(.semibold).monospacedDigit())
            }
            .foregroundStyle(DSColors.onAccent)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(Capsule(style: .continuous).fill(DSColors.accent))
        }
        .buttonStyle(.dsCard)
        .disabled(playback.currentBook == nil || playback.currentChapter == nil)
    }

    private func bookmarkRow(_ item: AudioBookmarkDTO) -> some View {
        let isSleep = (item.kind == .sleepAuto)
        return HStack(spacing: DSSpacing.sm) {
            ZStack {
                Circle()
                    .fill(isSleep ? Color.indigo.opacity(0.24) : DSColors.accent.opacity(0.18))
                    .frame(width: 34, height: 34)
                Image(systemName: isSleep ? "moon.zzz.fill" : "bookmark.fill")
                    .font(DSTypography.caption.weight(.semibold))
                    .foregroundStyle(isSleep ? Color.indigo : DSColors.accent)
            }

            Button {
                jumpToBookmark(item)
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text("第 \(item.chapterIndex + 1) 章 · \(item.formattedPosition)")
                            .font(DSTypography.subheadline.weight(.semibold).monospacedDigit())
                            .foregroundStyle(DSColors.inkPrimary)
                            .lineLimit(1)
                        if isSleep {
                            Text("睡眠打点")
                                .font(DSTypography.caption2.weight(.semibold))
                                .foregroundStyle(Color.indigo)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.indigo.opacity(0.18)))
                        }
                    }
                    Text(item.note.isEmpty ? item.chapterTitle : item.note)
                        .font(DSTypography.caption)
                        .foregroundStyle(DSColors.inkSecondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                editingBookmark = item
                noteDraft = item.note
            } label: {
                Image(systemName: "pencil")
                    .font(DSTypography.caption)
                    .foregroundStyle(DSColors.inkSecondary)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("编辑备注")

            Button {
                jumpToBookmark(item)
            } label: {
                Image(systemName: "play.fill")
                    .font(DSTypography.caption.weight(.bold))
                    .foregroundStyle(DSColors.accent)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(DSColors.accent.opacity(0.16)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("跳转到此书签播放")
        }
        .padding(DSSpacing.sm)
        .background(
            RoundedRectangle(cornerRadius: DSRadius.card, style: .continuous)
                .fill(DSColors.surfaceCard)
                .overlay(
                    RoundedRectangle(cornerRadius: DSRadius.card, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.07), lineWidth: 0.6)
                )
        )
    }

    private func addCurrentPositionBookmark() {
        guard let book = playback.currentBook, let chapter = playback.currentChapter else { return }
        DSHaptics.selection()
        container.bookmarks.addBookmark(
            bookID: book.id,
            bookTitle: book.title,
            chapterID: chapter.id,
            chapterIndex: playback.currentChapterIndex,
            chapterTitle: chapter.title,
            positionMs: Int(playback.clock.currentSeconds * 1000),
            note: "",
            kind: .manual
        )
        banner.show("已在 \(currentPositionText) 添加书签", tone: .success)
    }

    private func jumpToBookmark(_ item: AudioBookmarkDTO) {
        guard let book = playback.currentBook else { return }
        guard let targetIdx = item.resolveChapterIndex(in: playback.chapters) else {
            banner.show("未找到对应章节", tone: .warning)
            return
        }
        DSHaptics.selection()
        let targetSec = Double(item.positionMs) / 1000.0
        if targetIdx == playback.currentChapterIndex {
            playback.seek(to: targetSec)
            if !playback.state.isPlaying { playback.resume() }
        } else {
            playback.play(book: book, chapters: playback.chapters, startIndex: targetIdx, autoPlay: true)
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(350))
                playback.seek(to: targetSec)
            }
        }
        banner.show("已跳转至第 \(targetIdx + 1) 章 \(item.formattedPosition)", tone: .info)
        onDismiss()
    }
}
