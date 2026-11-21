import DSCore
import DSPluginKit
import Foundation
import XCTest

final class DSPluginKitSecurityTests: XCTestCase {
    func testSSRFGuardBlocksPrivateAndLoopbackHosts() {
        let blocked = [
            "http://localhost/admin",
            "http://127.0.0.1:8080/secret",
            "http://10.0.0.1/internal",
            "http://172.16.5.1/internal",
            "http://192.168.1.1/router",
            "http://169.254.169.254/latest/meta-data",
            "http://[::1]/",
            "file:///etc/passwd"
        ]
        for raw in blocked {
            let url = URL(string: raw)!
            XCTAssertThrowsError(try SSRFGuard.validatePublicURL(url), "Should block \(raw)")
        }
        XCTAssertNoThrow(try SSRFGuard.validatePublicURL(URL(string: "https://www.ximalaya.com/sound/1")!))
    }

    func testQ5PermissionPolicyModes() {
        let compatPolicy = SourcePermissionPolicy(
            ownerID: "third-party",
            isBuiltinParser: false,
            permissionMode: .compatApproved,
            declaredHosts: [],
            allowNetwork: true
        )
        XCTAssertNoThrow(try compatPolicy.validate(url: URL(string: "https://audio.example.org/1.m4a")!))
        XCTAssertThrowsError(try compatPolicy.validate(url: URL(string: "http://127.0.0.1/1.m4a")!))

        let parserPolicy = SourcePermissionPolicy(
            ownerID: "xmly-parser",
            isBuiltinParser: true,
            permissionMode: .declaredHosts,
            declaredHosts: ["ximalaya.com"],
            allowNetwork: true
        )
        XCTAssertNoThrow(try parserPolicy.validate(url: URL(string: "https://mobile.ximalaya.com/api")!))
        XCTAssertThrowsError(try parserPolicy.validate(url: URL(string: "https://evil.example.com/steal")!))
    }

    func testCrossDomainRedirectStripsCookieAndAuthorization() {
        let headers = [
            "Cookie": "session=topsecret",
            "Authorization": "Bearer jwt-token",
            "Referer": "https://a.example.com/"
        ]
        let cross = HostHTTPClient.sanitizeHeadersForRedirect(
            headers: headers,
            from: URL(string: "https://a.example.com/start")!,
            to: URL(string: "https://b.other.com/dest")!
        )
        XCTAssertNil(cross["Cookie"])
        XCTAssertNil(cross["Authorization"])
        XCTAssertEqual(cross["Referer"], "https://a.example.com/")

        let same = HostHTTPClient.sanitizeHeadersForRedirect(
            headers: headers,
            from: URL(string: "https://a.example.com/start")!,
            to: URL(string: "https://a.example.com/next")!
        )
        XCTAssertEqual(same["Cookie"], "session=topsecret")
    }

    func testCookieVaultEnforcesSecureExpiredAndPathAndOwnerScope() async {
        let vault = CookieVault(inMemorySecretsOnly: true)
        let secureCookie = HTTPCookie(properties: [
            .domain: "audio.test.local",
            .path: "/vip",
            .name: "sid",
            .value: "abc",
            .secure: "TRUE",
            .expires: Date().addingTimeInterval(3600)
        ])!
        let expiredCookie = HTTPCookie(properties: [
            .domain: "audio.test.local",
            .path: "/",
            .name: "old",
            .value: "xyz",
            .expires: Date().addingTimeInterval(-60)
        ])!
        await vault.setCookies([secureCookie, expiredCookie])

        let httpHeader = await vault.cookieHeader(for: URL(string: "http://audio.test.local/vip/1")!)
        XCTAssertEqual(httpHeader, "")

        let wrongPathHeader = await vault.cookieHeader(for: URL(string: "https://audio.test.local/public")!)
        XCTAssertEqual(wrongPathHeader, "")

        let validHeader = await vault.cookieHeader(for: URL(string: "https://audio.test.local/vip/1")!)
        XCTAssertEqual(validHeader, "sid=abc")

        // 强绑定 ownerID 的 Keychain 隔离
        await vault.setSecret("token-A", ownerID: "sourceA", key: "auth")
        let readByA = await vault.getSecret(ownerID: "sourceA", key: "auth")
        let readByB = await vault.getSecret(ownerID: "sourceB", key: "auth")
        XCTAssertEqual(readByA, "token-A")
        XCTAssertNil(readByB)
    }

    func testPureSwiftHTMLDocumentNodeSelectors() {
        let html = """
        <html><body>
          <div id="list" class="books">
            <a class="item hot" href="/book/42">凡人修仙传</a>
            <a class="item" href="/book/99">雪中悍刀行</a>
          </div>
        </body></html>
        """
        let doc = HTMLDocumentNode.parse(html: html, baseURL: "https://books.example.com/index.html")
        let items = doc.select("#list > a.item")
        XCTAssertEqual(items.size(), 2)
        XCTAssertEqual(items.first()?.text(), "凡人修仙传")
        XCTAssertEqual(items.first()?.absUrl("href"), "https://books.example.com/book/42")
        XCTAssertEqual(doc.selectFirst("a.hot")?.attr("href"), "/book/42")
    }

    private actor SlotSignalGate {
        private var enteredContinuation: CheckedContinuation<Void, Never>?
        private var entered = false
        private var releaseContinuation: CheckedContinuation<Void, Never>?
        private var released = false

        func markEntered() {
            entered = true
            enteredContinuation?.resume()
            enteredContinuation = nil
        }

        func waitUntilEntered() async {
            if entered { return }
            await withCheckedContinuation { cont in
                enteredContinuation = cont
            }
        }

        func waitUntilReleased() async {
            if released { return }
            await withCheckedContinuation { cont in
                releaseContinuation = cont
            }
        }

        func release() {
            released = true
            releaseContinuation?.resume()
            releaseContinuation = nil
        }
    }

    func testJSContextPoolReleasesSlotOnTaskCancellation() async throws {
        let pool = JSContextPool(maxSlots: 1)
        let gate = SlotSignalGate()
        let blocker = Task {
            try await pool.withSlot {
                await gate.markEntered()
                await gate.waitUntilReleased()
                return "done"
            }
        }
        await gate.waitUntilEntered()
        let activeWhileBlocked = await pool.currentActiveSlots
        XCTAssertEqual(activeWhileBlocked, 1)

        let cancelledWaiter = Task {
            try await pool.withSlot { "should-not-run" }
        }
        await Task.yield()
        cancelledWaiter.cancel()

        do {
            _ = try await cancelledWaiter.value
            XCTFail("Expected CancellationError")
        } catch is CancellationError {
            // Expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        await gate.release()
        let blockerResult = try await blocker.value
        XCTAssertEqual(blockerResult, "done")
        let active = await pool.currentActiveSlots
        XCTAssertEqual(active, 0)
    }
}
