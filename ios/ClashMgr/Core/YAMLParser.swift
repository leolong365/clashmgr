import Foundation

public enum YAMLError: Error, CustomStringConvertible {
    case syntax(String)
    case unterminated(String)

    public var description: String {
        switch self {
        case .syntax(let m): return "YAML 语法错误：\(m)"
        case .unterminated(let m): return "YAML 未闭合：\(m)"
        }
    }
}

// MARK: - 文档层

/// 一个顶层键。保留原始行，以便无损回写。
public final class YAMLBlock {
    public var key: String
    public var headerRaw: String?
    public var block: [String]

    public init(key: String, headerRaw: String?, block: [String]) {
        self.key = key
        self.headerRaw = headerRaw
        self.block = block
    }

    /// 该键 `:` 之后的 inline 文本（已剥注释）。
    public var inlineText: String {
        guard let head = headerRaw else { return "" }
        let body = stripComment(head)
        guard let idx = body.firstIndex(of: ":") else { return "" }
        return body[body.index(after: idx)...].trimmingCharacters(in: .whitespaces)
    }
}

/// 按顶层键切块的文档。`toText()` 可字节级还原原文。
public final class YAMLDocument {
    public var prologue: [String]
    public var entries: [YAMLBlock]
    public var epilogue: [String]

    public init(prologue: [String] = [], entries: [YAMLBlock] = [], epilogue: [String] = []) {
        self.prologue = prologue
        self.entries = entries
        self.epilogue = epilogue
    }

    public func get(_ key: String) -> YAMLBlock? {
        entries.first(where: { $0.key == key })
    }

    public func setBlock(_ key: String, _ lines: [String]) {
        if let e = get(key) {
            e.block = lines
        } else {
            entries.append(YAMLBlock(key: key, headerRaw: key + ":", block: lines))
        }
    }

    public func remove(_ key: String) {
        entries.removeAll(where: { $0.key == key })
    }

    public func setHeader(_ key: String, header: String) {
        if let e = get(key) {
            e.headerRaw = header
        } else {
            entries.append(YAMLBlock(key: key, headerRaw: header, block: []))
        }
    }

    public func toText() -> String {
        var out = prologue
        for e in entries {
            if let h = e.headerRaw { out.append(h) }
            out.append(contentsOf: e.block)
        }
        out.append(contentsOf: epilogue)
        var txt = out.joined(separator: "\n")
        if !txt.isEmpty && !txt.hasSuffix("\n") { txt += "\n" }
        return txt
    }
}

private let topKeyAllowed: Set<Character> = Set<Character>("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-")

/// 匹配 `^([A-Za-z0-9_.\-]+)\s*:(\s|$)`，返回 key。
private func matchTopKey(_ line: String) -> String? {
    let chars = Array(line)
    var i = 0
    while i < chars.count, topKeyAllowed.contains(chars[i]) { i += 1 }
    guard i > 0 else { return nil }
    var j = i
    while j < chars.count, chars[j] == " " || chars[j] == "\t" { j += 1 }
    guard j < chars.count, chars[j] == ":" else { return nil }
    let after = j + 1
    guard after >= chars.count || chars[after] == " " || chars[after] == "\t" else { return nil }
    return String(chars[0..<i])
}

public func parseDocument(_ src: String) -> YAMLDocument {
    let rawLines = src.components(separatedBy: "\n")
    var prologue: [String] = []
    var entries: [YAMLBlock] = []
    var epilogue: [String] = []
    var cur: YAMLBlock?
    var started = false
    var trailing = 0

    for rawLine in rawLines {
        var line = rawLine
        if line.hasSuffix("\r") { line.removeLast() }

        let stripped = line.trimmingCharacters(in: .whitespaces)
        if stripped == "---" || stripped == "..." {
            if !started { prologue.append(line) }
            continue
        }

        if indentOf(line) == 0, let key = matchTopKey(line) {
            started = true
            cur = YAMLBlock(key: key, headerRaw: line, block: [])
            entries.append(cur!)
            trailing = 0
            continue
        }

        if !started {
            prologue.append(line)
            continue
        }

        if let c = cur {
            c.block.append(line)
            trailing = (line.trimmingCharacters(in: .whitespaces).isEmpty) ? trailing + 1 : 0
        }
    }

    // 末尾连续空行从最后一块摘出，放到 epilogue，否则多次往返会膨胀
    if let c = cur, trailing > 0 {
        c.block.removeLast(trailing)
        epilogue.append(contentsOf: Array(repeating: "", count: trailing))
    }

    return YAMLDocument(prologue: prologue, entries: entries, epilogue: epilogue)
}

