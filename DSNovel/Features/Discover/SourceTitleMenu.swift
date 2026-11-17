import SwiftUI

struct SourceTitleMenu: View {
    let sources: [PluginRecord]
    let currentSourceID: String
    private let onSelectSource: (String) -> Void
    private let onMoreSources: () -> Void
    private let onManageSources: () -> Void

    init(
        sources: [PluginRecord],
        currentSourceID: String,
        onSelectSource: @escaping (String) -> Void,
        onMoreSources: @escaping () -> Void,
        onManageSources: @escaping () -> Void
    ) {
        self.sources = sources
        self.currentSourceID = currentSourceID
        self.onSelectSource = onSelectSource
        self.onMoreSources = onMoreSources
        self.onManageSources = onManageSources
    }

    var body: some View {
        ForEach(sources.prefix(12)) { src in
            Button {
                onSelectSource(src.id)
            } label: {
                HStack {
                    Text(src.name)
                    Spacer()
                    if src.id == currentSourceID {
                        Image(systemName: "checkmark")
                    }
                }
            }
        }
        Divider()
        if sources.count > 12 {
            Button(action: onMoreSources) {
                Label("更多书源…", systemImage: "ellipsis.circle")
            }
        }
        Button(action: onManageSources) {
            Label("管理书源", systemImage: "slider.horizontal.3")
        }
    }
}
