import DSCore
import DSDesignSystem
import SwiftUI

extension SourceListView {
    func groupSectionHeader(_ section: SourceGroupSection) -> some View {
        let isDefault = (section.title == SourceListHelper.defaultGroupName)
        return HStack {
            Text("\(section.title)（\(section.sources.count)）")
                .font(DSTypography.subheadline.weight(.semibold))
                .foregroundStyle(DSColors.inkPrimary)
            Spacer()
            Menu {
                if !isDefault {
                    Button {
                        renamingGroupName = section.title
                        renameGroupInput = section.title
                    } label: {
                        Label("重命名分组", systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        pendingDeleteGroupName = section.title
                    } label: {
                        Label("删除分组", systemImage: "trash")
                    }
                }
                Button {
                    showOrganizeSheet = true
                } label: {
                    Label("管理全部分组与排序", systemImage: "folder.badge.gearshape")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(DSTypography.subheadline)
                    .foregroundStyle(DSColors.inkSecondary)
                    .frame(minWidth: 32, minHeight: 28, alignment: .trailing)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("管理分组 \(section.title)")
        }
        .textCase(nil)
    }

    func sourceRow(_ src: SourceMetaDTO, availableGroups: [String]) -> some View {
        let summaryText = SourceListHelper.conciseSummary(for: src)
        let currentGroup = SourceListHelper.normalizedGroupName(src.groupName)

        return HStack(spacing: DSSpacing.sm) {
            Button {
                router.push(.sourceDetail(sourceID: src.id))
            } label: {
                HStack(spacing: DSSpacing.sm) {
                    DSSourceAvatar(name: src.name, size: 38)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(src.name)
                                .font(DSTypography.rowTitle)
                                .foregroundStyle(src.isEnabled ? DSColors.inkPrimary : DSColors.inkSecondary)
                                .lineLimit(1)
                            if SourceListHelper.supportsLogin(src) {
                                loginStatusBadge(for: src.id)
                            }
                            if src.isPinned {
                                DSBadge("置顶", style: .accent)
                            }
                        }
                        HStack(spacing: 6) {
                            if let rec = healthEngine.record(for: src.id), let badge = rec.badgeText {
                                SourceHealthBadge(text: badge, state: rec.state)
                            }
                            Text(summaryText)
                                .font(DSTypography.caption)
                                .foregroundStyle(DSColors.inkSecondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Toggle("", isOn: Binding(
                get: { src.isEnabled },
                set: { next in enqueueSourceUpdate(src.id, isEnabled: next, isPinned: nil, groupName: nil) }
            ))
            .labelsHidden()
            .tint(DSColors.accent)
            .fixedSize()
            .accessibilityLabel("启用或停用书源 \(src.name)")
        }
        .contextMenu {
            Menu("移至分组") {
                ForEach(availableGroups, id: \.self) { g in
                    Button {
                        enqueueSourceUpdate(src.id, isEnabled: nil, isPinned: nil, groupName: g)
                    } label: {
                        HStack {
                            Text(g)
                            if g == currentGroup { Image(systemName: "checkmark") }
                        }
                    }
                }
            }
            Button {
                Task { await checkSingleSource(src) }
            } label: {
                Label("重新检测可用性", systemImage: "waveform.path.ecg")
            }
            Button {
                enqueueSourceUpdate(src.id, isEnabled: nil, isPinned: !src.isPinned, groupName: nil)
            } label: {
                Label(src.isPinned ? "取消置顶" : "置顶展示", systemImage: src.isPinned ? "pin.slash" : "pin")
            }
            Button(role: .destructive) {
                deleteSource(src.id)
            } label: {
                Label("移除书源", systemImage: "trash")
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button("删除", role: .destructive) {
                deleteSource(src.id)
            }
            Button {
                DSHaptics.selection()
                enqueueSourceUpdate(src.id, isEnabled: nil, isPinned: !src.isPinned, groupName: nil)
            } label: {
                Label(src.isPinned ? "取消置顶" : "置顶", systemImage: src.isPinned ? "pin.slash" : "pin")
            }
            .tint(DSColors.accent)
        }
    }

    @ViewBuilder
    private func loginStatusBadge(for sourceID: String) -> some View {
        switch container.sourceAuth.status(for: sourceID) {
        case .loggedIn:
            DSBadge("已登录", style: .success)
        case .checking:
            DSBadge("检测中", style: .neutral)
        case .loggedOut, .unknown:
            DSBadge("未登录", style: .warning)
        }
    }
}