// MARK: - 标量

private func isIntLiteral(_ t: String) -> Bool {
    let chars = Array(t)
    guard !chars.isEmpty else { return false }
    var i = 0
    if chars[0] == "+" || chars[0] == "-" { i = 1 }
    guard i < chars.count else { return false }
    while i < chars.count {
        if !chars[i].isNumber || !chars[i].isASCII { return false }
        i += 1
    }
    return true
}

private func isFloatLiteral(_ t: String) -> Bool {
    let chars = Array(t)
    let n = chars.count
    guard n > 0 else { return false }
    var i = 0
    if chars[0] == "+" || chars[0] == "-" { i = 1 }
    guard i < n else { return false }

    // mantissa: (\d+\.\d* | \.\d+ | \d+)
    var digitsBefore = 0
    while i < n, chars[i].isNumber, chars[i].isASCII { i += 1; digitsBefore += 1 }
    var mantissaOk = false
    if i < n, chars[i] == "." {
        i += 1
        var digitsAfter = 0
        while i < n, chars[i].isNumber, chars[i].isASCII { i += 1; digitsAfter += 1 }
        mantissaOk = digitsBefore > 0 || digitsAfter > 0
    } else {
        mantissaOk = digitsBefore > 0
    }
    guard mantissaOk, digitsBefore + 0 >= 0 else { return false }

    // 可选指数
    if i < n, chars[i] == "e" || chars[i] == "E" {
        i += 1
        if i < n, chars[i] == "+" || chars[i] == "-" { i += 1 }
        var expDigits = 0
        while i < n, chars[i].isNumber, chars[i].isASCII { i += 1; expDigits += 1 }
        guard expDigits > 0 else { return false }
    }
    return i == n
}

public func parseScalar(_ text: String) -> YAMLValue {
    let t = text.trimmingCharacters(in: .whitespaces)
    if t.isEmpty { return .null }

    let chars = Array(t)
    if chars[0] == "[" || chars[0] == "{" {
        let (v, _) = parseFlow(t, 0)
        return v ?? .null
    }
    if chars.count >= 2, chars[0] == chars[chars.count - 1],
       chars[0] == "\"" || chars[0] == "'" {
        return .string(unquote(t))
    }

    switch t.lowercased() {
    case "null", "~": return .null
    case "true": return .bool(true)
    case "false": return .bool(false)
    default: break
    }

    if isIntLiteral(t), let iv = Int(t) { return .int(iv) }
    if isFloatLiteral(t), let dv = Double(t) { return .double(dv) }
    return .string(t)
}

