import Foundation
import JavaScriptCore

@objc protocol JsElementExports: JSExport {
    func exists() -> Bool
    func text() -> String
    func ownText() -> String
    @objc(attr:) func attr(_ name: String) -> String
    @objc(absUrl:) func absUrl(_ name: String) -> String
    func html() -> String
    func outerHtml() -> String
    func tag() -> String
    @objc(hasClass:) func hasClass(_ name: String) -> Bool
    @objc(first:) func first(_ selector: String) -> JsElement
    @objc(select:) func select(_ selector: String) -> [JsElement]
    func children() -> [JsElement]
    func parent() -> JsElement
    @objc(byId:) func byId(_ id: String) -> JsElement
}

/// 零第三方依赖的轻量 HTML DOM 节点与 CSS 选择器引擎（100% 兼容 SSTS 插件的 doc.select / .first / .absUrl / .attr / .text 链式调用）
@objc final class JsElement: NSObject, JsElementExports {
    let tagName: String
    let attributes: [String: String]
    let innerHTML: String
    let baseURL: String
    weak var parentNode: JsElement?
    private(set) var childNodes: [JsElement] = []
    private let isNullElement: Bool

    init(
        tagName: String = "",
        attributes: [String: String] = [:],
        innerHTML: String = "",
        baseURL: String = "",
        isNullElement: Bool = false
    ) {
        self.tagName = tagName.lowercased()
        self.attributes = attributes
        self.innerHTML = innerHTML
        self.baseURL = baseURL
        self.isNullElement = isNullElement
        super.init()
    }

    static func empty(baseURL: String = "") -> JsElement {
        JsElement(isNullElement: true)
    }

    static func parse(html: String, baseURL: String = "") -> JsElement {
        let root = JsElement(tagName: "document", attributes: [:], innerHTML: html, baseURL: baseURL)
        root.childNodes = HTMLTokenizer.parseElements(from: html, baseURL: baseURL, parent: root)
        return root
    }

    func exists() -> Bool {
        !isNullElement
    }

    func tag() -> String {
        tagName
    }

    func html() -> String {
        innerHTML
    }

    func outerHtml() -> String {
        guard !isNullElement else { return "" }
        if tagName == "document" { return innerHTML }
        let attrStr = attributes.map { "\($0.key)=\"\($0.value)\"" }.joined(separator: " ")
        let open = attrStr.isEmpty ? "<\(tagName)>" : "<\(tagName) \(attrStr)>"
        return "\(open)\(innerHTML)</\(tagName)>"
    }

    func text() -> String {
        guard !isNullElement else { return "" }
        return HTMLTokenizer.stripTagsAndDecodeEntities(innerHTML)
    }

    func ownText() -> String {
        guard !isNullElement else { return "" }
        var stripped = innerHTML
        for child in childNodes {
            let childOuter = child.outerHtml()
            if !childOuter.isEmpty {
                stripped = stripped.replacingOccurrences(of: childOuter, with: " ")
            }
        }
        return HTMLTokenizer.stripTagsAndDecodeEntities(stripped)
    }

    func attr(_ name: String) -> String {
        guard !isNullElement else { return "" }
        let key = name.lowercased()
        if key == "abs:href" { return absUrl("href") }
        if key == "abs:src" { return absUrl("src") }
        for (k, v) in attributes where k.lowercased() == key {
            return HTMLTokenizer.decodeHTMLEntities(v)
        }
        return ""
    }

