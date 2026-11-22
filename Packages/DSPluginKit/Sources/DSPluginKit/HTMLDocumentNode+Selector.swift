import Foundation
import JavaScriptCore

extension HTMLDocumentNode {
    // MARK: - CSS 选择器匹配（AUD-14 显式迭代栈 + AUD-91 引号感知属性选择器）

    internal func tokenizeSelectorChain(_ chain: String) -> [String] {
        var tokens: [String] = []
        var buf = ""
        var depth = 0
        var quote: Character?
        for ch in chain {
            if let q = quote { buf.append(ch); if ch == q { quote = nil }; continue }
            if depth > 0 {
                buf.append(ch)
                if ch == "\"" || ch == "'" { quote = ch }
                else if ch == "]" { depth -= 1 }
                else if ch == "[" { depth += 1 }
                continue
            }
            if ch == "[" { depth += 1; buf.append(ch) }
            else if ch == ">" { if !buf.isEmpty { tokens.append(buf); buf = "" }; tokens.append(">") }
            else if ch.isWhitespace { if !buf.isEmpty { tokens.append(buf); buf = "" } }
            else { buf.append(ch) }
        }
        if !buf.isEmpty { tokens.append(buf) }
        return tokens
    }

    internal func matchSelectorChain(_ chain: String, from root: HTMLDocumentNode) -> [HTMLDocumentNode] {
        let tokens = tokenizeSelectorChain(chain)
        guard !tokens.isEmpty else { return [] }

        var currentSet: [HTMLDocumentNode] = [root]
        var directChildOnly = false
        for token in tokens {
            if token == ">" {
                directChildOnly = true
                continue
            }
            var nextSet: [HTMLDocumentNode] = []
            var seen: Set<ObjectIdentifier> = []
            for base in currentSet {
                var candidates: [HTMLDocumentNode] = []
                if directChildOnly {
                    candidates = base.childNodes.filter { $0.tag != "#text" }
                } else {
                    allDescendants(of: base, into: &candidates)
                }
                for c in candidates where matchesSimpleSelector(c, selector: token) {
                    if seen.insert(ObjectIdentifier(c)).inserted { nextSet.append(c) }
                }
            }
            currentSet = nextSet
            directChildOnly = false
        }
        return currentSet
    }

    /// AUD-14：显式数组栈 + inout 收集全部后代元素节点，消除深层 DOM 递归栈溢出与中间数组拷贝
    internal func allDescendants(of node: HTMLDocumentNode, into out: inout [HTMLDocumentNode]) {
        var stack: [HTMLDocumentNode] = []
        for child in node.childNodes.reversed() where child.tag != "#text" {
            stack.append(child)
        }
        while let cur = stack.popLast() {
            out.append(cur)
            for child in cur.childNodes.reversed() where child.tag != "#text" {
                stack.append(child)
            }
        }
    }

    /// AUD-91：引号感知扫描提取 `[...]` 属性表达式，正确支持属性值内包含 `]`
    internal func matchesSimpleSelector(_ node: HTMLDocumentNode, selector: String) -> Bool {
        if selector == "*" { return true }
        let (remaining, attrExprs) = extractAttributeSelectors(from: selector)
        for expr in attrExprs {
            if !matchesAttributeExpr(node, expr: expr) { return false }
        }
        var tagFilter: String?
        var idFilter: String?
        var classFilters: [String] = []
        var buffer = ""
        var mode: Character = "t"
        for ch in remaining {
            if ch == "#" || ch == "." {
                flushSelectorToken(buffer, mode: mode, tag: &tagFilter, id: &idFilter, classes: &classFilters)
                buffer = ""
                mode = ch
            } else {
                buffer.append(ch)
            }
        }
        flushSelectorToken(buffer, mode: mode, tag: &tagFilter, id: &idFilter, classes: &classFilters)

        if let t = tagFilter, !t.isEmpty, t != "*", node.tag != t.lowercased() { return false }
        if let id = idFilter, node.attributes["id"] != id { return false }
        if !classFilters.isEmpty {
            let nodeClasses = Set((node.attributes["class"] ?? "").split(whereSeparator: \.isWhitespace).map(String.init))
            for cls in classFilters where !nodeClasses.contains(cls) { return false }
        }
        return true
    }

    private func extractAttributeSelectors(from selector: String) -> (remaining: String, exprs: [String]) {
        var remaining = ""
        var exprs: [String] = []
        var idx = selector.startIndex
        while idx < selector.endIndex {
            let ch = selector[idx]
            if ch == "[" {
                var cur = selector.index(after: idx)
                var quote: Character?
                var escaped = false
                var foundEnd: String.Index?
                while cur < selector.endIndex {
                    let c = selector[cur]
                    if let q = quote {
                        if escaped {
                            escaped = false
                        } else if c == "\\" {
                            escaped = true
                        } else if c == q {
                            quote = nil
                        }
                    } else if c == "\"" || c == "'" {
                        quote = c
                    } else if c == "]" {
                        foundEnd = cur
                        break
                    }
                    cur = selector.index(after: cur)
                }
                if let endIdx = foundEnd {
                    exprs.append(String(selector[selector.index(after: idx)..<endIdx]))
                    idx = selector.index(after: endIdx)
                    continue
                }
            }
            remaining.append(ch)
            idx = selector.index(after: idx)
        }
        return (remaining, exprs)
    }

    private func flushSelectorToken(_ buf: String, mode: Character, tag: inout String?, id: inout String?, classes: inout [String]) {
        guard !buf.isEmpty else { return }
        if mode == "#" { id = buf }
        else if mode == "." { classes.append(buf) }
        else { tag = buf }
    }

    private func matchesAttributeExpr(_ node: HTMLDocumentNode, expr: String) -> Bool {
        if let eqIdx = expr.firstIndex(of: "=") {
            var op = "=", keyEnd = eqIdx
            if eqIdx > expr.startIndex {
                let prev = expr.index(before: eqIdx)
                if expr[prev] == "*" || expr[prev] == "^" || expr[prev] == "$" {
                    op = "\(expr[prev])="; keyEnd = prev
                }
            }
            let key = String(expr[..<keyEnd]).trimmingCharacters(in: .whitespaces).lowercased()
            let rawVal = String(expr[expr.index(after: eqIdx)...]).trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            guard let actual = node.attributes[key] else { return false }
            switch op {
            case "*=": return actual.contains(rawVal)
            case "^=": return actual.hasPrefix(rawVal)
            case "$=": return actual.hasSuffix(rawVal)
            default: return actual == rawVal
            }
        }
        return node.attributes[expr.trimmingCharacters(in: .whitespaces).lowercased()] != nil
    }
}

@objc public final class HTMLNodeListJS: NSObject, HTMLNodeListJSExport, @unchecked Sendable {
    public let nodes: [HTMLDocumentNode]
    public var length: Int { nodes.count }
    public init(nodes: [HTMLDocumentNode]) { self.nodes = nodes }
    public func size() -> Int { nodes.count }
    public func get(_ index: Int) -> HTMLDocumentNode? { (index >= 0 && index < nodes.count) ? nodes[index] : nil }
    public func first() -> HTMLDocumentNode? { nodes.first }
    public func last() -> HTMLDocumentNode? { nodes.last }
    public func text() -> String { nodes.map { $0.text() }.joined(separator: " ") }
    public func attr(_ name: String) -> String { nodes.first?.attr(name) ?? "" }
    public func select(_ css: String) -> HTMLNodeListJS { HTMLNodeListJS(nodes: nodes.flatMap { $0.select(css).nodes }) }
}
