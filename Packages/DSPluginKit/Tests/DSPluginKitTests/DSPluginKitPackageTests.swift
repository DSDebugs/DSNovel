import DSCore
import DSPluginKit
import Foundation
import XCTest

final class DSPluginKitPackageTests: XCTestCase {
    func testSSRFGuardBlocksPrivateAndAllowsPublicHosts() {
        XCTAssertTrue(SSRFGuard.isBlockedHost("127.0.0.1"))
        XCTAssertTrue(SSRFGuard.isBlockedHost("10.0.0.5"))
        XCTAssertTrue(SSRFGuard.isBlockedHost("169.254.169.254"))
        XCTAssertTrue(SSRFGuard.isBlockedHost("localhost"))
        XCTAssertFalse(SSRFGuard.isBlockedHost("www.ximalaya.com"))
    }

    func testSourcePermissionPolicyDeclaredHostsEnforcement() {
        let policy = SourcePermissionPolicy(
            ownerID: "parser-xm",
            isBuiltinParser: true,
            permissionMode: .declaredHosts,
            declaredHosts: ["ximalaya.com"]
        )
        XCTAssertNoThrow(try policy.validate(url: URL(string: "https://mobile.ximalaya.com/api")!))
        XCTAssertThrowsError(try policy.validate(url: URL(string: "https://evil.example.org/steal")!))
    }

    func testHTMLDocumentNodeParsingAndInnerHTML() {
        let html = """
        <div></span><p class="intro">Hello <b>World</b></p><!-- <p>ignored</p> --><script>var x = 1 < 2;</script></div>
        """
        let doc = HTMLDocumentNode.parse(html: html, baseURL: "https://example.com/")
        let p = doc.selectFirst("div > p.intro")
        XCTAssertEqual(p?.text(), "Hello World")
        XCTAssertEqual(p?.html(), "Hello <b>World</b>")
        XCTAssertEqual(doc.select("p").size(), 1)
    }

    func testSourceContractAdapterDecodesBookDetailContiguously() {
        let fallback = BookSummaryDTO(id: "s::1", sourceID: "s", bookURL: "https://e.com/b", title: "原书名")
        let json = """
        {"title":"新书名","chapters":[{"title":"缺URL"},{"title":"第一章","url":"https://e.com/1"},{"title":"第二章","url":"https://e.com/2"}]}
        """
        let detail = SourceContractAdapter.decodeBookDetail(json, fallback: fallback)
        XCTAssertEqual(detail.summary.title, "新书名")
        XCTAssertEqual(detail.chapters.map(\.index), [0, 1])
        XCTAssertEqual(detail.summary.totalChapters, 2)
    }

    func testCrossDomainRedirectSanitizesSensitiveHeaders() {
        let headers = ["Cookie": "sid=1", "Authorization": "Bearer abc", "Accept": "application/json"]
        let stripped = HostHTTPClient.sanitizeHeadersForRedirect(
            headers: headers,
            from: URL(string: "https://a.example.com/1")!,
            to: URL(string: "https://b.example.net/2")!
        )
        XCTAssertNil(stripped["Cookie"])
        XCTAssertNil(stripped["Authorization"])
        XCTAssertEqual(stripped["Accept"], "application/json")
    }
}
