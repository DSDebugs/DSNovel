import DSCore
import Foundation
import JavaScriptCore

/// Jsoup 风格 JSExport 协议（兼容存量 ES5 书源调用 doc.select / attr / text / absUrl）
@objc public protocol HTMLNodeJSExport: JSExport {
    func select(_ css: String) -> HTMLNodeListJS
    func selectFirst(_ css: String) -> HTMLDocumentNode?
    func text() -> String
    func ownText() -> String
    func html() -> String
    func attr(_ name: String) -> String
    func absUrl(_ name: String) -> String
    func tagName() -> String
    func children() -> HTMLNodeListJS
}

@objc public protocol HTMLNodeListJSExport: JSExport {
    var length: Int { get }
    func size() -> Int
    func get(_ index: Int) -> HTMLDocumentNode?
    func first() -> HTMLDocumentNode?
    func last() -> HTMLDocumentNode?
    func text() -> String
    func attr(_ name: String) -> String
    func select(_ css: String) -> HTMLNodeListJS
}

/// 零外部依赖纯 Swift HTML5 DOM 节点与 CSS 选择器引擎（AUD-14：256 层深度限制、显式迭代栈、4096 单标签扫描上限）
/// 并发不变量：节点树仅在解析构建期于单线程内部写入 `childNodes`/`textContent`，解析完成后即视为只读快照并在所属 `JSContext` 串行队列内使用。
@objc public final class HTMLDocumentNode: NSObject, HTMLNodeJSExport, @unchecked Sendable {
    internal static let maxDepth = 256
    private static let maxTagScanLength = 4096
    internal static let voidTags: Set<String> = ["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr"]
    private static let tagAttrRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"([a-zA-Z0-9_:\-]+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+)))?"#
    )

    public let tag: String
    public let attributes: [String: String]
    public let baseURL: String
    public var childNodes: [HTMLDocumentNode] = []
    public var textContent: String = ""

    public init(tag: String, attributes: [String: String] = [:], baseURL: String = "") {
        self.tag = tag.lowercased()
        self.attributes = attributes
        self.baseURL = baseURL
    }

    public static func parse(html: String, baseURL: String = "") -> HTMLDocumentNode {
        let root = HTMLDocumentNode(tag: "#root", attributes: [:], baseURL: baseURL)
        var stack: [HTMLDocumentNode] = [root]

        func appendRawText(_ raw: String) {
            guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            let decoded = DSCrypto.htmlDecode(raw)
            if let parent = stack.last, let prev = parent.childNodes.last, prev.tag == "#text" {
                prev.textContent += decoded
            } else {
                let textNode = HTMLDocumentNode(tag: "#text", baseURL: baseURL)
                textNode.textContent = decoded
                stack.last?.childNodes.append(textNode)
            }
        }

        let scanner = html
        var idx = scanner.startIndex
        while idx < scanner.endIndex {
            guard let lt = scanner[idx...].firstIndex(of: "<") else {
                appendRawText(String(scanner[idx...]))
                break
            }
            if lt > idx { appendRawText(String(scanner[idx..<lt])) }
            let afterLT = scanner.index(after: lt)
            if afterLT == scanner.endIndex { appendRawText("<"); break }
            let nextCh = scanner[afterLT]
            if !(nextCh.isASCII && (nextCh.isLetter || nextCh == "/" || nextCh == "!" || nextCh == "?")) {
                appendRawText("<"); idx = afterLT; continue
            }
            if scanner[lt...].hasPrefix("<!--") {
                let commentStart = scanner.index(lt, offsetBy: 4, limitedBy: scanner.endIndex) ?? scanner.endIndex
                if let endRange = scanner[commentStart...].range(of: "-->") { idx = endRange.upperBound; continue }
                break
            }
            guard let gt = findTagCloseIndex(in: scanner, from: lt) else { appendRawText("<"); idx = afterLT; continue }
            let token = String(scanner[afterLT..<gt]).trimmingCharacters(in: .whitespacesAndNewlines)
            idx = scanner.index(after: gt)

            if token.isEmpty || token.hasPrefix("!") || token.hasPrefix("?") { continue }
            if token.hasPrefix("/") {
                let closeTag = token.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if let matchIdx = stack.lastIndex(where: { $0.tag == closeTag }), matchIdx > 0 {
                    stack.removeSubrange(matchIdx..<stack.count)
                }
                continue
            }
            let selfClosing = token.hasSuffix("/")
            let cleanToken = selfClosing ? String(token.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines) : token
            let (tagName, attrs) = parseTagHeader(cleanToken)
            guard !tagName.isEmpty else { continue }
            let elem = HTMLDocumentNode(tag: tagName, attributes: attrs, baseURL: baseURL)
            stack.last?.childNodes.append(elem)

            if !selfClosing && (tagName == "script" || tagName == "style") {
                if let closeRange = scanner[idx...].range(of: "</\(tagName)", options: .caseInsensitive) {
                    let rawBody = String(scanner[idx..<closeRange.lowerBound])
                    if !rawBody.isEmpty {
                        let rawNode = HTMLDocumentNode(tag: "#text", baseURL: baseURL)
                        rawNode.textContent = rawBody
                        elem.childNodes.append(rawNode)
                    }
                    idx = scanner[closeRange.upperBound...].firstIndex(of: ">").map { scanner.index(after: $0) } ?? scanner.endIndex
                } else { idx = scanner.endIndex }
                continue
            }
            // AUD-14：限制嵌套深度不超过 maxDepth (256)
            if !selfClosing && !voidTags.contains(tagName) && stack.count < Self.maxDepth {
                stack.append(elem)
            }
        }
        return root
    }

    /// AUD-14：单标签扫描上限 4096 字符，无引号遇新 `<` 立即中止，杜绝 O(n^2) 退化
    private static func findTagCloseIndex(in scanner: String, from lt: String.Index) -> String.Index? {
        let start = scanner.index(after: lt)
        var cur = start
        var quote: Character?
        var expectQuote = false
        var scanned = 0
        while cur < scanner.endIndex && scanned < maxTagScanLength {
            let ch = scanner[cur]
            if let q = quote {
                if ch == q { quote = nil }
            } else if ch == ">" {
                return cur
            } else if ch == "<" {
                return nil
            } else if ch == "=" {
                expectQuote = true
            } else if expectQuote {
                if ch == "\"" || ch == "'" {
                    quote = ch
                    expectQuote = false
                } else if !ch.isWhitespace {
                    expectQuote = false
                }
            }
            cur = scanner.index(after: cur)
            scanned += 1
        }
        return nil
    }

    public func select(_ css: String) -> HTMLNodeListJS {
        let groups = css.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        var results: [HTMLDocumentNode] = []
        var seen: Set<ObjectIdentifier> = []
        for group in groups {
            for node in matchSelectorChain(group, from: self) {
                if seen.insert(ObjectIdentifier(node)).inserted { results.append(node) }
            }
        }
        return HTMLNodeListJS(nodes: results)
    }

    public func selectFirst(_ css: String) -> HTMLDocumentNode? { select(css).first() }

    public func text() -> String {
        var parts: [String] = []
        appendText(into: &parts)
        return parts.joined(separator: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// AUD-14：显式数组栈迭代遍历收集文本，消除深层 DOM 栈溢出
    private func appendText(into parts: inout [String]) {
        var stack: [HTMLDocumentNode] = [self]
        while let node = stack.popLast() {
            if node.tag == "script" || node.tag == "style" { continue }
            if node.tag == "#text" {
                if !node.textContent.isEmpty { parts.append(node.textContent) }
                continue
            }
            for child in node.childNodes.reversed() {
                stack.append(child)
            }
        }
    }

    public func ownText() -> String {
        childNodes.filter { $0.tag == "#text" }.map(\.textContent).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func html() -> String {
        if tag == "#text" { return Self.escapeHTMLText(textContent) }
        var out = ""
        for child in childNodes {
            out += child.serializeOuterHTML()
        }
        return out
    }

    /// AUD-14：显式数组栈迭代序列化 OuterHTML，消除深层 DOM 栈溢出
    private func serializeOuterHTML() -> String {
        enum Frame {
            case enter(HTMLDocumentNode)
            case close(String)
        }
        var out = ""
        var stack: [Frame] = [.enter(self)]
        while let frame = stack.popLast() {
            switch frame {
            case .close(let closingTag):
                out += "</\(closingTag)>"
            case .enter(let node):
                if node.tag == "#text" {
                    out += Self.escapeHTMLText(node.textContent)
                } else if node.tag == "#root" {
                    for child in node.childNodes.reversed() {
                        stack.append(.enter(child))
                    }
                } else {
                    out += "<\(node.tag)"
                    if !node.attributes.isEmpty {
                        for key in node.attributes.keys.sorted() {
                            out += " \(key)=\"\(Self.escapeHTMLAttr(node.attributes[key] ?? ""))\""
                        }
                    }
                    out += ">"
                    if !Self.voidTags.contains(node.tag) {
                        stack.append(.close(node.tag))
                        for child in node.childNodes.reversed() {
                            stack.append(.enter(child))
                        }
                    }
                }
            }
        }
        return out
    }

    private static func escapeHTMLText(_ raw: String) -> String {
        raw.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func escapeHTMLAttr(_ raw: String) -> String {
        escapeHTMLText(raw).replacingOccurrences(of: "\"", with: "&quot;")
    }

    public func attr(_ name: String) -> String {
        let key = name.lowercased()
        if key.hasPrefix("abs:") { return absUrl(String(key.dropFirst(4))) }
        return attributes[key] ?? ""
    }

    public func absUrl(_ name: String) -> String {
        let raw = attr(name).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return "" }
        if raw.hasPrefix("http://") || raw.hasPrefix("https://") { return raw }
        if raw.hasPrefix("//") {
            let scheme = URL(string: baseURL)?.scheme ?? "https"
            return "\(scheme):\(raw)"
        }
        guard let base = URL(string: baseURL) else { return raw }
        if let resolved = URL(string: raw, relativeTo: base)?.absoluteURL {
            return resolved.absoluteString
        }
        if let encoded = raw.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed),
           let resolved = URL(string: encoded, relativeTo: base)?.absoluteURL {
            return resolved.absoluteString
        }
        return raw
    }

    public func tagName() -> String { tag }
    public func children() -> HTMLNodeListJS { HTMLNodeListJS(nodes: childNodes.filter { $0.tag != "#text" }) }

    private static func parseTagHeader(_ header: String) -> (String, [String: String]) {
        var idx = header.startIndex
        while idx < header.endIndex && !header[idx].isWhitespace { idx = header.index(after: idx) }
        let tagName = String(header[..<idx]).lowercased()
        var attrs: [String: String] = [:]
        let rest = String(header[idx...])
        if let regex = Self.tagAttrRegex {
            let ns = rest as NSString
            for m in regex.matches(in: rest, range: NSRange(location: 0, length: ns.length)) {
                let key = ns.substring(with: m.range(at: 1)).lowercased()
                var val = ""
                for g in 2...4 where m.range(at: g).location != NSNotFound {
                    val = ns.substring(with: m.range(at: g))
                    break
                }
                attrs[key] = DSCrypto.htmlDecode(val)
            }
        }
        return (tagName, attrs)
    }
}
