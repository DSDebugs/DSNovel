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
    private let onOpenSkip: () -> Void
    private let onOpenAudioEffects: () -> Void
    private let onOpenDownloads: () -> Void
    private let onOpenBookDetail: () -> Void
    private let onClose: () -> Void

    init(
        player: PlayerEngine = .shared,
        onOpenSkip: @escaping () -> Void = {},
        onOpenAudioEffects: @escaping () -> Void = {},
        onOpenDownloads: @escaping () -> Void = {},
        onOpenBookDetail: @escaping () -> Void = {},
        onClose: @escaping () -> Void
    ) {
        self.player = player
        self.onOpenSkip = onOpenSkip
        self.onOpenAudioEffects = onOpenAudioEffects
        self.onOpenDownloads = onOpenDownloads
        self.onOpenBookDetail = onOpenBookDetail
        self.onClose = onClose
    }

    var body: some View {
        DSSheetScaffold(title: "更多播放设置", onClose: onClose) {
            Form {
                Section("高频听书增强") {
                    Button {
                        onClose()
                        onOpenAudioEffects()
                    } label: {
                        HStack {
                            Label("音质档位与人声 EQ 音效", systemImage: "slider.vertical.3")
                            Spacer()
                            Text("\(player.streamStatusBadgeText) · \(player.audioEffectPreset.title)")
                                .font(DSTypography.caption)
                                .foregroundStyle(Color.dsAccent)
                        }
                    }

                    Button {
                        onClose()
                        onOpenDownloads()
                    } label: {
                        HStack {
                            Label("章节批量离线下载与队列", systemImage: "arrow.down.circle")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(DSTypography.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section {
                    Button {
                        onClose()
                        onOpenSkip()
                    } label: {
                        HStack {
                            Label("跳过片头片尾", systemImage: "forward.frame")
                            Spacer()
                            Text(player.bookSkip.summaryText)
                                .font(DSTypography.caption)
                                .foregroundStyle(player.bookSkip.state == .on ? Color.dsAccent : .secondary)
                            Image(systemName: "chevron.right")
                                .font(DSTypography.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("本书音量（支持最高 200% 增强）")
                                .font(DSTypography.numericFootnote)
                            Spacer()
                            Text("\(Int((player.bookVolume * 100.0).rounded()))%")
                                .font(DSTypography.numericFootnote.weight(.semibold))
                                .foregroundStyle(player.bookVolume > 1.01 ? .orange : Color.dsAccent)
                        }
                        Slider(
                            value: $player.bookVolume,
                            in: 0.0...2.0,
                            step: 0.05,
                            onEditingChanged: { editing in
                                if !editing {
                                    player.saveBookAudioSettings()
                                }
                            }
                        )
                        .tint(player.bookVolume > 1.01 ? .orange : Color.dsAccent)
                    }

                    Picker("音频通道", selection: Binding(
                        get: { AppSettingsStore.shared.audioChannel },
                        set: { AppSettingsStore.shared.audioChannel = $0 }
                    )) {
                        ForEach(AudioChannelMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                } header: {
                    Text("本书设置")
                } footer: {
                    Text(AppSettingsStore.shared.audioChannel.subtitle)
                        .font(DSTypography.caption)
                }

                Section("输出与书籍信息") {
                    HStack {
                        Label("AirPlay 无线音频输出", systemImage: "airplayaudio")
                        Spacer()
                        AirPlayRoutePickerRepresentable()
                            .frame(width: 36, height: 36)
                    }

                    Button {
                        onClose()
                        onOpenBookDetail()
                    } label: {
                        Label("查看书籍详情页与简介", systemImage: "book.closed")
                    }

                    Button {
                        UIPasteboard.general.string = player.currentChapter?.title ?? ""
                        player.showInlineToast("已复制当前章节标题")
                        onClose()
                    } label: {
                        Label("复制当前章节标题", systemImage: "doc.on.doc")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.dsSurfaceGrouped)
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.medium, .large])
    }
}
