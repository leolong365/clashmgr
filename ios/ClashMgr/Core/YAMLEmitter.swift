import Foundation

public enum YAMLEmitter {

    /// 需要引号的首字符集合。
    private static let unsafeFirst: Set<Character> = [
        "-", "?", ":", ",", "[", "]", "{", "}", "#", "&", "*", "!", "|", ">",
        "'", "\"", "%", "@", "`", " "
    ]

    private static let reservedWords: Set<String> = [
        "null", "~", "true", "false", "yes", "no", "on", "off"
    ]

    public static func dumpScalar(_ v: YAMLValue) -> String {
        switch v {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .int(let i): return String(i)
        case .double(let d): return YAMLValue.formatDouble(d)
        case .string(let s): return dumpString(s)
        case .array, .object:
            return flowDump(v)
        }
    }

    private static func dumpString(_ s: String) -> String {
        if s.isEmpty { return "''" }
        let chars = Array(s)
        var need = false

        if let f = chars.first, unsafeFirst.contains(f) { need = true }
        if let l = chars.last, l == " " { need = true }
        if s.contains(": ") || s.contains(" #") { need = true }
        if s.hasSuffix(":") { need = true }
        if reservedWords.contains(s.lowercased()) { need = true }
        if isNumericLike(s) { need = true }
        if s.contains("\n") { need = true }

        if !need { return s }
        if !s.contains("\"") && !s.contains("\n") && !s.contains("\\") {
            return "\"" + s + "\""
        }
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\t", with: "\\t")
            .replacingOccurrences(of: "\r", with: "\\r")
        return "\"" + escaped + "\""
    }

    private static func isNumericLike(_ s: String) -> Bool {
        switch parseScalar(s) {
        case .int, .double: return true
        default: return false
        }
    }

    /// 标量或空容器写在一行内。
    public static func emitScalarInline(_ v: YAMLValue) -> String {
        switch v {
        case .object(let m): return m.isEmpty ? "{}" : flowDump(v)
        case .array(let a): return a.isEmpty ? "[]" : flowDump(v)
        default: return dumpScalar(v)
        }
    }

    public static func flowDump(_ v: YAMLValue) -> String {
        switch v {
        case .object(let m):
            let inner = m.pairs
                .map { dumpScalar(.string($0.key)) + ": " + flowDump($0.value) }
                .joined(separator: ", ")
            return "{" + inner + "}"
        case .array(let a):
            return "[" + a.map(flowDump(_:)).joined(separator: ", ") + "]"
        default:
            return dumpScalar(v)
        }
    }

    /// 块状发射。返回带缩进的行数组。
    public static func emitValue(_ v: YAMLValue, indent: Int) -> [String] {
        let pad = String(repeating: " ", count: indent)

        switch v {
        case .object(let m):
            if m.isEmpty { return [pad + "{}"] }
            var out: [String] = []
            for pair in m.pairs {
                let ks = dumpScalar(.string(pair.key))
                switch pair.value {
                case .object(let sub) where !sub.isEmpty:
                    out.append("\(pad)\(ks):")
                    out.append(contentsOf: emitValue(pair.value, indent: indent + 2))
                case .array(let arr) where !arr.isEmpty:
                    out.append("\(pad)\(ks):")
                    out.append(contentsOf: emitValue(pair.value, indent: indent + 2))
                default:
                    out.append("\(pad)\(ks): \(emitScalarInline(pair.value))")
                }
            }
            return out

        case .array(let a):
            if a.isEmpty { return [pad + "[]"] }
            var out: [String] = []
            for item in a {
                switch item {
                case .object(let sub) where !sub.isEmpty:
                    var seg = emitValue(item, indent: indent + 2)
                    let cutFrom = indent + 2
                    let firstChars = Array(seg[0])
                    let tail = cutFrom <= firstChars.count ? String(firstChars[cutFrom...]) : ""
                    seg[0] = pad + "- " + tail
                    out.append(contentsOf: seg)
                case .array(let sub) where !sub.isEmpty:
                    out.append(pad + "-")
                    out.append(contentsOf: emitValue(item, indent: indent + 2))
                default:
                    out.append("\(pad)- \(emitScalarInline(item))")
                }
            }
            return out

        default:
            return [pad + emitScalarInline(v)]
        }
    }

    public static func emit(_ v: YAMLValue, indent: Int = 0) -> String {
        emitValue(v, indent: indent).joined(separator: "\n")
    }
}
