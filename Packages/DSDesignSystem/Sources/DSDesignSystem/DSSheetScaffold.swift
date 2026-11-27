import Observation
import SwiftUI

/// 单横幅消息模型
public struct DSBannerMessage: Equatable, Sendable, Identifiable {
    public enum Tone: Sendable, Equatable {
        case info
        case success
        case warning
        case error
    }

    public let id: UUID
    public let tone: Tone
    public let text: String

    public init(id: UUID = UUID(), tone: Tone = .info, text: String) {
        self.id = id
        self.tone = tone
        self.text = text
    }
}

/// 单横幅全局协调器（L-IOS-6/AUD-23/AUD-94：activeHostIDs 宿主栈保证仅顶层弹窗渲染横幅并播报 VoiceOver）
@Observable
@MainActor
public final class DSBannerCoordinator {
    public private(set) var current: DSBannerMessage?
    public private(set) var activeHostIDs: [UUID] = []
    private var legacySheetCount: Int = 0
    private var dismissTask: Task<Void, Never>?

    public init() {}

    public var activeSheetCount: Int {
        activeHostIDs.count + legacySheetCount
    }

    public var isSheetPresenting: Bool { activeSheetCount > 0 }

    public func show(_ text: String, tone: DSBannerMessage.Tone = .info, duration: TimeInterval = 2.6) {
        dismissTask?.cancel()
        let msg = DSBannerMessage(tone: tone, text: text)
        current = msg
        AccessibilityNotification.Announcement(text).post()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            if self?.current?.id == msg.id {
                self?.current = nil
            }
        }
    }

    public func dismiss() {
        dismissTask?.cancel()
        current = nil
    }

    public func registerHost(_ id: UUID) {
        activeHostIDs.removeAll { $0 == id }
        activeHostIDs.append(id)
    }

    public func unregisterHost(_ id: UUID) {
        activeHostIDs.removeAll { $0 == id }
    }

    public func isTopHost(_ id: UUID) -> Bool {
        activeHostIDs.last == id
    }

    public func registerSheetAppear() {
        legacySheetCount += 1
    }

    public func registerSheetDisappear() {
        legacySheetCount = max(0, legacySheetCount - 1)
    }
}

/// 统一弹窗容器（AUD-23：仅顶层宿主渲染横幅，避免嵌套弹窗与底层双横幅重叠）
public struct DSSheetScaffold<Content: View>: View {
    private let title: String
    private let banner: DSBannerCoordinator
    private let onDismiss: () -> Void
    private let content: () -> Content
    @Environment(\.dsEffectiveReduceMotion) private var reduceMotion
    @State private var hostID = UUID()

    public init(
        title: String,
        banner: DSBannerCoordinator,
        onDismiss: @escaping () -> Void,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.banner = banner
        self.onDismiss = onDismiss
        self.content = content
    }

    public var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                DSColors.surfaceBase.ignoresSafeArea()
                content()
                if banner.isTopHost(hostID), let msg = banner.current {
                    DSBannerPill(message: msg)
                        .padding(.top, DSSpacing.xs)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(DSMotion.resolved(DSMotion.snappy, reduceMotion: reduceMotion), value: banner.current != nil)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { onDismiss() }
                        .frame(minWidth: 44, minHeight: 44)
                }
            }
        }
        .onAppear { banner.registerHost(hostID) }
        .onDisappear { banner.unregisterHost(hostID) }
    }
}

public struct DSBannerPill: View {
    private let message: DSBannerMessage

    public init(message: DSBannerMessage) {
        self.message = message
    }

    public var body: some View {
        HStack(spacing: DSSpacing.xs) {
            Image(systemName: iconName)
                .foregroundStyle(toneColor)
            Text(message.text)
                .font(DSTypography.footnote)
                .foregroundStyle(DSColors.inkPrimary)
                .lineLimit(2)
        }
        .padding(.horizontal, DSSpacing.md)
        .padding(.vertical, DSSpacing.xs)
        .background(.ultraThinMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
        .accessibilityLabel(message.text)
        .allowsHitTesting(false)
    }

    private var iconName: String {
        switch message.tone {
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    private var toneColor: Color {
        switch message.tone {
        case .info: return DSColors.accent
        case .success: return DSColors.success
        case .warning: return DSColors.warning
        case .error: return DSColors.danger
        }
    }
}
