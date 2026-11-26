import DSCore
import DSPluginKit
import Foundation
import XCTest

/// 第十轮 4 项精修（b13）定向回归测试套件（总单测数达 308 项）
final class DSB13TenthAuditRegressionTests: XCTestCase {
    // B13-02: 无 audio() 方法的书源（如云图有声、博看有声）当 chapter.url 为直链音频时直接返回 AudioStreamDTO
    func testB13_02_DirectChapterURLBypassesMissingAudioMethod() async throws {
        let prelude = """
        var __sources = [];
        function registerSource(s) { __sources.push(s); }
        function __meta() { return JSON.stringify(__sources.map(function(s){ return { id: s.id, name: s.name, methods: ['search','bookDetail'] }; })); }
        function __invokeById(id, name, args) { return JSON.stringify({ __dsMissingMethod: name }); }
        """
        let script = "registerSource({ id: 'yuntu-test', name: '云图测试', search: function(){ return []; }, bookDetail: function(){ return {}; } });"
        let vault = CookieVault(inMemorySecretsOnly: true)
        let runtime = PluginRuntime(
            preludeScript: prelude,
            httpClient: HostHTTPClient(cookieVault: vault),
            cookieVault: vault,
            logger: DSDiagnosticLogStore()
        )
        let meta = SourceMetaDTO(id: "yuntu-test", name: "云图测试", methods: ["search", "bookDetail"])
        await runtime.registerSources([(meta: meta, scriptBody: script)])

        let chapter = ChapterDTO(id: "c1", index: 0, title: "第1集", url: "https://cdn.example.com/audio/ep01.m4a")
        let stream = try await runtime.resolveAudio(
            sourceID: "yuntu-test",
            bookID: "b1",
            chapter: chapter,
            preferredQuality: .high,
            forDownload: false
        )
        XCTAssertEqual(stream.url.absoluteString, "https://cdn.example.com/audio/ep01.m4a")
        XCTAssertFalse(stream.isHLS)
    }

    // B13-02: 无 audio() 方法且 chapter.url 为 HLS m3u8 直链时正确标记 isHLS = true
    func testB13_02_DirectHLSChapterURLMarksIsHLSTrue() async throws {
        let vault = CookieVault(inMemorySecretsOnly: true)
        let runtime = PluginRuntime(
            preludeScript: "",
            httpClient: HostHTTPClient(cookieVault: vault),
            cookieVault: vault,
            logger: DSDiagnosticLogStore()
        )
        let meta = SourceMetaDTO(id: "bookan-test", name: "博看测试", methods: ["search", "bookDetail"])
        await runtime.registerSources([(meta: meta, scriptBody: "")])

        let chapter = ChapterDTO(id: "c2", index: 1, title: "第2集", url: "https://cdn.example.com/live/ep02.m3u8")
        let stream = try await runtime.resolveAudio(
            sourceID: "bookan-test",
            bookID: "b2",
            chapter: chapter,
            preferredQuality: .standard,
            forDownload: false
        )
        XCTAssertTrue(stream.isHLS)
    }

    // B13-03: checkLogin() 正常返回登录账号昵称
    func testB13_03_CheckLoginReturnsAccountNickname() async throws {
        let prelude = """
        var __sources = [];
        function registerSource(s) { __sources.push(s); }
        function __invokeById(id, name, args) {
          var s = __sources[0];
          if (!s || typeof s[name] !== 'function') return JSON.stringify({ __dsMissingMethod: name });
          return JSON.stringify(s[name].apply(s, JSON.parse(args)));
        }
        """
        let script = "registerSource({ id: 'xmly-test', name: '喜马拉雅测试', checkLogin: function(){ return '测试VIP用户'; } });"
        let vault = CookieVault(inMemorySecretsOnly: true)
        let runtime = PluginRuntime(
            preludeScript: prelude,
            httpClient: HostHTTPClient(cookieVault: vault),
            cookieVault: vault,
            logger: DSDiagnosticLogStore()
        )
        let meta = SourceMetaDTO(id: "xmly-test", name: "喜马拉雅测试", methods: ["checkLogin"])
        await runtime.registerSources([(meta: meta, scriptBody: script)])

        let nickname = try await runtime.checkLogin(sourceID: "xmly-test")
        XCTAssertEqual(nickname, "测试VIP用户")
    }

    // B13-01: OneShotTimeoutGate 多次并发 resume 仅首次生效（零崩溃、防重入）
    func testB13_01_OneShotTimeoutGateResumesExactlyOnce() async throws {
        let value: String = try await withCheckedThrowingContinuation { cont in
            let gate = OneShotTimeoutGate(cont)
            gate.resume(returning: "first")
            gate.resume(returning: "second")
            gate.resume(throwing: PluginSecurityError.timeout(seconds: 1))
        }
        XCTAssertEqual(value, "first")
    }

    // B13-01: OneShotTimeoutGate 超时先到时忽略后续正常结果
    func testB13_01_OneShotTimeoutGateTimeoutWinsCleanly() async {
        do {
            let _: String = try await withCheckedThrowingContinuation { cont in
                let gate = OneShotTimeoutGate(cont)
                gate.resume(throwing: PluginSecurityError.timeout(seconds: 5))
                gate.resume(returning: "late")
            }
            XCTFail("应抛出超时错误")
        } catch {
            XCTAssertTrue(error is PluginSecurityError)
        }
    }
}
