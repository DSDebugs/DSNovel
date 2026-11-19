import Foundation
import JavaScriptCore
#if canImport(SwiftSoup)
import SwiftSoup
#endif

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

/// HTML DOM 节点与 Jsoup CSS 选择器桥接（优先使用 SwiftSoup 完整 HTML5/CSS3 引擎，并提供容错栈式 HTML5 解析器回退）
@objc final class JsElement: NSObject, JsElementExports {
    #if canImport(SwiftSoup)
    private let soupElement: SwiftSoup.Element?
    #endif

    let tagName: String
    let attributes: [String: String]
    var innerHTML: String
    let baseURL: String
    weak var parentNode: JsElement?
    var childNodes: [JsElement] = []
    private let isNullElement: Bool

    #if canImport(SwiftSoup)
    init(soupElement: SwiftSoup.Element?, baseURL: String = "") {
        self.soupElement = soupElement
        self.tagName = ((try? soupElement?.tagName()) ?? "").lowercased()
        self.attributes = [:]
        self.innerHTML = ""
        self.baseURL = baseURL
        self.isNullElement = (soupElement == nil)
        super.init()
    }
    #endif

    init(
        tagName: String = "",
        attributes: [String: String] = [:],
        innerHTML: String = "",
        baseURL: String = "",
        isNullElement: Bool = false
    ) {
        #if canImport(SwiftSoup)
        self.soupElement = nil
        #endif
        self.tagName = tagName.lowercased()
        self.attributes = attributes
        self.innerHTML = innerHTML
        self.baseURL = baseURL
        self.isNullElement = isNullElement
        super.init()
    }

    static func empty(baseURL: String = "") -> JsElement {
        #if canImport(SwiftSoup)
        return JsElement(soupElement: nil, baseURL: baseURL)
        #else
        return JsElement(baseURL: baseURL, isNullElement: true)
        #endif
    }

    static func parse(html: String, baseURL: String = "") -> JsElement {
        let cleanBase = (baseURL == "null" || baseURL == "undefined") ? "" : baseURL
        #if canImport(SwiftSoup)
        if let doc = try? SwiftSoup.parse(html, cleanBase) {
            return JsElement(soupElement: doc, baseURL: cleanBase)
        }
        return JsElement(soupElement: nil, baseURL: cleanBase)
        #else
        return HTMLTokenizer.parseDocument(html: html, baseURL: cleanBase)
        #endif
    }

    func exists() -> Bool {
        #if canImport(SwiftSoup)
        if soupElement != nil { return true }
        #endif
        return !isNullElement
    }

    func tag() -> String {
        #if canImport(SwiftSoup)
        if let el = soupElement {
            return (try? el.tagName()) ?? ""
        }
        #endif
        return tagName
    }

    func html() -> String {
        #if canImport(SwiftSoup)
        if let el = soupElement {
            return (try? el.html()) ?? ""
        }
        #endif
        return innerHTML
    }

    func outerHtml() -> String {
        #if canImport(SwiftSoup)
        if let el = soupElement {
            return (try? el.outerHtml()) ?? ""
        }
        #endif
        guard !isNullElement else { return "" }
        if tagName == "document" { return innerHTML }
        let attrStr = attributes.map { "\($0.key)=\"\($0.value)\"" }.joined(separator: " ")
        let open = attrStr.isEmpty ? "<\(tagName)>" : "<\(tagName) \(attrStr)>"
        return "\(open)\(innerHTML)</\(tagName)>"
    }

    func text() -> String {
        #if canImport(SwiftSoup)
        if let el = soupElement {
            return (try? el.text()) ?? ""
        }
        #endif
        guard !isNullElement else { return "" }
        return HTMLTokenizer.stripTagsAndDecodeEntities(innerHTML)
    }

