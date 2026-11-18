import SwiftUI

enum SoundEffectSheetTab: String, CaseIterable, Identifiable {
    case quality = "音质"
    case effect = "音效"

    var id: String { rawValue }
}

struct SoundEffectSheet: View {
    @State private var settings = AppSettingsStore.shared
    @State private var selectedTab: SoundEffectSheetTab = .effect
    private let onClose: () -> Void

    init(initialTab: SoundEffectSheetTab = .effect, onClose: @escaping () -> Void) {
        self._selectedTab = State(initialValue: initialTab)
        self.onClose = onClose
    }

    var body: some View {
        DSSheetScaffold(title: "音质与音效", onClose: onClose) {
            VStack(spacing: 0) {
                Picker("模式", selection: $selectedTab) {
                    ForEach(SoundEffectSheetTab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, Spacing.pageHorizontal)
                .padding(.vertical, Spacing.s2)

                List {
                    switch selectedTab {
                    case .quality:
                        qualityList
                    case .effect:
                        effectList
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .background(Color.dsSurfaceGrouped)
            }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private var qualityList: some View {
        Section("选择在线播放与缓存音质") {
            ForEach(AudioQualityTier.allCases) { tier in
                let isSelected = (settings.audioQualityTier == tier)
                Button {
                    DSHapticPolicy.fire(.selection)
                    settings.audioQualityTier = tier
                } label: {
                    HStack(spacing: Spacing.s3) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text(tier.title)
                                    .font(DSTypography.rowTitle)
                                    .foregroundStyle(.primary)
                                if tier == .ultra {
                                    DSBadge("HQ", style: .accent)
                                }
                            }
                            Text(tier.subtitle)
                                .font(DSTypography.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(isSelected ? "使用中" : "使用")
                            .font(DSTypography.caption.weight(.semibold))
                            .foregroundStyle(isSelected ? .secondary : Color.dsAccent)
                            .padding(.horizontal, Spacing.s3)
                            .padding(.vertical, 6)
                            .background(
                                Capsule()
                                    .strokeBorder(isSelected ? Color.dsSeparator : Color.dsAccent, lineWidth: 1)
                            )
                    }
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
                .listRowBackground(Color.dsSurfaceCard)
            }
        }
    }

    @ViewBuilder
    private var effectList: some View {
        Section("听书声学场景预设") {
            ForEach(AudioSoundEffectPreset.allCases) { preset in
                let isSelected = (settings.soundEffectPreset == preset)
                Button {
                    DSHapticPolicy.fire(.selection)
                    settings.soundEffectPreset = preset
                } label: {
                    HStack(spacing: Spacing.s3) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text(preset.title)
                                    .font(DSTypography.rowTitle)
                                    .foregroundStyle(.primary)
                                if let badge = preset.badge {
                                    DSBadge(badge, style: .accent)
                                }
                            }
                            Text(preset.subtitle)
                                .font(DSTypography.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(isSelected ? "使用中" : "使用")
                            .font(DSTypography.caption.weight(.semibold))
                            .foregroundStyle(isSelected ? .secondary : Color.dsAccent)
                            .padding(.horizontal, Spacing.s3)
                            .padding(.vertical, 6)
                            .background(
                                Capsule()
                                    .strokeBorder(isSelected ? Color.dsSeparator : Color.dsAccent, lineWidth: 1)
                            )
                    }
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
                .listRowBackground(Color.dsSurfaceCard)
            }
        }
    }
}
