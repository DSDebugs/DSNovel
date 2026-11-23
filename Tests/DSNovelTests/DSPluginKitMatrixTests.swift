import DSCore
import DSPluginKit
import Foundation
import XCTest

final class DSPluginKitMatrixTests: XCTestCase {

    func testSSRFBlocks_localhost() {
        XCTAssertTrue(SSRFGuard.isBlockedHost("localhost"))
    }

    func testSSRFBlocks_subLocalhost() {
        XCTAssertTrue(SSRFGuard.isBlockedHost("api.localhost"))
    }

    func testSSRFBlocks_dotLocal() {
        XCTAssertTrue(SSRFGuard.isBlockedHost("printer.local"))
    }

    func testSSRFBlocks_dotInternal() {
        XCTAssertTrue(SSRFGuard.isBlockedHost("meta.internal"))
    }

    func testSSRFBlocks_zeroIP() {
        XCTAssertTrue(SSRFGuard.isBlockedHost("0.0.0.0"))
    }

    func testSSRFBlocks_loopback127_1() {
        XCTAssertTrue(SSRFGuard.isBlockedHost("127.0.0.1"))
    }

    func testSSRFBlocks_loopback127_254() {
        XCTAssertTrue(SSRFGuard.isBlockedHost("127.255.255.254"))
    }

    func testSSRFBlocks_rfc1918_10() {
        XCTAssertTrue(SSRFGuard.isBlockedHost("10.20.30.40"))
    }

    func testSSRFBlocks_rfc1918_172_16() {
        XCTAssertTrue(SSRFGuard.isBlockedHost("172.16.0.1"))
    }

    func testSSRFBlocks_rfc1918_172_31() {
        XCTAssertTrue(SSRFGuard.isBlockedHost("172.31.255.254"))
    }

    func testSSRFBlocks_rfc1918_192_168() {
        XCTAssertTrue(SSRFGuard.isBlockedHost("192.168.0.100"))
    }

    func testSSRFBlocks_linkLocal169() {
        XCTAssertTrue(SSRFGuard.isBlockedHost("169.254.169.254"))
    }

    func testSSRFBlocks_cgnat100() {
        XCTAssertTrue(SSRFGuard.isBlockedHost("100.64.1.1"))
    }

    func testSSRFBlocks_ipv6Loopback() {
        XCTAssertTrue(SSRFGuard.isBlockedHost("::1"))
    }

    func testSSRFBlocks_ipv6ULA_fc() {
        XCTAssertTrue(SSRFGuard.isBlockedHost("fc00::1"))
    }

    func testSSRFBlocks_ipv6ULA_fd() {
        XCTAssertTrue(SSRFGuard.isBlockedHost("fd12:3456::1"))
    }

    func testSSRFBlocks_ipv6LinkLocal() {
        XCTAssertTrue(SSRFGuard.isBlockedHost("fe80::1"))
    }

    func testSSRFBlocks_ipv4MappedLoopback() {
        XCTAssertTrue(SSRFGuard.isBlockedHost("::ffff:127.0.0.1"))
    }

    func testSSRFAllows_ximalaya() {
        XCTAssertFalse(SSRFGuard.isBlockedHost("www.ximalaya.com"))
    }

    func testSSRFAllows_xmcdn() {
        XCTAssertFalse(SSRFGuard.isBlockedHost("audiopay.cos.tx.xmcdn.com"))
    }

    func testSSRFAllows_public172_15() {
        XCTAssertFalse(SSRFGuard.isBlockedHost("172.15.0.1"))
    }

    func testSSRFAllows_public172_32() {
        XCTAssertFalse(SSRFGuard.isBlockedHost("172.32.0.1"))
    }

    func testSSRFAllows_public100_63() {
        XCTAssertFalse(SSRFGuard.isBlockedHost("100.63.0.1"))
    }

    func testSSRFAllows_public100_128() {
        XCTAssertFalse(SSRFGuard.isBlockedHost("100.128.0.1"))
    }

    func testSSRFAllows_exampleOrg() {
        XCTAssertFalse(SSRFGuard.isBlockedHost("audio.example.org"))
    }

    func testHTMLParser_tagSelector() {
        let doc = HTMLDocumentNode.parse(html: "<div><p>One</p><p>Two</p></div>", baseURL: "https://books.example.com/")
        let list = doc.select("p")
        XCTAssertEqual(list.size(), 2)
        XCTAssertEqual(list.first()?.text() ?? "", "One")
    }