    func absUrl(_ name: String) -> String {
        let raw = attr(name).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return "" }
        if raw.hasPrefix("http://") || raw.hasPrefix("https://") {
            return raw
        }
        if raw.hasPrefix("//") {
            if let base = URL(string: baseURL), let scheme = base.scheme {
                return "\(scheme):\(raw)"
            }
            return "https:\(raw)"
        }
        if let base = URL(string: baseURL), let resolved = URL(string: raw, relativeTo: base)?.absoluteURL {
            return resolved.absoluteString
        }
        return raw
    }

    func hasClass(_ name: String) -> Bool {
        let classes = attr("class").split(whereSeparator: { $0.isWhitespace }).map(String.init)
        return classes.contains(name)
    }

    func children() -> [JsElement] {
        childNodes
    }

    func parent() -> JsElement {
        parentNode ?? JsElement.empty(baseURL: baseURL)
    }

    func byId(_ id: String) -> JsElement {
        first("#\(id)")
    }

    func first(_ selector: String) -> JsElement {
        select(selector).first ?? JsElement.empty(baseURL: baseURL)
    }

    func select(_ selector: String) -> [JsElement] {
        guard !isNullElement else { return [] }
        let groups = selector.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        var combined: [JsElement] = []
        var seen = Set<ObjectIdentifier>()

        for group in groups where !group.isEmpty {
            let tokens = group
                .replacingOccurrences(of: ">", with: " > ")
                .split(whereSeparator: { $0.isWhitespace })
                .map(String.init)
            var currentPool: [JsElement] = [self]
            var directChildOnly = false

            for token in tokens {
                if token == ">" {
                    directChildOnly = true
                    continue
                }
                var nextPool: [JsElement] = []
                for node in currentPool {
                    let candidates = directChildOnly ? node.childNodes : node.allDescendants()
                    let matched = Self.filter(candidates: candidates, bySimpleSelector: token)
                    nextPool.append(contentsOf: matched)
                }
                currentPool = nextPool
                directChildOnly = false
            }

            for el in currentPool {
                let oid = ObjectIdentifier(el)
                if !seen.contains(oid) {
                    seen.insert(oid)
                    combined.append(el)
                }
            }
        }
        return combined
    }

    private func allDescendants() -> [JsElement] {
        var result: [JsElement] = []
        var stack: [JsElement] = childNodes.reversed()
        while let current = stack.popLast() {
            result.append(current)
            if !current.childNodes.isEmpty {
                stack.append(contentsOf: current.childNodes.reversed())
            }
        }
        return result
    }

    private static func filter(candidates: [JsElement], bySimpleSelector rawToken: String) -> [JsElement] {
        var token = rawToken
        var eqIndex: Int?
        if let eqRange = token.range(of: ":eq("), token.hasSuffix(")") {
            let numStr = token[eqRange.upperBound..<token.index(before: token.endIndex)]
            eqIndex = Int(numStr)
            token = String(token[..<eqRange.lowerBound])
        } else if token.hasSuffix(":first-child") || token.hasSuffix(":first") {
            eqIndex = 0
            token = token.replacingOccurrences(of: ":first-child", with: "").replacingOccurrences(of: ":first", with: "")
        }

        let matched = candidates.filter { matches(element: $0, simpleSelector: token) }
        if let idx = eqIndex {
            let resolvedIdx = idx >= 0 ? idx : matched.count + idx
            if resolvedIdx >= 0 && resolvedIdx < matched.count {
                return [matched[resolvedIdx]]
            }
            return []
        }
        return matched
    }

    private static func matches(element: JsElement, simpleSelector: String) -> Bool {
        if simpleSelector.isEmpty || simpleSelector == "*" { return true }
        var sel = simpleSelector

        // 属性选择器 [attr=val] / [attr*=val] / [attr^=val] / [attr$=val] / [attr]
        while let openBracket = sel.firstIndex(of: "["),
              let closeBracket = sel[openBracket...].firstIndex(of: "]") {
            let inside = String(sel[sel.index(after: openBracket)..<closeBracket])
            sel.removeSubrange(openBracket...closeBracket)
            if !matchAttribute(element: element, expression: inside) {
                return false
            }
        }

        // ID 选择器 #id
        var requiredID: String?
        if let hashIdx = sel.firstIndex(of: "#") {
            let afterHash = sel[sel.index(after: hashIdx)...]
            let endIdx = afterHash.firstIndex(of: ".") ?? afterHash.endIndex
            requiredID = String(afterHash[..<endIdx])
            sel.removeSubrange(hashIdx..<endIdx)
        }
        if let reqID = requiredID, element.attr("id") != reqID {
            return false
        }

        // 类选择器 .class1.class2
        let parts = sel.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        let tagPart = parts.first ?? ""
        if !tagPart.isEmpty && element.tagName != tagPart.lowercased() {
            return false
        }
        if parts.count > 1 {
            for cls in parts.dropFirst() where !cls.isEmpty {
                if !element.hasClass(cls) {
                    return false
                }
            }
        }
        return true
    }

    private static func matchAttribute(element: JsElement, expression: String) -> Bool {
        let clean = expression.trimmingCharacters(in: .whitespaces)
        let operators = ["*=", "^=", "$=", "="]
        for op in operators {
            if let range = clean.range(of: op) {
                let key = clean[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
                var val = clean[range.upperBound...].trimmingCharacters(in: .whitespaces)
                val = val.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
                let actual = element.attr(key)
                switch op {
                case "*=": return actual.contains(val)
                case "^=": return actual.hasPrefix(val)
                case "$=": return actual.hasSuffix(val)
                default: return actual == val
                }
            }
        }
        return !element.attr(clean).isEmpty
    }
}

enum HTMLTokenizer {
    private static let voidTags: Set<String> = [
        "img", "input", "br", "hr", "meta", "link", "source", "area", "base", "col", "embed", "param", "track", "wbr"
    ]

