import Foundation

/// 预处理后的有效行。`raw` 保留原始未去注释文本（块标量需按 raw 切缩进）。
public struct YAMLLine: Equatable {
    public var indent: Int
    public var text: String
    public var raw: String
    public var no: Int

    public init(_ indent: Int, _ text: String, _ raw: String, _ no: Int) {
        self.indent = indent
        self.text = text
        self.raw = raw
        self.no = no
    }
}

/// 出现在这些字符之后，引号才开启引号段（即引号处于 token 起始位置）。
private let tokenStartChars: Set<Character> = [":", "-", ",", "[", "{"]

private let whitespaceChars: Set<Character> = [" ", "\t", "\r", "\n", "\u{0B}", "\u{0C}"]

public func isWhitespace(_ c: Character) -> Bool {
    c == " " || c == "\t" || c == "\r" || c == "\n" || c == "\u{0B}" || c == "\u{0C}"
}

private func rstrip(_ s: String) -> String {
    var out = s
    while let last = out.last, isWhitespace(last) {
        out.removeLast()
    }
    return out
}

/// 去掉行尾注释。只有位于 token 起始处的引号才开启引号段。
///
/// YAML 的 plain scalar 里出现 `'` 或 `"` 时并不开启 quote（如 `it's a secret`），
/// 若误判会导致行尾注释吞不掉，值被污染。
public func stripComment(_ line: String) -> String {
    let chars = Array(line)
    let n = chars.count
    var out = String()
    out.reserveCapacity(n)
    var quote: Character?
    var prevSig: Character?      // 最近一个非空白、非引号字符
    var i = 0

    while i < n {
        let c = chars[i]

        if let q = quote {
            out.append(c)
            if c == "\\" && q == "\"" && i + 1 < n {
                out.append(chars[i + 1])
                i += 2
                continue
            }
            if c == q {
                // 单引号内的 '' 是转义的字面单引号
                if q == "'" && i + 1 < n && chars[i + 1] == "'" {
                    out.append("'")
                    i += 2
                    continue
                }
                quote = nil
            }
            i += 1
            continue
        }

        let atTokenStart = (prevSig == nil) || tokenStartChars.contains(prevSig!)
        if (c == "\"" || c == "'") && atTokenStart {
            quote = c
            out.append(c)
            prevSig = c
            i += 1
            continue
        }

        if c == "#" && (i == 0 || chars[i - 1] == " " || chars[i - 1] == "\t") {
            break
        }

        out.append(c)
        if c != " " && c != "\t" {
            prevSig = c
        }
        i += 1
    }

    return rstrip(out)
}

public func indentOf(_ line: String) -> Int {
    var n = 0
    for c in line {
        if c == " " { n += 1 } else { break }
    }
    return n
}

/// 把源码切成有效行，跳过纯空行/纯注释行。
public func splitLines(_ src: String) -> [YAMLLine] {
    var res: [YAMLLine] = []
    let rawLines = src.components(separatedBy: "\n")
    for (idx, rawLine) in rawLines.enumerated() {
        var raw = rawLine
        if raw.hasSuffix("\r") { raw.removeLast() }
        let s = stripComment(raw)
        if s.trimmingCharacters(in: .whitespaces).isEmpty { continue }
        let ind = indentOf(s)
        let text = ind <= s.count ? String(Array(s)[ind...]) : ""
        res.append(YAMLLine(ind, text, raw, idx + 1))
    }
    return res
}

/// 映射分隔冒号：后面必须跟空白/行尾，且不在引号或 flow 结构内。
/// 返回字符下标，未找到返回 -1。
public func findColon(_ text: String) -> Int {
    let chars = Array(text)
    let n = chars.count
    var quote: Character?
    var depth = 0
    var i = 0

    while i < n {
        let c = chars[i]

        if let q = quote {
            if c == "\\" && q == "\"" {
                i += 2
                continue
            }
            if c == q { quote = nil }
            i += 1
            continue
        }

        if (c == "\"" || c == "'") && (i == 0 || " ,[{".contains(chars[i - 1])) {
            quote = c
            i += 1
            continue
        }
        if c == "[" || c == "{" { depth += 1; i += 1; continue }
        if c == "]" || c == "}" { depth -= 1; i += 1; continue }
        if c == ":" && depth == 0 && (i + 1 >= n || chars[i + 1] == " " || chars[i + 1] == "\t") {
            return i
        }
        i += 1
    }
    return -1
}

/// 去掉成对的首尾引号并按 YAML 规则处理转义。
public func unquote(_ s: String) -> String {
    let chars = Array(s)
    guard chars.count >= 2, chars[0] == chars[chars.count - 1],
          chars[0] == "\"" || chars[0] == "'" else {
        return s
    }
    let body = String(chars[1..<(chars.count - 1)])
    if chars[0] == "'" {
        return body.replacingOccurrences(of: "''", with: "'")
    }
    guard body.contains("\\") else { return body }

    let bc = Array(body)
    var out = String()
    out.reserveCapacity(bc.count)
    var i = 0
    while i < bc.count {
        let c = bc[i]
        if c == "\\" && i + 1 < bc.count {
            let nx = bc[i + 1]
            switch nx {
            case "n": out.append("\n")
            case "t": out.append("\t")
            case "r": out.append("\r")
            case "\"": out.append("\"")
            case "\\": out.append("\\")
            case "0": out.append("\u{0}")
            case "/": out.append("/")
            default:
                out.append("\\")
                out.append(nx)
            }
            i += 2
            continue
        }
        out.append(c)
        i += 1
    }
    return out
}
