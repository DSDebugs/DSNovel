import DSCore
import DSDesignSystem
import DSPluginKit
import Foundation
import Testing

@Suite("安全与稳定性加固回归测试（JS 槽位替补、封面重定向 SSRF 与流式字节上限）")
struct DSHardeningAuditTests {
    @Test("JSContextPool 死循环卡死槽位可退役替补且忽略旧代际延迟归还")
    func jsContextPoolRetireAndReplacePreventsDeadlock() async throws {
        let pool = JSContextPool(maxSlots: 1, labelPrefix: "com.dsnovel.app.test.retire", maxRetiredReplacements: 2)
        let stuckLease = try await pool.acquireLease()
        #expect(await pool.currentActiveSlots == 1)

        // 模拟死循环超时后退役替补
        let replaced = await pool.retireAndReplaceLease(stuckLease)
        #expect(replaced)
        #expect(await pool.currentRetiredSlots == 1)
        #expect(await pool.currentActiveSlots == 0)

        // 后续正常请求可立刻拿到新槽位而不会永久挂起
        let freshLease = try await pool.acquireLease(timeoutSeconds: 1.0)
        #expect(freshLease.index == stuckLease.index)

        // 旧卡死槽位即使后续延迟 release，也绝不能误释放新槽位
        await pool.releaseLease(stuckLease)
        #expect(await pool.currentActiveSlots == 1)

        await pool.releaseLease(freshLease)
        #expect(await pool.currentActiveSlots == 0)
    }

    @Test("JSContextPool 排队超过 timeoutSeconds 主动取消而非无限挂起")
    func jsContextPoolAcquireTimeoutPreventsInfiniteHang() async throws {
        let pool = JSContextPool(maxSlots: 1, labelPrefix: "com.dsnovel.app.test.wait", maxRetiredReplacements: 0)
        let lease = try await pool.acquireLease()
        var didTimeoutCancel = false
        do {
            _ = try await pool.acquireLease(timeoutSeconds: 0.15)
        } catch is CancellationError {
            didTimeoutCancel = true
        }
        #expect(didTimeoutCancel)
        await pool.releaseLease(lease)
    }

    @Test("DSCappedHTTPTransfer 块级流式超限实时断流并阻止自动 302 重定向")
    func cappedHTTPTransferEnforcesChunkLimitAndBlocksRedirect() async throws {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [HardeningMockURLProtocol.self]
        let session = URLSession(configuration: cfg)
        defer { session.finishTasksAndInvalidate() }

        // 1. 分块累加超过 maxBytes 时立即抛出 responseTooLarge
        let bigURL = try #require(URL(string: "https://cdn.example.com/huge.bin"))
        var threwTooLarge = false
        do {
            _ = try await DSCappedHTTPTransfer.fetch(
                request: URLRequest(url: bigURL),
                session: session,
                maxBytes: 1024,
                blockRedirects: true
            )
        } catch DSCappedHTTPError.responseTooLarge(let limit) {
            threwTooLarge = (limit == 1024)
        }
        #expect(threwTooLarge)

        // 2. 302 指向内网回环时不会自动跟随，原样返回 302 由上层逐跳拦截
        let redirURL = try #require(URL(string: "https://cdn.example.com/redir-loopback"))
        let (_, http) = try await DSCappedHTTPTransfer.fetch(
            request: URLRequest(url: redirURL),
            session: session,
            maxBytes: 1024,
            blockRedirects: true
        )
        #expect(http.statusCode == 302)
        #expect(http.value(forHTTPHeaderField: "Location") == "http://127.0.0.1:8080/secret")
    }
}

private final class HardeningMockURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        if url.path == "/huge.bin" {
            let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)
            if let resp { client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed) }
            // 分 4 块每块 512B（共 2048B > 1024B 上限）
            let chunk = Data(repeating: 0x41, count: 512)
            for _ in 0..<4 {
                client?.urlProtocol(self, didLoad: chunk)
            }
            client?.urlProtocolDidFinishLoading(self)
        } else if url.path == "/redir-loopback" {
            let resp = HTTPURLResponse(
                url: url,
                statusCode: 302,
                httpVersion: "HTTP/1.1",
                headerFields: ["Location": "http://127.0.0.1:8080/secret"]
            )
            if let resp { client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed) }
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}
