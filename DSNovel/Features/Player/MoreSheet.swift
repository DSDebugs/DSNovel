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
    private let onSwitchSource: () -> Void
    private let onClose: () -> Void

    init(
        player: PlayerEngine = .shared,
        onSwitchSource: @escaping () -> Void = {},
        onClose: @escaping () -> Void
    ) {
        self.player = player
        self.onSwitchSource = onSwitchSource
        self.onClose = onClose
    }

    var body: some View {
        DSSheetScaffold(title: "更多播放设置", onClose: onClose) {
            Form {
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

                Section("跳过片头与片尾") {
                    Stepper("跳过片头：\(player.skipIntroSec) 秒", value: $player.skipIntroSec, in: 0...180, step: 5)
                        .onChange(of: player.skipIntroSec) { _, _ in player.saveBookAudioSettings() }
                    Stepper("跳过片尾：\(player.skipOutroSec) 秒", value: $player.skipOutroSec, in: 0...180, step: 5)
                        .onChange(of: player.skipOutroSec) { _, _ in player.saveBookAudioSettings() }
                }

                Section("输出与来源") {
                    HStack {
                        Text("AirPlay 音频输出")
                        Spacer()
                        AirPlayRoutePickerRepresentable()
                            .frame(width: 36, height: 36)
                    }

                    Button("切换书源") {
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
