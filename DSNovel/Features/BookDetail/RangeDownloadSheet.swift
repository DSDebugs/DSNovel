import SwiftUI

struct RangeDownloadSheet: View {
    let totalChapters: Int
    @State private var startChapter: Int = 1
    @State private var endChapter: Int
    private let onConfirmRange: (Int, Int) -> Void
    private let onClose: () -> Void

    init(
        totalChapters: Int,
        onConfirmRange: @escaping (Int, Int) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.totalChapters = max(1, totalChapters)
        self._endChapter = State(initialValue: max(1, min(30, totalChapters)))
        self.onConfirmRange = onConfirmRange
        self.onClose = onClose
    }

    var body: some View {
        DSSheetScaffold(title: "自定义区间下载", onClose: onClose) {
            Form {
                Section("选择章节范围（共 \(totalChapters) 章）") {
                    Stepper("起始：第 \(startChapter) 章", value: $startChapter, in: 1...totalChapters)
                    Stepper("结束：第 \(endChapter) 章", value: $endChapter, in: max(startChapter, 1)...totalChapters)
                }
                Section {
                    DSActionButton(
                        title: "下载第 \(startChapter)–\(max(startChapter, endChapter)) 章",
                        icon: "arrow.down.circle.fill",
                        role: .primary
                    ) {
                        onConfirmRange(startChapter, max(startChapter, endChapter))
                        onClose()
                    }
                }
            }
        }
    }
}