    func ownText() -> String {
        #if canImport(SwiftSoup)
        if let el = soupElement {
            return (try? el.ownText()) ?? ""
        }
        #endif
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
        #if canImport(SwiftSoup)
        if let el = soupElement {
            let key = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if key.lowercased().hasPrefix("abs:") {
                let targetAttr = String(key.dropFirst(4))
                return absUrl(targetAttr)
            }
            return (try? el.attr(key)) ?? ""
        }
        #endif
        guard !isNullElement else { return "" }
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if key.hasPrefix("abs:") {
            return absUrl(String(key.dropFirst(4)))
        }
        for (k, v) in attributes where k.lowercased() == key {
            return HTMLTokenizer.decodeHTMLEntities(v)
        }
        return ""
    }

    func absUrl(_ name: String) -> String {
        #if canImport(SwiftSoup)
        if let el = soupElement {
            if let resolved = try? el.absUrl(name), !resolved.isEmpty {
                return resolved
            }
            let raw = ((try? el.attr(name)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return Self.resolveAbsoluteURL(raw: raw, baseURL: baseURL.isEmpty ? el.getBaseUri() : baseURL)
        }
        #endif
        let raw = attr(name).trimmingCharacters(in: .whitespacesAndNewlines)
        return Self.resolveAbsoluteURL(raw: raw, baseURL: baseURL)
    }

    static func resolveAbsoluteURL(raw: String, baseURL: String) -> String {
        guard !raw.isEmpty else { return "" }
        if raw.hasPrefix("http://") || raw.hasPrefix("https://") {
            return raw
        }
        if raw.hasPrefix("//") {
            if let base = Self.makeSafeURL(baseURL), let scheme = base.scheme {
                return "\(scheme):\(raw)"
            }
            return "https:\(raw)"
        }
        if let base = Self.makeSafeURL(baseURL) {
            if let resolved = URL(string: raw, relativeTo: base)?.absoluteURL {
                return resolved.absoluteString
            }
            if let encodedRaw = raw.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed),
               let resolved = URL(string: encodedRaw, relativeTo: base)?.absoluteURL {
                return resolved.absoluteString
            }
        }
        return raw
    }

    private static func makeSafeURL(_ str: String) -> URL? {
        let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "null", trimmed != "undefined" else { return nil }
        if let u = URL(string: trimmed), u.scheme != nil {
            return u
        }
        if let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed),
           let u = URL(string: encoded), u.scheme != nil {
            return u
        }
        return nil
    }

    func hasClass(_ name: String) -> Bool {
        #if canImport(SwiftSoup)
        if let el = soupElement {
            return (try? el.hasClass(name)) ?? false
        }
        #endif
        let classes = attr("class").split(whereSeparator: { $0.isWhitespace }).map(String.init)
        return classes.contains(name)
    }

    func children() -> [JsElement] {
        #if canImport(SwiftSoup)
        if let el = soupElement {
            return el.children().array().map { JsElement(soupElement: $0, baseURL: baseURL) }
        }
        #endif
        return childNodes
    }

    func parent() -> JsElement {
        #if canImport(SwiftSoup)
        if let el = soupElement {
            return JsElement(soupElement: el.parent(), baseURL: baseURL)
        }
        #endif
        return parentNode ?? JsElement.empty(baseURL: baseURL)
    }

    func byId(_ id: String) -> JsElement {
        #if canImport(SwiftSoup)
        if let el = soupElement {
            // McpGuide.md 第 7 节：byId(id) 按 id 在整个文档里找（优先取 ownerDocument）
            let root = el.ownerDocument() ?? el
            if let found = try? root.getElementById(id) {
                return JsElement(soupElement: found, baseURL: baseURL)
            }
            return JsElement(soupElement: nil, baseURL: baseURL)
        }
        #endif
        var root: JsElement = self
        while let p = root.parentNode {
            root = p
        }
        return root.first("#\(id)")
    }

