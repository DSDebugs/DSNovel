import Foundation
import SwiftData

/// 按书独立的片头片尾跳过配置（纯值类型，便于单元测试与 UI 绑定）
struct BookSkipConfig: Equatable, Hashable, Sendable {
    enum State: Equatable, Sendable {
        /// 从未配置（关闭且片头/片尾均为 0）
        case unset
        /// 已开启且至少一项 > 0
        case on
        /// 已关闭但保留了已配置的时长，再次开启可一键恢复
        case off
    }

    static let maxSkipSec: Int = 180
    static let stepSec: Int = 5
    static let defaultPrefillIntroSec: Int = 15
    static let defaultPrefillOutroSec: Int = 10
    static let quickPresetSeconds: [Int] = [0, 10, 15, 30, 45, 60]

    static let unset = BookSkipConfig(enabled: false, introSec: 0, outroSec: 0)

    var enabled: Bool
    var introSec: Int
    var outroSec: Int

    init(enabled: Bool = false, introSec: Int = 0, outroSec: Int = 0) {
        self.enabled = enabled
        self.introSec = Self.clamp(introSec)
        self.outroSec = Self.clamp(outroSec)
    }

    static func clamp(_ seconds: Int) -> Int {
        min(max(seconds, 0), maxSkipSec)
    }

    /// 规范化非法组合：开启但两项均为 0 时自动回落为未设置
    var normalized: BookSkipConfig {
        let clampedIntro = Self.clamp(introSec)
        let clampedOutro = Self.clamp(outroSec)
        if enabled && clampedIntro == 0 && clampedOutro == 0 {
            return .unset
        }
        return BookSkipConfig(enabled: enabled, introSec: clampedIntro, outroSec: clampedOutro)
    }

    var state: State {
        let clampedIntro = Self.clamp(introSec)
        let clampedOutro = Self.clamp(outroSec)
        if enabled && (clampedIntro > 0 || clampedOutro > 0) {
            return .on
        }
        if clampedIntro > 0 || clampedOutro > 0 {
            return .off
        }
        return .unset
    }

    var effectiveIntroSec: Int {
        state == .on ? Self.clamp(introSec) : 0
    }

    var effectiveOutroSec: Int {
        state == .on ? Self.clamp(outroSec) : 0
    }

    var summaryText: String {
        switch state {
        case .unset:
            return "未设置"
        case .off:
            return "已关闭"
        case .on:
            let intro = effectiveIntroSec
            let outro = effectiveOutroSec
            if intro > 0 && outro > 0 {
                return "片头 \(intro) 秒 · 片尾 \(outro) 秒"
            } else if intro > 0 {
                return "片头 \(intro) 秒"
            } else {
                return "片尾 \(outro) 秒"
            }
        }
    }

    /// 切换总开关：首次从「未设置」开启时预填 15s / 10s；关闭时保留原有数值
    func toggled(to isOn: Bool) -> BookSkipConfig {
        let clampedIntro = Self.clamp(introSec)
        let clampedOutro = Self.clamp(outroSec)
        if isOn {
            if clampedIntro == 0 && clampedOutro == 0 {
                return BookSkipConfig(
                    enabled: true,
                    introSec: Self.defaultPrefillIntroSec,
                    outroSec: Self.defaultPrefillOutroSec
                )
            }
            return BookSkipConfig(enabled: true, introSec: clampedIntro, outroSec: clampedOutro)
        } else {
            return BookSkipConfig(enabled: false, introSec: clampedIntro, outroSec: clampedOutro)
        }
    }

    /// 统一起播位置计算：有续播进度优先保留进度；否则按本书片头跳过，并做短章保护（intro >= duration - 5 时不跳）
    static func startPositionSec(
        initialPositionMs: Int,
        duration: Double,
        config: BookSkipConfig
    ) -> Double {
        if initialPositionMs > 0 {
            return Double(initialPositionMs) / 1000.0
        }
        let intro = Double(config.effectiveIntroSec)
        guard intro > 0 else { return 0 }
        if duration.isFinite && duration > 0 && intro >= duration - 5.0 {
            return 0
        }
        return intro
    }

    /// 统一片尾触发判定：含单次触发保护、手动回听抑制与短章保护（duration > intro + outro + 10）
    static func shouldTriggerOutroSkip(
        positionSec: Double,
        durationSec: Double,
        config: BookSkipConfig,
        hasTriggered: Bool,
        isSuppressed: Bool
    ) -> Bool {
        guard !hasTriggered, !isSuppressed else { return false }
        let outro = Double(config.effectiveOutroSec)
        let intro = Double(config.effectiveIntroSec)
        guard outro > 0, durationSec.isFinite, positionSec.isFinite else { return false }
        guard durationSec > intro + outro + 10.0 else { return false }
        return positionSec >= durationSec - outro
    }

    /// 计算精确片尾跳过边界时刻（供 AVPlayer.addBoundaryTimeObserver 注册）
    static func outroBoundarySec(
        durationSec: Double,
        config: BookSkipConfig
    ) -> Double? {
        let outro = Double(config.effectiveOutroSec)
        let intro = Double(config.effectiveIntroSec)
        guard outro > 0, durationSec.isFinite, durationSec > intro + outro + 10.0 else {
            return nil
        }
        return max(0, durationSec - outro)
    }

    /// 用户手动拖回片尾前 2 秒以上时，恢复本章片尾跳过触发能力
    static func shouldResetOutroSuppression(
        seekSec: Double,
        durationSec: Double,
        config: BookSkipConfig
    ) -> Bool {
        let outro = Double(config.effectiveOutroSec)
        guard outro > 0, durationSec.isFinite, durationSec > 0, seekSec.isFinite else {
            return false
        }
        return seekSec < durationSec - outro - 2.0
    }
}

/// 一次性幂等迁移：移除全局片头片尾默认设置并保留每本书当前听感
enum PerBookSkipMigration {
    static let completedKey = "migration.perBookSkip.v1"
    static let legacyIntroKey = "defaultSkipIntroSec"
    static let legacyOutroKey = "defaultSkipOutroSec"
    static let pendingNoticeKey = "migration.perBookSkip.pendingNotice.v1"

    @MainActor
    @discardableResult
    static func runIfNeeded(
        context: ModelContext,
        defaults: UserDefaults = .standard,
        saveAction: ((ModelContext) throws -> Void)? = nil
    ) -> Bool {
        if defaults.bool(forKey: completedKey) {
            return false
        }
        let legacyIntro = defaults.integer(forKey: legacyIntroKey)
        let legacyOutro = defaults.integer(forKey: legacyOutroKey)
        let hadLegacyGlobal = (legacyIntro > 0 || legacyOutro > 0)

        do {
            let books = try context.fetch(FetchDescriptor<Book>())
            for book in books {
                book.skipEnabled = (book.skipIntroSec > 0 || book.skipOutroSec > 0)
            }
            if let saveAction {
                try saveAction(context)
            } else {
                try context.save()
            }
            defaults.removeObject(forKey: legacyIntroKey)
            defaults.removeObject(forKey: legacyOutroKey)
            if hadLegacyGlobal {
                defaults.set(true, forKey: pendingNoticeKey)
            }
            defaults.set(true, forKey: completedKey)
            return true
        } catch {
            return false
        }
    }

    @MainActor
    static func consumePendingNoticeIfNeeded(defaults: UserDefaults = .standard) -> String? {
        guard defaults.bool(forKey: pendingNoticeKey) else { return nil }
        defaults.removeObject(forKey: pendingNoticeKey)
        return "全局片头片尾设置已移除，现在可在播放页为每本书单独设置；已保留各书原有设置"
    }
}
