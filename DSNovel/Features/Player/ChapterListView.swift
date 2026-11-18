import SwiftUI

enum ChapterSheetTab: String, CaseIterable, Identifiable {
    case playlist = "播放列表"
    case recent = "已播节目"

    var id: String { rawValue }
}

struct ChapterListView: View {
    let chapters: [ChapterDTO]
    let currentChapterID: String?
    let isPlaying: Bool
    private let onSelectChapter: (ChapterDTO) -> Void
    private let onClose: () -> Void

    @State private var selectedTab: ChapterSheetTab = .playlist
    @State private var isAscending: Bool = true
    @State private var libraryStore = LibraryStore.shared

    init(
        chapters: [ChapterDTO],
        currentChapterID: String?,
        isPlaying: Bool,
        onSelectChapter: @escaping (ChapterDTO) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.chapters = chapters
        self.currentChapterID = currentChapterID
        self.isPlaying = isPlaying
        self.onSelectChapter = onSelectChapter
        self.onClose = onClose
    }

    private var orderedChapters: [ChapterDTO] {
        isAscending ? chapters : Array(chapters.reversed())
    }

    var body: some View {
        DSSheetScaffold(title: "播放列表（共 \(chapters.count) 章）", onClose: onClose) {
            VStack(spacing: 0) {
                HStack {
                    Picker("标签", selection: $selectedTab) {
                        ForEach(ChapterSheetTab.allCases) { tab in
                            Text(tab.rawValue).tag(tab)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 220)

                    Spacer()

                    if selectedTab == .playlist {
                        Button {
                            DSHapticPolicy.fire(.selection)
                            isAscending.toggle()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.up.arrow.down")
                                Text(isAscending ? "从旧到新" : "从新到旧")
                            }
                            .font(DSTypography.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, Spacing.pageHorizontal)
                .padding(.vertical, Spacing.s2)

                switch selectedTab {
                case .playlist:
                    playlistContent
                case .recent:
                    recentPlayedContent
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var playlistContent: some View {
        ScrollViewReader { proxy in
            List(orderedChapters) { ch in
                let isCurrent = (ch.id == currentChapterID)
                Button {
                    DSHapticPolicy.fire(.chapterSwitch)
                    onSelectChapter(ch)
                    onClose()
                } label: {
                    HStack(spacing: Spacing.s3) {
                        if isCurrent {
                            DSEqualizer(isPlaying: isPlaying)
                        } else {
                            Text("\(ch.index + 1)")
                                .font(DSTypography.numericCaption)
                                .foregroundStyle(.secondary)
                                .frame(minWidth: 26, alignment: .leading)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(ch.title)
                                .font(DSTypography.body.weight(isCurrent ? .semibold : .regular))
                                .foregroundStyle(isCurrent ? Color.dsAccent : .primary)
                                .lineLimit(1)
                            if ch.hintDurationSec > 0 {
                                Text(PlaybackClock.formatSeconds(ch.hintDurationSec))
                                    .font(DSTypography.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                    }
                }
                .id(ch.id)
                .listRowBackground(Color.dsSurfaceCard)
            }
            .listStyle(.plain)
            .onAppear {
                if let currentChapterID {
                    proxy.scrollTo(currentChapterID, anchor: .center)
                }
            }
        }
    }

    private var recentPlayedContent: some View {
        let items: [Book] = {
            var all: [Book] = []
            if let cont = libraryStore.continueBook { all.append(cont) }
            for b in libraryStore.recentBooks where !all.contains(where: { $0.id == b.id }) {
                all.append(b)
            }
            return all
        }()

        return Group {
            if items.isEmpty {
                DSStateView(kind: .empty)
            } else {
                List(items) { book in
                    Button {
                        onClose()
                        AppRouter.shared.open(.book(book.bookRef))
                    } label: {
                        HStack(spacing: Spacing.s3) {
                            DSCover(url: book.cover, title: book.title, side: 48)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(book.title)
                                    .font(DSTypography.rowTitle)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Text(book.lastChapterTitle.isEmpty ? "第 \(max(1, book.lastChapterIndex)) 章" : book.lastChapterTitle)
                                    .font(DSTypography.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.dsSurfaceCard)
                }
                .listStyle(.plain)
            }
        }
    }
}