    func first(_ selector: String) -> JsElement {
        #if canImport(SwiftSoup)
        if let el = soupElement {
            let found = try? el.select(selector).first()
            return JsElement(soupElement: found, baseURL: baseURL)
        }
        #endif
        return select(selector).first ?? JsElement.empty(baseURL: baseURL)
    }

    func select(_ selector: String) -> [JsElement] {
        #if canImport(SwiftSoup)
        if let el = soupElement {
            guard let elements = try? el.select(selector) else { return [] }
            return elements.array().map { JsElement(soupElement: $0, baseURL: baseURL) }
        }
        #endif
        guard !isNullElement else { return [] }
        let groups = Self.splitTopLevelSelectorGroups(selector)
        var combined: [JsElement] = []
        var seen = Set<ObjectIdentifier>()

        for group in groups where !group.isEmpty {
            let tokens = Self.tokenizeSelectorCombinators(group)
            var currentPool: [JsElement] = [self]
            var combinator: String = " "

            for token in tokens {
                if token == ">" || token == "+" || token == "~" {
                    combinator = token
                    continue
                }
                var nextPool: [JsElement] = []
                for node in currentPool {
                    let candidates: [JsElement]
                    switch combinator {
                    case ">":
                        candidates = node.childNodes
                    case "+":
                        if let p = node.parentNode,
                           let idx = p.childNodes.firstIndex(where: { $0 === node }),
                           idx + 1 < p.childNodes.count {
                            candidates = [p.childNodes[idx + 1]]
                        } else {
                            candidates = []
                        }
                    case "~":
                        if let p = node.parentNode,
                           let idx = p.childNodes.firstIndex(where: { $0 === node }),
                           idx + 1 < p.childNodes.count {
                            candidates = Array(p.childNodes[(idx + 1)...])
                        } else {
                            candidates = []
                        }
                    default:
                        candidates = node.allDescendants()
                    }
                    let matched = Self.filter(candidates: candidates, bySimpleSelector: token)
                    nextPool.append(contentsOf: matched)
                }
                currentPool = nextPool
                combinator = " "
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

    private static func splitTopLevelSelectorGroups(_ selector: String) -> [String] {
        var result: [String] = []
        var current = ""
        var parenDepth = 0
        var bracketDepth = 0
        for ch in selector {
            if ch == "(" { parenDepth += 1 }
            else if ch == ")" { parenDepth = max(0, parenDepth - 1) }
            else if ch == "[" { bracketDepth += 1 }
            else if ch == "]" { bracketDepth = max(0, bracketDepth - 1) }

            if ch == "," && parenDepth == 0 && bracketDepth == 0 {
                result.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                current = ""
            } else {
                current.append(ch)
            }
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { result.append(tail) }
        return result
    }

    private static func tokenizeSelectorCombinators(_ group: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var parenDepth = 0
        var bracketDepth = 0

        for ch in group {
            if ch == "(" { parenDepth += 1 }
            else if ch == ")" { parenDepth = max(0, parenDepth - 1) }
            else if ch == "[" { bracketDepth += 1 }
            else if ch == "]" { bracketDepth = max(0, bracketDepth - 1) }

            if parenDepth == 0 && bracketDepth == 0 && (ch == ">" || ch == "+" || ch == "~") {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { tokens.append(trimmed) }
                tokens.append(String(ch))
                current = ""
            } else if parenDepth == 0 && bracketDepth == 0 && ch.isWhitespace {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    tokens.append(trimmed)
                    current = ""
                }
            } else {
                current.append(ch)
            }
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { tokens.append(tail) }
        return tokens
    }

    private static func filter(candidates: [JsElement], bySimpleSelector rawToken: String) -> [JsElement] {
        var token = rawToken
        var eqIndex: Int?
        var gtIndex: Int?
        var ltIndex: Int?

        if let eqRange = token.range(of: ":eq("), token.hasSuffix(")") {
            let numStr = token[eqRange.upperBound..<token.index(before: token.endIndex)]
            eqIndex = Int(numStr.trimmingCharacters(in: .whitespaces))
            token = String(token[..<eqRange.lowerBound])
        } else if let gtRange = token.range(of: ":gt("), token.hasSuffix(")") {
            let numStr = token[gtRange.upperBound..<token.index(before: token.endIndex)]
            gtIndex = Int(numStr.trimmingCharacters(in: .whitespaces))
            token = String(token[..<gtRange.lowerBound])
        } else if let ltRange = token.range(of: ":lt("), token.hasSuffix(")") {
            let numStr = token[ltRange.upperBound..<token.index(before: token.endIndex)]
            ltIndex = Int(numStr.trimmingCharacters(in: .whitespaces))
            token = String(token[..<ltRange.lowerBound])
        } else if token.hasSuffix(":first") && !token.hasSuffix(":first-child") {
            eqIndex = 0
            token = String(token.dropLast(6))
        } else if token.hasSuffix(":last") && !token.hasSuffix(":last-child") {
            eqIndex = -1
            token = String(token.dropLast(5))
        }

        let matched = candidates.filter { matches(element: $0, simpleSelector: token) }
        if let idx = eqIndex {
            let resolvedIdx = idx >= 0 ? idx : matched.count + idx
            if resolvedIdx >= 0 && resolvedIdx < matched.count {
                return [matched[resolvedIdx]]
            }
            return []
        }
        if let gt = gtIndex {
            let start = max(0, gt + 1)
            return start < matched.count ? Array(matched[start...]) : []
        }
        if let lt = ltIndex {
            let end = min(matched.count, max(0, lt))
            return Array(matched[..<end])
        }
        return matched
    }

    private static func matches(element: JsElement, simpleSelector: String) -> Bool {
        if simpleSelector.isEmpty || simpleSelector == "*" { return true }
        var sel = simpleSelector

        if sel.hasSuffix(":first-child") {
            sel = String(sel.dropLast(12))
            if let p = element.parentNode, p.childNodes.first !== element { return false }
        }
        if sel.hasSuffix(":last-child") {
            sel = String(sel.dropLast(11))
            if let p = element.parentNode, p.childNodes.last !== element { return false }
        }
        if let nthRange = sel.range(of: ":nth-child("), sel.hasSuffix(")") {
            let numStr = sel[nthRange.upperBound..<sel.index(before: sel.endIndex)].trimmingCharacters(in: .whitespaces)
            sel = String(sel[..<nthRange.lowerBound])
            if let n = Int(numStr), let p = element.parentNode,
               let idx = p.childNodes.firstIndex(where: { $0 === element }) {
                if idx + 1 != n { return false }
            }
        }
        if let notRange = sel.range(of: ":not("), sel.hasSuffix(")") {
            let innerSel = String(sel[notRange.upperBound..<sel.index(before: sel.endIndex)])
            sel = String(sel[..<notRange.lowerBound])
            if matches(element: element, simpleSelector: innerSel) { return false }
        }
        if let containsRange = sel.range(of: ":contains("), sel.hasSuffix(")") {
            let sub = String(sel[containsRange.upperBound..<sel.index(before: sel.endIndex)])
                .trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
            sel = String(sel[..<containsRange.lowerBound])
            if !element.text().contains(sub) { return false }
        }

        while let openBracket = sel.firstIndex(of: "["),
              let closeBracket = sel[openBracket...].firstIndex(of: "]") {
            let inside = String(sel[sel.index(after: openBracket)..<closeBracket])
            sel.removeSubrange(openBracket...closeBracket)
            if !matchAttribute(element: element, expression: inside) {
                return false
            }
        }

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

        let parts = sel.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        let tagPart = parts.first ?? ""
        if !tagPart.isEmpty && tagPart != "*" && element.tagName != tagPart.lowercased() {
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
        let operators = ["*=", "^=", "$=", "!=", "~=", "="]
        for op in operators {
            if let range = clean.range(of: op) {
                let key = clean[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
                var val = clean[range.upperBound...].trimmingCharacters(in: .whitespaces)
                val = val.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
                let actual = element.attr(key)
                switch op {
                case "*=": return !val.isEmpty && actual.contains(val)
                case "^=": return !val.isEmpty && actual.hasPrefix(val)
                case "$=": return !val.isEmpty && actual.hasSuffix(val)
                case "!=": return actual != val
                case "~=": return actual.split(whereSeparator: { $0.isWhitespace }).map(String.init).contains(val)
                default: return actual == val
                }
            }
        }
        return !element.attr(clean).isEmpty
    }
}

/// 容错栈式 HTML5 解析器（自动忽略注释与脚本干扰，自动闭合未闭合的 li/p/dd/dt/td/tr 等标签）
enum HTMLTokenizer {
    private static let voidTags: Set<String> = [
        "img", "input", "br", "hr", "meta", "link", "source", "area", "base", "col", "embed", "param", "track", "wbr"
    ]

    private static let autoCloseSameTag: Set<String> = [
        "li", "p", "dt", "dd", "option", "tr", "td", "th"
    ]

    private static let commentRegex = try? NSRegularExpression(pattern: "<!--[\\s\\S]*?-->", options: [])
    private static let doctypeRegex = try? NSRegularExpression(pattern: "<!doctype[^>]*>", options: [.caseInsensitive])
    private static let scriptStyleBlockRegex = try? NSRegularExpression(pattern: "<(script|style)\\b[^>]*>[\\s\\S]*?</\\1>", options: [.caseInsensitive])
    private static let tagRegex = try? NSRegularExpression(pattern: "<(/?)([a-zA-Z][a-zA-Z0-9:-]*)([^>]*?)(/?)>", options: [.dotMatchesLineSeparators])
    private static let attrRegex = try? NSRegularExpression(pattern: "([a-zA-Z0-9_:-]+)\\s*(?:=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s\"'=<>`]+)))?", options: [])
    private static let stripScriptStyleRegex = try? NSRegularExpression(pattern: "<(script|style)[^>]*>[\\s\\S]*?</\\1>", options: [.caseInsensitive])
    private static let stripTagRegex = try? NSRegularExpression(pattern: "<[^>]+>", options: [])
    private static let numericEntityRegex = try? NSRegularExpression(pattern: "&#(x?[0-9a-fA-F]+);", options: [])
    private static let namedEntities: [(String, String)] = [
        ("&nbsp;", " "), ("&#160;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
        ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&ldquo;", "“"),
        ("&rdquo;", "”"), ("&hellip;", "…"), ("&mdash;", "—"), ("&middot;", "·")
    ]

    private static func replacing(_ text: String, with regex: NSRegularExpression?, template: String) -> String {
        guard let regex else { return text }
        let range = NSRange(location: 0, length: (text as NSString).length)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
    }

    static func parseDocument(html: String, baseURL: String) -> JsElement {
        let root = JsElement(tagName: "document", attributes: [:], innerHTML: html, baseURL: baseURL)
        guard !html.isEmpty else { return root }

        var cleaned = replacing(html, with: commentRegex, template: "")
        cleaned = replacing(cleaned, with: doctypeRegex, template: "")
        cleaned = replacing(cleaned, with: scriptStyleBlockRegex, template: "")

        let ns = cleaned as NSString
        let totalLength = ns.length
        guard let tagRegex else {
            return root
        }

        final class OpenEntry {
            let element: JsElement
            let innerStart: Int
            init(element: JsElement, innerStart: Int) {
                self.element = element
                self.innerStart = innerStart
            }
        }

        var stack: [OpenEntry] = [OpenEntry(element: root, innerStart: 0)]
        let matches = tagRegex.matches(in: cleaned, options: [], range: NSRange(location: 0, length: totalLength))

        for match in matches {
            let isClosing = !ns.substring(with: match.range(at: 1)).isEmpty
            let tagName = ns.substring(with: match.range(at: 2)).lowercased()
            let attrRaw = ns.substring(with: match.range(at: 3))
            let hasTrailingSlash = !ns.substring(with: match.range(at: 4)).isEmpty
            let tagStart = match.range.location
            let tagEnd = match.range.location + match.range.length

            if isClosing {
                if let matchIdx = stack.lastIndex(where: { $0.element.tagName == tagName && $0.element !== root }) {
                    while stack.count > matchIdx {
                        let popped = stack.removeLast()
                        let len = max(0, tagStart - popped.innerStart)
                        if popped.innerStart + len <= totalLength {
                            popped.element.innerHTML = ns.substring(with: NSRange(location: popped.innerStart, length: len))
                        }
                    }
                }
            } else {
                if autoCloseSameTag.contains(tagName),
                   let top = stack.last,
                   top.element.tagName == tagName {
                    let popped = stack.removeLast()
                    let len = max(0, tagStart - popped.innerStart)
                    if popped.innerStart + len <= totalLength {
                        popped.element.innerHTML = ns.substring(with: NSRange(location: popped.innerStart, length: len))
                    }
                }

                let parentEl = stack.last?.element ?? root
                let attrs = parseAttributes(attrRaw)
                let el = JsElement(tagName: tagName, attributes: attrs, innerHTML: "", baseURL: baseURL)
                el.parentNode = parentEl
                parentEl.childNodes.append(el)

                if !hasTrailingSlash && !voidTags.contains(tagName) {
                    stack.append(OpenEntry(element: el, innerStart: tagEnd))
                }
            }
        }

        while stack.count > 1 {
            let popped = stack.removeLast()
            let len = max(0, totalLength - popped.innerStart)
            if popped.innerStart + len <= totalLength {
                popped.element.innerHTML = ns.substring(with: NSRange(location: popped.innerStart, length: len))
            }
        }

        return root
    }

    static func parseElements(from html: String, baseURL: String, parent: JsElement, depth: Int = 0) -> [JsElement] {
        let doc = parseDocument(html: html, baseURL: baseURL)
        for ch in doc.childNodes {
            ch.parentNode = parent
        }
        return doc.childNodes
    }

    private static func parseAttributes(_ raw: String) -> [String: String] {
        var result: [String: String] = [:]
        guard !raw.isEmpty, let regex = attrRegex else { return result }
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
        // 快速路径：纯文本不含 HTML 标签与实体时跳过正则编译与实体解码
        if !html.contains("<") && !html.contains("&") {
            return html
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        }
        let withoutTags: String
        if html.contains("<") {
            let withoutScript = replacing(html, with: stripScriptStyleRegex, template: " ")
            withoutTags = replacing(withoutScript, with: stripTagRegex, template: " ")
        } else {
            withoutTags = html
        }
        let decoded = decodeHTMLEntities(withoutTags)
        return decoded
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static func decodeHTMLEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var s = text
        for (k, v) in namedEntities where s.contains(k) {
            s = s.replacingOccurrences(of: k, with: v)
        }
        if s.contains("&#"), let numRegex = numericEntityRegex {
            let ns = s as NSString
            let matches = numRegex.matches(in: s, range: NSRange(location: 0, length: ns.length)).reversed()
            for m in matches {
                let codeStr = ns.substring(with: m.range(at: 1))
                let code: UInt32?
                if codeStr.lowercased().hasPrefix("x") {
                    code = UInt32(codeStr.dropFirst(), radix: 16)
                } else {
                    code = UInt32(codeStr, radix: 10)
                }
                if let c = code, let scalar = UnicodeScalar(c) {
                    s = (s as NSString).replacingCharacters(in: m.range, with: String(scalar))
                }
            }
        }
        return s
    }
}
