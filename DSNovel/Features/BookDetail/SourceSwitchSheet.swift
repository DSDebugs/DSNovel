import SwiftUI

struct SourceSwitchSheet: View {
    let currentRef: BookRef
    let candidates: [BookRef]
    let sourceStore: SourceStore
    private let onSelectCandidate: (BookRef) -> Void
    private let onClose: () -> Void

    init(
        currentRef: BookRef,
        candidates: [BookRef],
        sourceStore: SourceStore = .shared,
        onSelectCandidate: @escaping (BookRef) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.currentRef = currentRef
        self.candidates = candidates
        self.sourceStore = sourceStore
        self.onSelectCandidate = onSelectCandidate
        self.onClose = onClose
    }

    var body: some View {
        let allItems = [currentRef] + candidates.filter { $0.id != currentRef.id }
        DSSheetScaffold(title: "切换书源", onClose: onClose) {
            List(Array(allItems.enumerated()), id: \.element.id) { idx, item in
                let src = sourceStore.source(for: item.sourceID)
                Button {
                    onSelectCandidate(item)
                } label: {
                    HStack(spacing: Spacing.s3) {
                        DSSourceBadge(
                            name: src?.name ?? item.sourceID,
                            health: DSSourceHealthKind(rawValue: src?.lastCheckStatus ?? "") ?? .untested,
                            latencyMs: (src?.lastLatencyMs ?? -1) > 0 ? src?.lastLatencyMs : nil
                        )

                        if item.chapterCount > 0 {
                            Text("\(item.chapterCount) 章")
                                .font(DSTypography.numericCaption)
                                .foregroundStyle(.secondary)
                        }

                        if idx == 0 {
                            DSBadge("当前书源", style: .accent)
                        }

                        Spacer()

                        if item.id == currentRef.id {
                            Image(systemName: "checkmark")
                                .foregroundStyle(Color.dsAccent)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Color.dsSurfaceGrouped)
        }
        .presentationDetents([.medium, .large])
    }
}
