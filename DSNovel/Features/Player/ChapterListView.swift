import SwiftUI

struct ChapterListView: View {
    let chapters: [ChapterDTO]
    let currentChapterID: String?
    let isPlaying: Bool
    private let onSelectChapter: (ChapterDTO) -> Void
    private let onClose: () -> Void

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

    var body: some View {
        DSSheetScaffold(title: "章节目录（共 \(chapters.count) 章）", onClose: onClose) {
            ScrollViewReader { proxy in
                List(chapters) { ch in
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
                            }
                            Text(ch.title)
                                .font(DSTypography.body.weight(isCurrent ? .semibold : .regular))
                                .foregroundStyle(isCurrent ? Color.dsAccent : .primary)
                            Spacer()
                        }
                    }
                    .id(ch.id)
                }
                .onAppear {
                    if let currentChapterID {
                        proxy.scrollTo(currentChapterID, anchor: .center)
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
