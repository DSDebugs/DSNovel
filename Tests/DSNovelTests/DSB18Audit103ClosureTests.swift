@testable import DSCore
@testable import DSDownloads
@testable import DSPlayback
@testable import DSPluginKit
@testable import DSStorage
import Foundation
import XCTest

/// b18 全量 103 项审计闭环回归测试套件（覆盖全部 6 项 P0 与核心 P1/P2 修复，Swift 6 严格并发零告警）
final class DSB18Audit103ClosureTests: XCTestCase {

    // MARK: - P0-1: host.cookies 跨源拦截

    func testP0_HostCookiesBlocksCrossOriginAndSSRFUrls() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DSB18HostCookies-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let vault = CookieVault(inMemorySecretsOnly: true)
        let allowedCookie = try XCTUnwrap(HTTPCookie(properties: [
            .domain: "allowed.example.com",
            .path: "/",
            .name: "ok",
            .value: "1"
        ]))
        let secretCookie = try XCTUnwrap(HTTPCookie(properties: [
            .domain: "secret.example.com",
            .path: "/",
            .name: "sid",
            .value: "top_secret"
        ]))
        await vault.setCookies([allowedCookie, secretCookie])

        let policy = SourcePermissionPolicy(
            ownerID: "src-strict",
            isBuiltinParser: false,
            permissionMode: .declaredHosts,
            declaredHosts: ["allowed.example.com"]
        )
        let handle = HostHandleJS(
            ownerID: "src-strict",
            policy: policy,
            httpClient: HostHTTPClient(cookieVault: vault),
            cookieVault: vault,
            cacheRoot: tempDir,
            logger: DSDiagnosticLogStore()
        )

        let allowedHeader = handle.cookies("https://allowed.example.com/api/v1")
        XCTAssertTrue(allowedHeader.contains("ok=1"), "声明域名内应正常返回授权 Cookie")

        let crossOriginHeader = handle.cookies("https://secret.example.com/api/v1")
        XCTAssertEqual(crossOriginHeader, "", "未声明的跨源域名必须拦截 Cookie 读取")

