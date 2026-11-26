import DSCore
import DSDesignSystem
import DSStorage
import SwiftUI

/// 首页半屏「切换书源」美化弹窗（约 66% 半屏高度 + 一句话简介 + 当前源赤陶高亮 + 右上角直达「管理」）
struct DiscoverSourcePickerSheet: View {
    @Environment(AppContainer.self) private var container
    let sections: [DiscoverSourceSection]
    let selectedSourceID: String
    let onSelectSource: (String) -> Void
    let onManageSources: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DSSpacing.md) {
                    ForEach(sections) { section in
                        VStack(alignment: .leading, spacing: DSSpacing.xs) {
                            Text(section.title)
                                .font(DSTypography.footnote.weight(.medium))
                                .foregroundStyle(DSColors.inkSecondary)
                                .padding(.horizontal, DSSpacing.xs)

                            VStack(spacing: 0) {
                                ForEach(Array(section.sources.enumerated()), id: \.element.id) { idx, src in
                                    let isSelected = (src.id == selectedSourceID)
                                    sourceRow(src, isSelected: isSelected)

                                    if idx < section.sources.count - 1 {
                                        Rectangle()
                                            .fill(DSColors.separator.opacity(0.35))
                                            .frame(height: 0.5)
                                            .padding(.leading, 58)
                                    }
                                }
                            }
                            .background(sectionCardBackground(section))
                            .clipShape(RoundedRectangle(cornerRadius: DSRadius.card, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: DSRadius.card, style: .continuous)
                                    .strokeBorder(sectionBorderColor(section), lineWidth: sectionHasOnlySelected(section) ? 1.0 : 0.6)
                            )
                        }
                    }
                }
                .padding(.horizontal, DSSpacing.pageHorizontal)
                .padding(.top, DSSpacing.xs)
                .padding(.bottom, DSSpacing.lg)
            }
            .background(DSColors.surfaceGrouped)
            .navigationTitle("切换书源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        DSHaptics.selection()
                        onManageSources()
                    } label: {
                        Text("管理")
                            .font(DSTypography.subheadline.weight(.medium))
                            .foregroundStyle(DSColors.inkPrimary)
                    }
                    .accessibilityIdentifier("discover.sourcePicker.manage")
                }
            }
        }
        .presentationDetents([.fraction(0.66), .large])
        .presentationDragIndicator(.visible)
    }

    private func sourceRow(_ src: SourceMetaDTO, isSelected: Bool) -> some View {
        let summaryText = SourceListHelper.conciseSummary(for: src)
        return Button {
            DSHaptics.selection()
            onSelectSource(src.id)
        } label: {
            HStack(spacing: DSSpacing.sm) {
                DSSourceAvatar(name: src.name, size: 38)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(src.name)
                            .font(DSTypography.rowTitle)
                            .foregroundStyle(DSColors.inkPrimary)
                            .lineLimit(1)
                        if SourceListHelper.supportsLogin(src) {
                            loginBadge(for: src.id)
                        }
                    }
                    Text(summaryText)
                        .font(DSTypography.caption)
                        .foregroundStyle(DSColors.inkSecondary)
                        .lineLimit(1)
                }

                Spacer(minLength: DSSpacing.xs)

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(DSTypography.title)
                        .foregroundStyle(DSColors.accent)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, DSSpacing.md)
            .padding(.vertical, DSSpacing.sm)
            .frame(minHeight: 62)
            .background(isSelected ? DSColors.accent.opacity(0.12) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityLabel("\(src.name)，\(summaryText)")
    }

    @ViewBuilder
    private func loginBadge(for sourceID: String) -> some View {
        switch container.sourceAuth.status(for: sourceID) {
        case .loggedIn:
            DSBadge("已登录", style: .success)
        case .checking:
            DSBadge("检测中", style: .neutral)
        case .loggedOut, .unknown:
            DSBadge("未登录", style: .warning)
        }
    }

    private func sectionHasOnlySelected(_ section: DiscoverSourceSection) -> Bool {
        section.sources.count == 1 && section.sources.first?.id == selectedSourceID
    }

    private func sectionCardBackground(_ section: DiscoverSourceSection) -> Color {
        sectionHasOnlySelected(section) ? DSColors.surfaceCard : DSColors.surfaceCard
    }

    private func sectionBorderColor(_ section: DiscoverSourceSection) -> Color {
        sectionHasOnlySelected(section) ? DSColors.accent.opacity(0.55) : DSColors.separator.opacity(0.25)
    }
}
