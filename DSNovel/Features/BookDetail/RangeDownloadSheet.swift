import SwiftUI

struct RangeDownloadSheet: View {
    let totalChapters: Int
    let currentChapterIndex: Int
    @State private var startChapter: Int
    @State private var endChapter: Int
    @FocusState private var focusedField: Field?
    private let onConfirmRange: (Int, Int) -> Void
    private let onClose: () -> Void

    private enum Field {
        case start
        case end
    }

    init(
        totalChapters: Int,
        currentChapterIndex: Int = 1,
        onConfirmRange: @escaping (Int, Int) -> Void,
        onClose: @escaping () -> Void
    ) {
        let safeTotal = max(1, totalChapters)
        let safeCurrent = max(1, min(currentChapterIndex, safeTotal))
        self.totalChapters = safeTotal
        self.currentChapterIndex = safeCurrent
        self._startChapter = State(initialValue: safeCurrent)
        self._endChapter = State(initialValue: min(safeTotal, safeCurrent + 29))
        self.onConfirmRange = onConfirmRange
        self.onClose = onClose
    }

    private func applyPreset(start: Int, end: Int) {
        let clampedStart = max(1, min(start, totalChapters))
        let clampedEnd = max(clampedStart, min(end, totalChapters))
        startChapter = clampedStart
        endChapter = clampedEnd
        focusedField = nil
        DSHapticPolicy.fire(.selection)
    }

    var body: some View {
        DSSheetScaffold(title: "自定义区间下载", subtitle: "共 \(totalChapters) 章", onClose: onClose) {
            Form {
                Section("快捷区间") {
                    HStack(spacing: Spacing.s2) {
                        presetButton(title: "后 50 章") {
                            applyPreset(start: currentChapterIndex, end: currentChapterIndex + 49)
                        }
                        presetButton(title: "后 100 章") {
                            applyPreset(start: currentChapterIndex, end: currentChapterIndex + 99)
                        }
                        presetButton(title: "全部未下载") {
                            applyPreset(start: currentChapterIndex, end: totalChapters)
                        }
                    }
                    .listRowBackground(Color.dsSurfaceCard)
                }

                Section("选择章节范围（1 – \(totalChapters)）") {
                    HStack(spacing: Spacing.s2) {
                        Text("起始章")
                            .font(DSTypography.body)
                        TextField("1", value: $startChapter, format: .number)
                            .focused($focusedField, equals: .start)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .font(DSTypography.numericCaption.weight(.semibold))
                            .frame(width: 72)
                            .padding(.horizontal, Spacing.s2)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: Radius.input, style: .continuous)
                                    .fill(Color.dsSurfaceGrouped)
                            )
                        Spacer()
                        Stepper("", value: $startChapter, in: 1...totalChapters)
                            .labelsHidden()
                    }
                    .frame(minHeight: 44)
                    .listRowBackground(Color.dsSurfaceCard)

                    HStack(spacing: Spacing.s2) {
                        Text("结束章")
                            .font(DSTypography.body)
                        TextField("\(totalChapters)", value: $endChapter, format: .number)
                            .focused($focusedField, equals: .end)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .font(DSTypography.numericCaption.weight(.semibold))
                            .frame(width: 72)
                            .padding(.horizontal, Spacing.s2)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: Radius.input, style: .continuous)
                                    .fill(Color.dsSurfaceGrouped)
                            )
                        Spacer()
                        Stepper("", value: $endChapter, in: 1...totalChapters)
                            .labelsHidden()
                    }
                    .frame(minHeight: 44)
                    .listRowBackground(Color.dsSurfaceCard)
                }

                Section {
                    let safeStart = max(1, min(startChapter, totalChapters))
                    let safeEnd = max(safeStart, min(endChapter, totalChapters))
                    let count = safeEnd - safeStart + 1
                    DSActionButton(
                        title: "下载第 \(safeStart)–\(safeEnd) 章（共 \(count) 章）",
                        icon: "arrow.down.circle.fill",
                        role: .primary
                    ) {
                        focusedField = nil
                        onConfirmRange(safeStart, safeEnd)
                        onClose()
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.dsSurfaceGrouped)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") {
                        focusedField = nil
                    }
                    .fontWeight(.semibold)
                }
            }
            .onChange(of: startChapter) { _, newValue in
                let clamped = max(1, min(newValue, totalChapters))
                if clamped != startChapter {
                    startChapter = clamped
                }
                if endChapter < clamped {
                    endChapter = clamped
                }
            }
            .onChange(of: endChapter) { _, newValue in
                let clamped = max(1, min(newValue, totalChapters))
                if clamped != endChapter {
                    endChapter = clamped
                }
                if clamped < startChapter {
                    startChapter = clamped
                }
            }
        }
    }

    private func presetButton(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(DSTypography.caption.weight(.semibold))
                .foregroundStyle(Color.dsAccent)
                .frame(maxWidth: .infinity, minHeight: 36)
                .padding(.horizontal, Spacing.s2)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.dsAccent.opacity(0.12))
                )
        }
        .buttonStyle(.plain)
    }
}