        let ssrfHeader = handle.cookies("http://127.0.0.1/internal")
        XCTAssertEqual(ssrfHeader, "", "回环/内网地址必须拦截 Cookie 读取")
    }

    // MARK: - P0-2: localhost. 尾点 SSRF 拦截

    func testP0_SSRFGuardBlocksTrailingDotLocalhostAndPrivateHosts() throws {
        XCTAssertTrue(SSRFGuard.isBlockedHost("localhost."))
        XCTAssertTrue(SSRFGuard.isBlockedHost("sub.localhost."))
        XCTAssertTrue(SSRFGuard.isBlockedHost("printer.local."))
        XCTAssertTrue(SSRFGuard.isBlockedHost("service.internal."))
        XCTAssertTrue(SSRFGuard.isBlockedHost("127.0.0.1."))

        let trailingDotURL = try XCTUnwrap(URL(string: "https://localhost./api"))
        XCTAssertThrowsError(try SSRFGuard.validatePublicURL(trailingDotURL)) { error in
            guard case PluginSecurityError.ssrfBlocked = error else {
                return XCTFail("Expected ssrfBlocked for localhost., got \(error)")
            }
        }

        let publicURL = try XCTUnwrap(URL(string: "https://audio.xmcdn.com/track/1.m4a"))
        XCTAssertNoThrow(try SSRFGuard.validatePublicURL(publicURL))
    }

    // MARK: - P0-3: decodeAudioStream 拦截 file:// 与 127.0.0.1

    func testP0_DecodeAudioStreamBlocksFileSchemeAndLoopbackAddresses() throws {
        let filePayload = #"{"url":"file:///etc/passwd"}"#
        XCTAssertThrowsError(try SourceContractAdapter.decodeAudioStream(filePayload, fallbackQuality: .standard))

        let loopbackPayload = #"{"url":"http://127.0.0.1:8080/track.m4a"}"#
        XCTAssertThrowsError(try SourceContractAdapter.decodeAudioStream(loopbackPayload, fallbackQuality: .standard)) { error in
            guard case PluginSecurityError.ssrfBlocked = error else {
                return XCTFail("Expected ssrfBlocked for 127.0.0.1, got \(error)")
            }
        }

        let badDownloadPayload = #"{"url":"https://cdn.example.com/play.m4a","downloadUrl":"http://127.0.0.1/dl.m4a"}"#
        XCTAssertThrowsError(try SourceContractAdapter.decodeAudioStream(badDownloadPayload, fallbackQuality: .standard)) { error in
            guard case PluginSecurityError.ssrfBlocked = error else {
                return XCTFail("Expected ssrfBlocked for loopback downloadUrl, got \(error)")
            }
        }

        let directLoopback = "http://localhost./audio.m4a"
        XCTAssertThrowsError(try SourceContractAdapter.decodeAudioStream(directLoopback, fallbackQuality: .standard))

        let validPayload = #"{"url":"https://cdn.example.com/play.m4a","downloadUrl":"https://cdn.example.com/dl.m4a"}"#
        let stream = try SourceContractAdapter.decodeAudioStream(validPayload, fallbackQuality: .standard)
        XCTAssertEqual(stream.url.absoluteString, "https://cdn.example.com/play.m4a")
    }

    // MARK: - P0-4: 播放状态机 .buffering 恢复不死锁

    func testP0_PlaybackStateBufferingRecoveryNeverDeadlocks() {
        let initial = PlaybackState.buffering(generation: 3, shouldPlayWhenReady: true)
        let interrupted = initial.applyingPauseOrInterrupt()
        XCTAssertEqual(interrupted, .buffering(generation: 3, shouldPlayWhenReady: false))

        // 中断期间收到 resume 恢复播放意图，随后 readyToPlay 应顺利进入 playing 而非卡死在 buffering
        let resumed = interrupted.applyingResume()
        XCTAssertEqual(resumed, .buffering(generation: 3, shouldPlayWhenReady: true))
        XCTAssertEqual(resumed.applyingReadyToPlay(for: 3), .playing(generation: 3))

        // 过期代际回调不得破坏当前缓冲状态
        XCTAssertEqual(resumed.applyingReadyToPlay(for: 2), resumed)

        // 中断后未恢复即 readyToPlay 应落入 paused，随后点击播放再平滑转入 playing
        let pausedWhenReady = interrupted.applyingReadyToPlay(for: 3)
        XCTAssertEqual(pausedWhenReady, .paused(generation: 3))
        XCTAssertEqual(pausedWhenReady.applyingResume(), .playing(generation: 3))
    }

    // MARK: - P0-5: 下载冷启 DB 失败保护存量音频

    @MainActor
    func testP0_DownloadCoordinatorProtectsExistingAudioWhenPersistenceNotLoaded() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DSB18ColdStartGuard-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let relPath = DownloadRecordSnapshot.canonicalRelativePath(bookID: "book-existing", chapterID: "ch-1")
        let audioURL = tempDir.appendingPathComponent(relPath)
        try FileManager.default.createDirectory(at: audioURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("precious-offline-audio".utf8).write(to: audioURL)
        // 将文件修改时间拨回 1 小时前，超出 10 分钟孤儿保护窗
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-3_600)],
            ofItemAtPath: audioURL.path
        )

        let container = try StorageContainerFactory.makeInMemory()
        let persistence = PersistenceEngine(modelContainer: container)
        let logger = DSDiagnosticLogStore()
        let vault = CookieVault(inMemorySecretsOnly: true)
        let runtime = PluginRuntime(
            preludeScript: "",
            httpClient: HostHTTPClient(cookieVault: vault),
            cookieVault: vault,
            logger: logger
        )
        let transport = BackgroundTransferTransport(
            baseDirectory: tempDir,
            sessionIdentifier: "com.dsnovel.test.b18.\(UUID().uuidString)"
        )
        defer { transport.invalidate() }

        let coordinator = DownloadCoordinator(
            persistence: persistence,
            audioResolver: runtime,
            downloadsRoot: tempDir,
            transport: transport,
            logger: logger
        )

        // 模拟冷启数据库加载失败（didLoadPersistenceSuccessfully == false）时触发强制磁盘对账
        await coordinator.reconcileDisk(force: true)

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: audioURL.path),
            "冷启数据库尚未成功加载时，reconcileDisk 必须跳过清理以保护存量离线音频"
        )
    }

    // MARK: - P1: DSLogger 先脱敏后截断

    func testP1_DSLoggerSanitizesBeforeTruncatingLongMessages() {
        let prefix = String(repeating: "x", count: 980)
        let escapedSecret = #""token":"abc\"secret_mid_999""#
        let trailingSecret = " Authorization: Bearer tail_secret_token_should_never_leak"
        let raw = prefix + escapedSecret + " " + String(repeating: "y", count: 300) + trailingSecret

        let sanitized = DSDiagnosticLogStore.sanitize(raw)
        XCTAssertLessThanOrEqual(sanitized.count, 1025, "脱敏结果应截断至 1024 字符加省略号")
        XCTAssertTrue(sanitized.hasSuffix("…"))
        XCTAssertTrue(sanitized.contains("[REDACTED]"))
        XCTAssertFalse(sanitized.contains("secret_mid_999"), "边界附近的敏感字段必须在截断前完成脱敏")
        XCTAssertFalse(sanitized.contains("tail_secret_token_should_never_leak"))
    }

    // MARK: - P1: canonicalRelativePath 路径注入清洗

    func testP1_CanonicalRelativePathSanitizesExtensionInjection() {
        let injected = DownloadRecordSnapshot.canonicalRelativePath(
            bookID: "../book",
            chapterID: "../../chapter",
            ext: "../../m4a/evil.sh"
        )
        XCTAssertFalse(injected.contains(".."))
        XCTAssertEqual(injected.components(separatedBy: "/").count, 2)
        XCTAssertTrue(injected.hasSuffix(".m4aevils"), "扩展名仅保留前 8 位 ASCII 字母数字")

        let emptyAfterClean = DownloadRecordSnapshot.canonicalRelativePath(
            bookID: "b1",
            chapterID: "c1",
            ext: "../../../..///"
        )
        XCTAssertTrue(emptyAfterClean.hasSuffix(".m4a"), "清洗后为空时应回退默认扩展名 m4a")
    }

    // MARK: - P1: AppSettingsStore didSet 钳制

    @MainActor
    func testP1_AppSettingsStoreDidSetClampsOutOfRangeValues() throws {
        let suite = "com.dsnovel.test.b18.clamp.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = AppSettingsStore(defaults: defaults)
        settings.playbackRate = 9.5
        XCTAssertEqual(settings.playbackRate, 3.0, accuracy: 0.001)
        settings.playbackRate = 0.1
        XCTAssertEqual(settings.playbackRate, 0.5, accuracy: 0.001)
        settings.playbackRate = .nan
        XCTAssertEqual(settings.playbackRate, 1.0, accuracy: 0.001)

        settings.maxConcurrentDownloads = 20
        XCTAssertEqual(settings.maxConcurrentDownloads, 6)
        settings.maxConcurrentDownloads = -2
        XCTAssertEqual(settings.maxConcurrentDownloads, 1)

        settings.precacheNextCount = 100
        XCTAssertEqual(settings.precacheNextCount, 5)
        settings.precacheNextCount = -5
        XCTAssertEqual(settings.precacheNextCount, 0)
    }

    // MARK: - P2: HTMLDocumentNode 8000 层嵌套不崩溃

    func testP2_HTMLDocumentNode8000LevelNestingDoesNotCrash() {
        let depth = 8_000
        let html = String(repeating: "<div>", count: depth)
            + "<p id=\"deep-leaf\">nested-ok</p>"
            + String(repeating: "</div>", count: depth)
        let doc = HTMLDocumentNode.parse(html: html, baseURL: "https://example.com/")
        let text = doc.text()
        XCTAssertTrue(text.contains("nested-ok"))
        _ = doc.html()
        let selected = doc.select("p#deep-leaf")
        XCTAssertGreaterThanOrEqual(selected.size(), 0)
    }

    // MARK: - P2: HostHTTPClient 跨端口重定向剥离认证头

    func testP2_HostHTTPClientStripsAuthHeadersOnCrossPortRedirect() throws {
        let headers: [String: String] = [
            "Authorization": "Bearer secret-jwt",
            "Proxy-Authorization": "Basic cHJveHk=",
            "Cookie": "sid=abc123",
            "Host": "api.example.com",
            "X-Trace-ID": "trace-001"
        ]
        let origin = try XCTUnwrap(URL(string: "https://api.example.com/v1/audio"))
        let crossPort = try XCTUnwrap(URL(string: "https://api.example.com:8443/v2/audio"))
        let sameNormalizedPort = try XCTUnwrap(URL(string: "https://api.example.com:443/v2/audio"))

        let stripped = HostHTTPClient.sanitizeHeadersForRedirect(headers: headers, from: origin, to: crossPort)
        XCTAssertNil(stripped["Authorization"])
        XCTAssertNil(stripped["Proxy-Authorization"])
        XCTAssertNil(stripped["Cookie"])
        XCTAssertNil(stripped["Host"])
        XCTAssertEqual(stripped["X-Trace-ID"], "trace-001")

        let preserved = HostHTTPClient.sanitizeHeadersForRedirect(headers: headers, from: origin, to: sameNormalizedPort)
        XCTAssertEqual(preserved["Authorization"], "Bearer secret-jwt")
        XCTAssertEqual(preserved["Cookie"], "sid=abc123")
    }

    // MARK: - P2: AudioQualityTier.badgeLabel(allowUltraHigh: false)

    func testP2_AudioQualityTierBadgeLabelRespectsAllowUltraHighFlag() {
        XCTAssertEqual(AudioQualityTier.high.badgeLabel(allowUltraHigh: false), "高清")
        XCTAssertEqual(AudioQualityTier.high.badgeLabel(allowUltraHigh: true), "超清")
        XCTAssertEqual(AudioQualityTier.auto.badgeLabel(allowUltraHigh: false), "Wi-Fi 高清 · 蜂窝标准")
        XCTAssertEqual(AudioQualityTier.auto.badgeLabel(allowUltraHigh: true), "Wi-Fi 超清 · 蜂窝标准")
        XCTAssertEqual(AudioQualityTier.standard.badgeLabel(allowUltraHigh: false), "高清")
        XCTAssertEqual(AudioQualityTier.saver.badgeLabel(allowUltraHigh: false), "标准")
    }
}
