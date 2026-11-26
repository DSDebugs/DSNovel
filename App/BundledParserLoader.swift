import DSCore
import DSPluginKit
import Foundation

/// 音频解析三连击激活结果
enum BundledParserLoadOutcome: Equatable, Sendable {
    case installed(name: String, version: String)
    case upgraded(name: String, fromVersion: String, toVersion: String)
    case reEnabled(name: String, version: String)
    case alreadyLatest(name: String, version: String)
    case newerInstalled(name: String, installedVersion: String, bundledVersion: String)

    var bannerMessage: String {
        switch self {
        case .installed(let name, let version):
            return "已开启音频解析入口并启用：\(name) v\(version)"
        case .upgraded(let name, _, let toVersion):
            return "已开启音频解析入口并升级 \(name) 至 v\(toVersion)"
        case .reEnabled(let name, let version):
            return "已开启音频解析入口并恢复启用：\(name) v\(version)"
        case .alreadyLatest(let name, let version):
            return "已开启音频解析入口：\(name) v\(version) 已启用"
        case .newerInstalled(let name, let installed, _):
            return "已开启音频解析入口（保留更高版本 \(name) v\(installed)）"
        }
    }
}

/// 喜马拉雅内置音频解析脚本加载器（供「关于 → 版本号三连击」触发）
enum BundledParserLoader {
    static let bundledResourceName = "ximalaya_parser-v1.5.5"
    static let bundledResourceExt = "js"
    static let bundledParserID = "ximalaya-vip"
    static let bundledParserVersion = "1.5.5"

    /// 从 App Bundle 读取内置解析脚本并执行幂等安装 / 升级 / 恢复启用
    static func activateBundledXimalayaParser(
        engine: BuiltinParserEngine,
        bundle: Bundle = .main
    ) async throws -> BundledParserLoadOutcome {
        guard let url = bundle.url(forResource: bundledResourceName, withExtension: bundledResourceExt),
              let scriptBody = try? String(contentsOf: url, encoding: .utf8),
              !scriptBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PluginSecurityError.scriptError("未找到音频解析脚本资源 \(bundledResourceName).\(bundledResourceExt)")
        }
        return try await installIfNeeded(
            engine: engine,
            scriptBody: scriptBody,
            expectedID: bundledParserID,
            bundledVersion: bundledParserVersion
        )
    }

    /// 可测试核心逻辑：按已安装状态决定首次安装、同版幂等、停用恢复、低版升级或高版防降级
    static func installIfNeeded(
        engine: BuiltinParserEngine,
        scriptBody: String,
        expectedID: String = bundledParserID,
        bundledVersion: String = bundledParserVersion
    ) async throws -> BundledParserLoadOutcome {
        let existingList = await engine.listParsers()
        let bundledSHA = DSCrypto.sha256Hex(scriptBody)
        if let existing = existingList.first(where: { $0.id == expectedID }) {
            let cmp = existing.version.compare(bundledVersion, options: .numeric)
            if cmp == .orderedDescending {
                if !existing.isEnabled {
                    try await engine.setEnabled(id: existing.id, enabled: true)
                }
                return .newerInstalled(
                    name: existing.name,
                    installedVersion: existing.version,
                    bundledVersion: bundledVersion
                )
            }
            if cmp == .orderedSame && existing.sha256 == bundledSHA {
                if !existing.isEnabled {
                    try await engine.setEnabled(id: existing.id, enabled: true)
                    return .reEnabled(name: existing.name, version: existing.version)
                }
                return .alreadyLatest(name: existing.name, version: existing.version)
            }
            let upgraded = try await engine.installParser(scriptBody: scriptBody)
            return .upgraded(name: upgraded.name, fromVersion: existing.version, toVersion: upgraded.version)
        }
        let installed = try await engine.installParser(scriptBody: scriptBody)
        return .installed(name: installed.name, version: installed.version)
    }
}