/// 递归下降解析 `[...]` / `{...}`。返回 (值, 新下标)。
public func parseFlow(_ text: String, _ start: Int) -> (YAMLValue?, Int) {
    let chars = Array(text)
    let n = chars.count
    var i = start

    func skipWS(_ j: Int) -> Int {
        var k = j
        while k < n, chars[k] == " " || chars[k] == "\t" { k += 1 }
        return k
    }

    i = skipWS(i)
    guard i < n else { return (nil, i) }
    let c = chars[i]

    if c == "[" {
        i += 1
        var arr: [YAMLValue] = []
        while true {
            while i < n, chars[i] == " " || chars[i] == "\t" || chars[i] == "," { i += 1 }
            if i >= n { return (.array(arr), i) }
            if chars[i] == "]" { return (.array(arr), i + 1) }
            let (v, ni) = parseFlow(text, i)
            arr.append(v ?? .null)
            i = ni
        }
    }

    if c == "{" {
        i += 1
        var obj = YAMLMap()
        while true {
            while i < n, chars[i] == " " || chars[i] == "\t" || chars[i] == "," { i += 1 }
            if i >= n { return (.object(obj), i) }
            if chars[i] == "}" { return (.object(obj), i + 1) }
            let (k, ki) = parseFlow(text, i)
            i = skipWS(ki)
            let key = k?.scalarText ?? ""
            if i < n, chars[i] == ":" {
                let (v, vi) = parseFlow(text, i + 1)
                obj[key] = v ?? .null
                i = vi
            } else {
                obj[key] = .null
            }
        }
    }

    if c == "\"" || c == "'" {
        let q = c
        i += 1
        var buf = String()
        while i < n {
            if chars[i] == "\\" && q == "\"" && i + 1 < n {
                buf.append(chars[i]); buf.append(chars[i + 1])
                i += 2
                continue
            }
            if chars[i] == q { i += 1; break }
            buf.append(chars[i])
            i += 1
        }
        return (.string(unquote(String(q) + buf + String(q))), i)
    }

    let segStart = i
    while i < n, !",]}".contains(chars[i]) {
        if chars[i] == ":" && (i + 1 >= n || chars[i + 1] == " " || chars[i + 1] == "\t") {
            break
        }
        i += 1
    }
    let seg = String(chars[segStart..<i]).trimmingCharacters(in: .whitespaces)
    return (seg.isEmpty ? nil : parseScalar(seg), i)
}

// MARK: - 结构层

public final class YAMLParser {
    private var lines: [YAMLLine]
    private var i = 0

    public init(_ lines: [YAMLLine]) {
        self.lines = lines
    }

    private var atEnd: Bool { i >= lines.count }
    private func current() -> YAMLLine? { atEnd ? nil : lines[i] }

    private static func isSeqItem(_ ln: YAMLLine) -> Bool {
        ln.text == "-" || ln.text.hasPrefix("- ")
    }

    public func parseBlock(_ minIndent: Int) -> YAMLValue? {
        guard let ln = current(), ln.indent >= minIndent else { return nil }
        return parseNode(ln.indent)
    }

    private func parseNode(_ ind: Int) -> YAMLValue? {
        guard let ln = current(), ln.indent >= ind else { return nil }
        if YAMLParser.isSeqItem(ln) { return parseSeq(ln.indent) }
        if findColon(ln.text) >= 0 { return parseMap(ln.indent) }
        return parsePlainBlock(ln.indent)
    }

    private func parseMap(_ ind: Int) -> YAMLValue {
        var out = YAMLMap()
        while true {
            guard let ln = current() else { break }
            if ln.indent < ind { break }
            if ln.indent > ind { i += 1; continue }   // 非法缩进，容错跳过
            if YAMLParser.isSeqItem(ln) { break }

            let colon = findColon(ln.text)
            if colon < 0 { i += 1; continue }

            let keyChars = Array(ln.text)
            let key = unquote(String(keyChars[0..<colon]).trimmingCharacters(in: .whitespaces))
            let rest = String(keyChars[(colon + 1)...]).trimmingCharacters(in: .whitespaces)
            i += 1
            out[key] = parseValueAfterKey(ind, rest)
        }
        return .object(out)
    }

    private func parseValueAfterKey(_ ind: Int, _ rest: String) -> YAMLValue {
        if rest.isEmpty { return parseChild(ind) ?? .null }
        if isBlockStyle(rest) { return .string(readBlockScalar(ind, rest)) }
        return parseScalar(rest)
    }

    private func isBlockStyle(_ s: String) -> Bool {
        s == "|" || s == ">" || s == "|-" || s == ">-" || s == "|+" || s == ">+"
    }