    static func parseElements(from html: String, baseURL: String, parent: JsElement, depth: Int = 0) -> [JsElement] {
        guard depth < 18, !html.isEmpty else { return [] }
        var elements: [JsElement] = []
        let ns = html as NSString
        let length = ns.length
        var cursor = 0

        let openTagRegex = try? NSRegularExpression(
            pattern: "<([a-zA-Z][a-zA-Z0-9:-]*)([^>]*?)(/?)>",
            options: [.dotMatchesLineSeparators]
        )
        guard let regex = openTagRegex else { return [] }

        while cursor < length {
            let searchRange = NSRange(location: cursor, length: length - cursor)
            guard let match = regex.firstMatch(in: html, options: [], range: searchRange) else {
                break
            }
            let tagName = ns.substring(with: match.range(at: 1)).lowercased()
            let attrRaw = ns.substring(with: match.range(at: 2))
            let selfClosingSlash = ! ns.substring(with: match.range(at: 3)).isEmpty
            let attrs = parseAttributes(attrRaw)
            let afterOpenTag = match.range.location + match.range.length

            if selfClosingSlash || voidTags.contains(tagName) {
                let el = JsElement(tagName: tagName, attributes: attrs, innerHTML: "", baseURL: baseURL)
                el.parentNode = parent
                elements.append(el)
                cursor = afterOpenTag
                continue
            }

            if let (inner, nextCursor) = findBalancedClosingTag(in: ns, tagName: tagName, startOffset: afterOpenTag) {
                let el = JsElement(tagName: tagName, attributes: attrs, innerHTML: inner, baseURL: baseURL)
                el.parentNode = parent
                if tagName != "script" && tagName != "style" && inner.contains("<") {
                    el.childNodes = parseElements(from: inner, baseURL: baseURL, parent: el, depth: depth + 1)
                }
                elements.append(el)
                cursor = nextCursor
            } else {
                cursor = afterOpenTag
            }
        }
        return elements
    }

    private static func findBalancedClosingTag(in ns: NSString, tagName: String, startOffset: Int) -> (String, Int)? {
        let pattern = "<(/?)" + NSRegularExpression.escapedPattern(for: tagName) + "\\b[^>]*>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        var depth = 1
        var searchPos = startOffset
        let totalLen = ns.length

        while searchPos < totalLen {
            let r = NSRange(location: searchPos, length: totalLen - searchPos)
            guard let m = regex.firstMatch(in: ns as String, options: [], range: r) else {
                break
            }
            let isClose = !ns.substring(with: m.range(at: 1)).isEmpty
            let fullTag = ns.substring(with: m.range)
            if isClose {
                depth -= 1
                if depth == 0 {
                    let innerRange = NSRange(location: startOffset, length: m.range.location - startOffset)
                    let inner = ns.substring(with: innerRange)
                    return (inner, m.range.location + m.range.length)
                }
            } else if !fullTag.hasSuffix("/>") {
                depth += 1
            }
            searchPos = m.range.location + m.range.length
        }
        return nil
    }

    private static func parseAttributes(_ raw: String) -> [String: String] {
        var result: [String: String] = [:]
        let pattern = "([a-zA-Z0-9_:-]+)\\s*(?:=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s\"'=<>`]+)))?"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return result }
        let ns = raw as NSString
        let matches = regex.matches(in: raw, options: [], range: NSRange(location: 0, length: ns.length))
        for m in matches {
            let key = ns.substring(with: m.range(at: 1)).lowercased()
            var val = ""
            if m.range(at: 2).location != NSNotFound {
                val = ns.substring(with: m.range(at: 2))
            } else if m.range(at: 3).location != NSNotFound {
                val = ns.substring(with: m.range(at: 3))
            } else if m.range(at: 4).location != NSNotFound {
                val = ns.substring(with: m.range(at: 4))
            }
            result[key] = val
        }
        return result
    }

    static func stripTagsAndDecodeEntities(_ html: String) -> String {
        guard !html.isEmpty else { return "" }
        let withoutScript = html.replacingOccurrences(
            of: "<(script|style)[^>]*>[\\s\\S]*?</\\1>",
            with: " ",
            options: [.regularExpression, .caseInsensitive]
        )
        let withoutTags = withoutScript.replacingOccurrences(
            of: "<[^>]+>",
            with: " ",
            options: .regularExpression
        )
        let decoded = decodeHTMLEntities(withoutTags)
        return decoded
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static func decodeHTMLEntities(_ text: String) -> String {
        var s = text
        let entities: [(String, String)] = [
            ("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&ldquo;", "“"),
            ("&rdquo;", "”"), ("&hellip;", "…"), ("&mdash;", "—")
        ]
        for (k, v) in entities where s.contains(k) {
            s = s.replacingOccurrences(of: k, with: v)
        }
        return s
    }
}
