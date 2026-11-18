import SwiftUI
import AVKit
import UIKit

struct AirPlayRoutePickerRepresentable: UIViewRepresentable {
    init() {}

    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.prioritizesVideoDevices = false
        return picker
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

struct MoreSheet: View {
    @Bindable var player: PlayerEngine
    let inShelf: Bool
    private let onToggleShelf: () -> Void
    private let onOpenSoundEffect: () -> Void
    private let onOpenSleep: () -> Void
    private let onSwitchSource: () -> Void
    private let onSearchNarrator: (String) -> Void
    private let onClose: () -> Void

    init(
        player: PlayerEngine = .shared,
        inShelf: Bool = false,
        onToggleShelf: @escaping () -> Void = {},
        onOpenSoundEffect: @escaping () -> Void = {},
        onOpenSleep: @escaping () -> Void = {},
        onSwitchSource: @escaping () -> Void = {},
        onSearchNarrator: @escaping (String) -> Void = { _ in },
        onClose: @escaping () -> Void
    ) {
        self.player = player
        self.inShelf = inShelf
        self.onToggleShelf = onToggleShelf
        self.onOpenSoundEffect = onOpenSoundEffect
        self.onOpenSleep = onOpenSleep
        self.onSwitchSource = onSwitchSource
        self.onSearchNarrator = onSearchNarrator
        self.onClose = onClose
    }

    var body: some View {
        DSSheetScaffold(title: "更多播放设置", onClose: onClose) {
            Form {
                if let book = player.currentBook {
                    Section("当前专辑与主播") {
                        HStack(spacing: Spacing.s3) {
                            DSCover(url: book.cover, title: book.title, side: 44)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("专辑：\(book.title)")
                                    .font(DSTypography.cardTitle)
                                    .lineLimit(1)
                                if !book.author.isEmpty {
                                    Button {
                                        let narrator = book.author
                                        onClose()
                                        onSearchNarrator(narrator)
                                    } label: {
                                        HStack(spacing: 4) {
                                            Image(systemName: "mic.fill")
                                            Text("主播：\(book.author)")
                                        }
                                        .font(DSTypography.caption)
                                        .foregroundStyle(Color.dsAccent)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            Spacer()
                            Button(inShelf ? "已收藏" : "收藏") {
                                onToggleShelf()
                            }
                            .font(DSTypography.caption.weight(.semibold))
                            .foregroundStyle(inShelf ? .secondary : Color.dsAccent)
                            .buttonStyle(.plain)
                        }
                    }
                }

                Section("快捷功能") {
                    Button {
                        onClose()
                        onOpenSoundEffect()
                    } label: {
                        HStack {
                            Label("音质音效", systemImage: "waveform")
                            Spacer()
                            Text("\(AppSettingsStore.shared.audioQualityTier.shortBadge) · \(AppSettingsStore.shared.soundEffectPreset.title)")
                                .font(DSTypography.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Button {
                        onClose()
                        onOpenSleep()
                    } label: {
                        HStack {
                            Label("定时关闭", systemImage: "clock")
                            Spacer()
                            Text(player.sleepOption.label)
                                .font(DSTypography.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("跳过片头与片尾") {
                    Stepper("跳过片头：\(player.skipIntroSec) 秒", value: $player.skipIntroSec, in: 0...180, step: 5)
                        .onChange(of: player.skipIntroSec) { _, _ in player.saveBookAudioSettings() }
                    Stepper("跳过片尾：\(player.skipOutroSec) 秒", value: $player.skipOutroSec, in: 0...180, step: 5)
                        .onChange(of: player.skipOutroSec) { _, _ in player.saveBookAudioSettings() }
                }

                Section("本书音频调节") {
                    VStack(alignment: .leading) {
                        Text("本书音量：\(Int(player.bookVolume * 100))%")
                            .font(DSTypography.numericFootnote)
                        Slider(value: $player.bookVolume, in: 0.1...1.0)
                            .onChange(of: player.bookVolume) { _, _ in
                                player.saveBookAudioSettings()
                            }
                    }

                    Picker("音频通道", selection: Binding(
                        get: { AppSettingsStore.shared.audioChannel },
                        set: { AppSettingsStore.shared.audioChannel = $0 }
                    )) {
                        ForEach(AudioChannelMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                }

                Section("输出与来源") {
                    HStack {
                        Text("AirPlay 音频输出")
                        Spacer()
                        AirPlayRoutePickerRepresentable()
                            .frame(width: 36, height: 36)
                    }

                    Button("切换书源 / 专辑详情") {
                        onClose()
                        onSwitchSource()
                    }

                    Button("复制当前章节标题") {
                        UIPasteboard.general.string = player.currentChapter?.title ?? ""
                        BannerCenter.shared.show("已复制", kind: .info)
                        onClose()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