    func testHTMLParser_idSelector() {
        let doc = HTMLDocumentNode.parse(html: "<div id='main'><span>Hello</span></div>", baseURL: "https://books.example.com/")
        let list = doc.select("#main span")
        XCTAssertEqual(list.size(), 1)
        XCTAssertEqual(list.first()?.text() ?? "", "Hello")
    }

    func testHTMLParser_classSelector() {
        let doc = HTMLDocumentNode.parse(html: "<ul><li class='a b'>Item1</li><li class='a'>Item2</li></ul>", baseURL: "https://books.example.com/")
        let list = doc.select("li.a.b")
        XCTAssertEqual(list.size(), 1)
        XCTAssertEqual(list.first()?.text() ?? "", "Item1")
    }

    func testHTMLParser_directChild() {
        let doc = HTMLDocumentNode.parse(html: "<div class='p'><span>Direct</span><div><span>Nested</span></div></div>", baseURL: "https://books.example.com/")
        let list = doc.select(".p > span")
        XCTAssertEqual(list.size(), 1)
        XCTAssertEqual(list.first()?.text() ?? "", "Direct")
    }

    func testHTMLParser_commaUnion() {
        let doc = HTMLDocumentNode.parse(html: "<h1>Title</h1><h2>Sub</h2>", baseURL: "https://books.example.com/")
        let list = doc.select("h1, h2")
        XCTAssertEqual(list.size(), 2)
        XCTAssertEqual(list.first()?.text() ?? "", "Title")
    }

    func testHTMLParser_attrPresence() {
        let doc = HTMLDocumentNode.parse(html: "<a href='/1' data-vip>VIP</a><a href='/2'>Free</a>", baseURL: "https://books.example.com/")
        let list = doc.select("a[data-vip]")
        XCTAssertEqual(list.size(), 1)
        XCTAssertEqual(list.first()?.text() ?? "", "VIP")
    }

    func testHTMLParser_attrExact() {
        let doc = HTMLDocumentNode.parse(html: "<a data-k='yes'>Y</a><a data-k='no'>N</a>", baseURL: "https://books.example.com/")
        let list = doc.select("a[data-k=yes]")
        XCTAssertEqual(list.size(), 1)
        XCTAssertEqual(list.first()?.text() ?? "", "Y")
    }

    func testHTMLParser_attrContains() {
        let doc = HTMLDocumentNode.parse(html: "<a href='/audio/play/1'>P</a><a href='/book/2'>B</a>", baseURL: "https://books.example.com/")
        let list = doc.select("a[href*=play]")
        XCTAssertEqual(list.size(), 1)
        XCTAssertEqual(list.first()?.text() ?? "", "P")
    }

    func testHTMLParser_attrPrefix() {
        let doc = HTMLDocumentNode.parse(html: "<a href='https://cdn.a/1'>S</a><a href='/rel'>R</a>", baseURL: "https://books.example.com/")
        let list = doc.select("a[href^=https]")
        XCTAssertEqual(list.size(), 1)
        XCTAssertEqual(list.first()?.text() ?? "", "S")
    }

    func testHTMLParser_attrSuffix() {
        let doc = HTMLDocumentNode.parse(html: "<a href='/a.m4a'>M</a><a href='/a.html'>H</a>", baseURL: "https://books.example.com/")
        let list = doc.select("a[href$=.m4a]")
        XCTAssertEqual(list.size(), 1)
        XCTAssertEqual(list.first()?.text() ?? "", "M")
    }

    func testHTMLParser_entityDecoded() {
        let doc = HTMLDocumentNode.parse(html: "<p>A &amp; B &lt;C&gt;</p>", baseURL: "https://books.example.com/")
        let list = doc.select("p")
        XCTAssertEqual(list.size(), 1)
        XCTAssertEqual(list.first()?.text() ?? "", "A & B <C>")
    }

    func testHTMLParser_unclosedTagsFuzz() {
        let doc = HTMLDocumentNode.parse(html: "<div><p>Loose<span>Text</div>", baseURL: "https://books.example.com/")
        let list = doc.select("span")
        XCTAssertEqual(list.size(), 1)
        XCTAssertEqual(list.first()?.text() ?? "", "Text")
    }

    func testHTMLParser_voidImgTag() {
        let doc = HTMLDocumentNode.parse(html: "<div><img src='/c.jpg'><span>Cap</span></div>", baseURL: "https://books.example.com/")
        let list = doc.select("span")
        XCTAssertEqual(list.size(), 1)
        XCTAssertEqual(list.first()?.text() ?? "", "Cap")
    }

