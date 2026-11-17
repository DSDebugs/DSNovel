import SwiftUI

struct SourceTitleMenu: View {
    let sources: [PluginRecord]
    let currentSourceID: String
    private let onSelectSource: (String) -> Void
    private let onMoreSources: () -> Void

    init(
        sources: [PluginRecord],
        currentSourceID: String,
        onSelectSource: @escaping (String) -> Void,
        onMoreSources: @escaping () -> Void,
        onManageSources: @escaping () -> Void = {}
    ) {
        self.sources = sources
        self.currentSourceID = currentSourceID
        self.onSelectSource = onSelectSource
        self.onMoreSources = onMoreSources
        _ = onManageSources
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
        if sources.count > 12 {
            Divider()
            Button(action: onMoreSources) {
                Label("更多书源…", systemImage: "ellipsis.circle")
            }
        }
    }
}