    /// `key:` 之后换行。子块缩进可 > ind；若为序列，允许与 key 同缩进。
    private func parseChild(_ ind: Int) -> YAMLValue? {
        guard let ln = current() else { return nil }
        if ln.indent > ind { return parseNode(ln.indent) }
        if ln.indent == ind, YAMLParser.isSeqItem(ln) { return parseSeq(ind) }
        return nil
    }

    private func readBlockScalar(_ ind: Int, _ style: String) -> String {
        var buf: [String] = []
        var base: Int?
        while true {
            guard let ln = current() else { break }
            let trimmed = ln.text.trimmingCharacters(in: .whitespaces)
            if ln.indent <= ind && !trimmed.isEmpty { break }
            if base == nil && !trimmed.isEmpty { base = ln.indent }
            let cutFrom = base ?? (ind + 1)
            let rawChars = Array(ln.raw)
            let cut = cutFrom <= rawChars.count ? String(rawChars[cutFrom...]) : ""
            buf.append(cut)
            i += 1
        }

        let body: String
        if style.hasPrefix(">") {
            body = buf.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .joined(separator: " ")
        } else {
            body = buf.joined(separator: "\n")
        }

        if style.hasSuffix("-") { return body }
        if style.hasSuffix("+") { return body + "\n" }
        return body.isEmpty ? body : body + "\n"
    }

    /// 键后换行写出的标量：把 >= ind 的连续非结构行折叠成一个值。
    private func parsePlainBlock(_ ind: Int) -> YAMLValue? {
        var parts: [String] = []
        while true {
            guard let ln = current() else { break }
            if ln.indent < ind { break }
            if ln.indent == ind && YAMLParser.isSeqItem(ln) { break }
            if ln.indent == ind && findColon(ln.text) >= 0 { break }
            parts.append(ln.text.trimmingCharacters(in: .whitespaces))
            i += 1
        }
        if parts.isEmpty { return nil }
        if parts.count == 1 { return parseScalar(parts[0]) }
        return .string(parts.joined(separator: " "))
    }

    private func parseSeq(_ ind: Int) -> YAMLValue {
        var items: [YAMLValue] = []
        while true {
            guard let ln = current(), ln.indent == ind, YAMLParser.isSeqItem(ln) else { break }

            if ln.text == "-" {
                i += 1
                items.append(parseChild(ind) ?? .null)
                continue
            }

            let restRaw = String(Array(ln.text)[2...])
            let lead = indentOf(restRaw)
            let rest = restRaw.trimmingCharacters(in: .whitespaces)
            let inner = ind + 2 + lead        // 内联内容的有效缩进

            if isBlockStyle(rest) {
                i += 1
                items.append(.string(readBlockScalar(ind, rest)))
                continue
            }

            if rest.hasPrefix("- ") || rest == "-" {
                lines[i] = YAMLLine(inner, rest, ln.raw, ln.no)
                items.append(parseSeq(inner))
                continue
            }

            if findColon(rest) >= 0 {
                lines[i] = YAMLLine(inner, rest, ln.raw, ln.no)
                items.append(parseMap(inner))
                continue
            }

            i += 1
            var value = parseScalar(rest)
            // 该标量可能的续行
            var cont: [String] = []
            while true {
                guard let nxt = current() else { break }
                if nxt.indent <= ind || YAMLParser.isSeqItem(nxt) || findColon(nxt.text) >= 0 { break }
                cont.append(nxt.text.trimmingCharacters(in: .whitespaces))
                i += 1
            }
            if !cont.isEmpty {
                value = .string(([value.scalarText] + cont).joined(separator: " "))
            }
            items.append(value)
        }
        return .array(items)
    }
}

/// 把顶层键重新按完整语法解析（支持 `key: |` 与 `key:` 后换行标量）。
public func entryValue(_ doc: YAMLDocument, _ key: String) -> YAMLValue? {
    guard let e = doc.get(key) else { return nil }
    let text = key + ": " + e.inlineText + "\n" + e.block.joined(separator: "\n")
    let lines = splitLines(text)
    if lines.isEmpty { return nil }
    let p = YAMLParser(lines)
    let v = p.parseBlock(0)
    return v?.mapValue?[key]
}