    func testHTMLParser_commentIgnored() {
        let doc = HTMLDocumentNode.parse(html: "<div><!-- hidden --><p>Visible</p></div>", baseURL: "https://books.example.com/")
        let list = doc.select("p")
        XCTAssertEqual(list.size(), 1)
        XCTAssertEqual(list.first()?.text() ?? "", "Visible")
    }

    func testHTMLParser_emptyHTMLSafe() {
        let doc = HTMLDocumentNode.parse(html: "", baseURL: "https://books.example.com/")
        let list = doc.select("div.missing")
        XCTAssertEqual(list.size(), 0)
        XCTAssertEqual(list.first()?.text() ?? "", "")
    }

    func testPreviewPolicyBlocksAllNetwork() {
        let policy = SourcePermissionPolicy(ownerID: "p", permissionMode: .compatApproved, allowNetwork: false)
        XCTAssertThrowsError(try policy.validate(url: URL(string: "https://www.ximalaya.com/")!))
    }
    func testDeclaredHostsWildcardMatchesSubdomain() {
        let policy = SourcePermissionPolicy(ownerID: "s", declaredHosts: ["*.example.com"])
        XCTAssertTrue(policy.matchesDeclaredHosts("api.example.com"))
        XCTAssertTrue(policy.matchesDeclaredHosts("example.com"))
        XCTAssertFalse(policy.matchesDeclaredHosts("badexample.com"))
    }
    func testBuiltinParserRejectsEmptyHosts() {
        let policy = SourcePermissionPolicy(ownerID: "bp", isBuiltinParser: true, declaredHosts: [])
        XCTAssertThrowsError(try policy.validate(url: URL(string: "https://www.ximalaya.com/")!))
    }
    func testRedirectStripsProxyAuthorization() {
        let out = HostHTTPClient.sanitizeHeadersForRedirect(
            headers: ["Proxy-Authorization": "Basic 123", "Accept": "*/*"],
            from: URL(string: "https://a.com/1")!,
            to: URL(string: "https://b.com/2")!
        )
        XCTAssertNil(out["Proxy-Authorization"])
        XCTAssertEqual(out["Accept"], "*/*")
    }
    func testCookieVaultClearDomainIsolation() async {
        let vault = CookieVault(inMemorySecretsOnly: true)
        let c1 = HTTPCookie(properties: [.domain: "a.test", .path: "/", .name: "k1", .value: "v1"])!
        let c2 = HTTPCookie(properties: [.domain: "b.test", .path: "/", .name: "k2", .value: "v2"])!
        await vault.setCookies([c1, c2])
        await vault.clearCookies(forDomain: "a.test")
        let h1 = await vault.cookieHeader(for: URL(string: "https://a.test/")!)
        let h2 = await vault.cookieHeader(for: URL(string: "https://b.test/")!)
        XCTAssertEqual(h1, "")
        XCTAssertEqual(h2, "k2=v2")
    }
    func testCookieVaultDeleteSecret() async {
        let vault = CookieVault(inMemorySecretsOnly: true)
        await vault.setSecret("val", ownerID: "s1", key: "k1")
        let before = await vault.getSecret(ownerID: "s1", key: "k1")
        XCTAssertEqual(before, "val")
        await vault.setSecret(nil, ownerID: "s1", key: "k1")
        let after = await vault.getSecret(ownerID: "s1", key: "k1")
        XCTAssertNil(after)
    }
    func testCookieVaultScopedKeyPreventsCollision() {
        XCTAssertNotEqual(CookieVault.scopedKey(ownerID: "a", key: "bc"), CookieVault.scopedKey(ownerID: "ab", key: "c"))
    }
    func testJSContextPoolLimitsConcurrency() async throws {
        let pool = JSContextPool(maxSlots: 2)
        let result = try await pool.withSlot { 42 }
        XCTAssertEqual(result, 42)
        let active = await pool.currentActiveSlots
        XCTAssertEqual(active, 0)
    }
    func testHTMLAbsURLResolution() {
        let doc = HTMLDocumentNode.parse(html: "<a href='/ch/1.mp3'>Play</a>", baseURL: "https://host.example/book/10/")
        XCTAssertEqual(doc.selectFirst("a")?.absUrl("href"), "https://host.example/ch/1.mp3")
        XCTAssertEqual(doc.selectFirst("a")?.attr("abs:href"), "https://host.example/ch/1.mp3")
    }
    func testSSRFRejectsNonHTTPSchemes() {
        for scheme in ["ftp://example.com/a", "javascript:alert(1)", "data:text/plain,hi"] {
            XCTAssertThrowsError(try SSRFGuard.validatePublicURL(URL(string: scheme)!))
        }
    }
}
