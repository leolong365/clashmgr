import Foundation

/// 规则匹配可行性：能离线判定的就判定，不能的显式标记为未知。
public enum RuleMatchOutcome: Equatable {
    case matched
    case notMatched
    /// 需要 mihomo 运行时数据（GeoIP/GeoSite 库、规则集文件、进程信息等），本机无法离线判定。
    case unknown(String)
}

/// 规则测试的输入类型。
public struct RuleTestInput {
    public enum Kind {
        case domain(String)
        case ipAddress(String)
        case url(URL)
    }
    public var kind: Kind
    public var raw: String

    public var host: String {
        switch kind {
        case .domain(let d): return d
        case .ipAddress(let ip): return ip
        case .url(let u): return u.host ?? ""
        }
    }
}

/// 一条因缺少运行时数据而无法判定的规则。
public struct SkippedRule: Identifiable {
    public var index: Int
    public var rule: Rule
    public var reason: String
    public var id: Int { index }

    public init(index: Int, rule: Rule, reason: String) {
        self.index = index
        self.rule = rule
        self.reason = reason
    }
}

/// 一次规则测试的结果。
public struct RuleTestResult {
    /// 命中的规则下标；nil 表示没有任何规则命中（配置里缺少 MATCH 兜底）。
    public var matchedIndex: Int?
    public var matchedRule: Rule?
    /// 在命中规则之前、无法离线判定的规则。它们可能改变最终结果。
    public var skipped: [SkippedRule]
    /// 是否是靠 MATCH 兜底命中。
    public var viaFallback: Bool
    public var input: String
}

/// 复刻 mihomo 的规则匹配优先级：按书写顺序逐条匹配，第一个命中即终止。
public enum RuleMatcher {

    /// 从用户输入推断测试目标：可以是域名、IP 或完整 URL。
    public static func inferInput(_ text: String) -> RuleTestInput? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }

        if t.contains("://"), let u = URL(string: t), u.host != nil {
            return RuleTestInput(kind: .url(u), raw: t)
        }
        // 无 scheme 但有路径：补成 http:// 再解析
        if t.contains("/"), !t.contains(" ") {
            if let u = URL(string: "http://" + t), u.host != nil {
                return RuleTestInput(kind: .url(u), raw: t)
            }
        }
        if isIPLiteral(t) {
            return RuleTestInput(kind: .ipAddress(t), raw: t)
        }
        return RuleTestInput(kind: .domain(t.lowercased()), raw: t)
    }

    /// 逐条匹配。命中返回结果；遇到无法判定的规则会记录下来并继续向后找。
    public static func test(_ input: RuleTestInput, rules: [Rule]) -> RuleTestResult {
        var skipped: [SkippedRule] = []
        let host = input.host.lowercased()

        for (idx, rule) in rules.enumerated() {
            let outcome = evaluate(rule, input: input, host: host)
            switch outcome {
            case .matched:
                return RuleTestResult(
                    matchedIndex: idx,
                    matchedRule: rule,
                    skipped: skipped,
                    viaFallback: rule.type.uppercased() == "MATCH",
                    input: input.raw
                )
            case .notMatched:
                continue
            case .unknown(let reason):
                skipped.append(SkippedRule(index: idx, rule: rule, reason: reason))
                continue
            }
        }

        return RuleTestResult(matchedIndex: nil, matchedRule: nil, skipped: skipped,
                              viaFallback: false, input: input.raw)
    }

    // MARK: - 单条规则求值

    public static func evaluate(_ rule: Rule, input: RuleTestInput, host: String) -> RuleMatchOutcome {
        let type = rule.type.uppercased()
        let payload = rule.payload.lowercased()

        switch type {
        case "MATCH":
            return .matched

        case "DOMAIN":
            return host == payload ? .matched : .notMatched

        case "DOMAIN-SUFFIX":
            // mihomo：domain == suffix 或 domain 以 ".suffix" 结尾
            if host == payload { return .matched }
            if host.hasSuffix("." + payload) { return .matched }
            return .notMatched

        case "DOMAIN-KEYWORD":
            return host.contains(payload) ? .matched : .notMatched

        case "DOMAIN-WILDCARD":
            return wildcardMatch(pattern: payload, text: host) ? .matched : .notMatched

        case "DOMAIN-REGEX":
            return regexMatch(pattern: rule.payload, text: host) ? .matched : .notMatched

        case "IP-CIDR", "IP-CIDR6":
            guard let ip = ipLiteral(from: input) else {
                return .notMatched   // 输入是域名且未解析，无法命中 IP 规则
            }
            guard let hit = cidrContains(cidr: rule.payload, ip: ip) else {
                return .unknown("CIDR 写法无法解析：\(rule.payload)")
            }
            return hit ? .matched : .notMatched

        case "GEOIP", "SRC-GEOIP":
            return .unknown("需要 GeoIP 数据库（MMDB），本机无离线副本")

        case "GEOSITE":
            return .unknown("需要 GeoSite 数据库，本机无离线副本")

        case "RULE-SET":
            return .unknown("规则集「\(rule.payload)」需要先下载 provider 内容才能判定")

        case "IP-ASN":
            return .unknown("需要 ASN 数据库，本机无离线副本")

        case "IP-SUFFIX":
            guard let ip = ipLiteral(from: input) else { return .notMatched }
            guard let hit = ipSuffixContains(pattern: rule.payload, ip: ip) else {
                return .unknown("IP-SUFFIX 写法无法解析：\(rule.payload)")
            }
            return hit ? .matched : .notMatched

        case "SRC-IP-CIDR", "SRC-PORT", "DST-PORT", "SRC-IP-SUFFIX":
            return .unknown("需要连接的源地址/端口信息，本机无法离线判定")

        case "PROCESS-NAME", "PROCESS-PATH", "PROCESS-NAME-REGEX", "PROCESS-PATH-REGEX", "UID":
            return .unknown("需要本机进程信息，iOS 上不适用")

        case "NETWORK", "IN-TYPE", "IN-USER", "IN-NAME", "IN-PORT":
            return .unknown("需要连接的网络层/入站信息，本机无法离线判定")

        case "SUB-RULE":
            return .unknown("子规则「\(rule.payload)」需要完整规则链求值")

        case "AND", "OR", "NOT":
            return .unknown("逻辑规则需要对其内部子条件逐一求值")

        default:
            return .unknown("未知规则类型 \(rule.type)")
        }
    }

    // MARK: - 匹配原语

    /// mihomo 的 DOMAIN-WILDCARD：`*` 匹配任意字符，`?` 匹配单字符。
    static func wildcardMatch(pattern: String, text: String) -> Bool {
        let p = Array(pattern.lowercased())
        let t = Array(text.lowercased())

        var pi = 0, ti = 0
        var starIdx = -1, matchIdx = 0

        while ti < t.count {
            if pi < p.count && (p[pi] == "?" || p[pi] == t[ti]) {
                pi += 1; ti += 1
            } else if pi < p.count && p[pi] == "*" {
                starIdx = pi
                matchIdx = ti
                pi += 1
            } else if starIdx != -1 {
                pi = starIdx + 1
                matchIdx += 1
                ti = matchIdx
            } else {
                return false
            }
        }
        while pi < p.count && p[pi] == "*" { pi += 1 }
        return pi == p.count
    }

    static func regexMatch(pattern: String, text: String) -> Bool {
        guard let re = try? NSRegularExpression(pattern: pattern, options: []) else {
            return false
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return re.firstMatch(in: text, options: [], range: range) != nil
    }

    static func ipLiteral(from input: RuleTestInput) -> String? {
        switch input.kind {
        case .ipAddress(let ip): return ip
        case .domain(let d): return isIPLiteral(d) ? d : nil
        case .url(let u):
            if let h = u.host, isIPLiteral(h) { return h }
            return nil
        }
    }

    public static func isIPLiteral(_ s: String) -> Bool {
        parseIPv4(s) != nil || parseIPv6(s) != nil
    }

    // MARK: - IPv4

    static func parseIPv4(_ s: String) -> UInt32? {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var value: UInt32 = 0
        for p in parts {
            guard !p.isEmpty, p.count <= 3,
                  p.allSatisfy({ $0.isNumber && $0.isASCII }),
                  let n = UInt32(p), n <= 255 else { return nil }
            value = (value << 8) | n
        }
        return value
    }

    // MARK: - IPv6

    static func parseIPv6(_ s: String) -> [UInt16]? {
        guard !s.isEmpty else { return nil }
        var text = s
        if text.hasPrefix("[") && text.hasSuffix("]") {
            text = String(text.dropFirst().dropLast())
        }
        // 去掉 zone id
        if let pct = text.firstIndex(of: "%") {
            text = String(text[text.startIndex..<pct])
        }
        guard text.contains(":") else { return nil }

        var head: [UInt16] = []
        var tail: [UInt16] = []
        var sawDoubleColon = false

        let groups = text.components(separatedBy: "::")
        if groups.count > 2 { return nil }

        func parseGroups(_ part: String, allowIPv4Tail: Bool) -> [UInt16]? {
            if part.isEmpty { return [] }
            var out: [UInt16] = []
            let items = part.split(separator: ":", omittingEmptySubsequences: false)
            for (i, raw) in items.enumerated() {
                let item = String(raw)
                if item.isEmpty { return nil }
                if item.contains(".") {
                    guard allowIPv4Tail, i == items.count - 1,
                          let v4 = parseIPv4(item) else { return nil }
                    out.append(UInt16(v4 >> 16))
                    out.append(UInt16(v4 & 0xFFFF))
                    continue
                }
                guard item.count <= 4,
                      item.allSatisfy({ $0.isHexDigit }),
                      let v = UInt16(item, radix: 16) else { return nil }
                out.append(v)
            }
            return out
        }

        if groups.count == 2 {
            sawDoubleColon = true
            guard let h = parseGroups(groups[0], allowIPv4Tail: false) else { return nil }
            guard let t = parseGroups(groups[1], allowIPv4Tail: true) else { return nil }
            head = h
            tail = t
            if head.count + tail.count > 8 { return nil }
        } else {
            guard let h = parseGroups(groups[0], allowIPv4Tail: true), h.count == 8 else { return nil }
            return h
        }

        let fill = 8 - head.count - tail.count
        guard fill >= 0 else { return nil }
        if !sawDoubleColon && fill != 0 { return nil }
        return head + Array(repeating: 0, count: fill) + tail
    }

    /// 判断 IP 是否落在 CIDR 内。写法无法解析时返回 nil。
    public static func cidrContains(cidr: String, ip: String) -> Bool? {
        let parts = cidr.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let network = String(parts[0])
        guard let prefixLen = Int(parts[1]), prefixLen >= 0 else { return nil }

        if let net4 = parseIPv4(network) {
            guard let ip4 = parseIPv4(ip), prefixLen <= 32 else { return nil }
            if prefixLen == 0 { return true }
            let mask: UInt32 = prefixLen == 32 ? 0xFFFF_FFFF : (0xFFFF_FFFF << UInt32(32 - prefixLen))
            return (net4 & mask) == (ip4 & mask)
        }
        if let net6 = parseIPv6(network) {
            guard let ip6 = parseIPv6(ip), prefixLen <= 128 else { return nil }
            var remaining = prefixLen
            for i in 0..<8 {
                if remaining <= 0 { break }
                let bits = min(16, remaining)
                let mask: UInt16 = bits == 16 ? 0xFFFF : (0xFFFF << UInt16(16 - bits))
                if (net6[i] & mask) != (ip6[i] & mask) { return false }
                remaining -= 16
            }
            return true
        }
        return nil
    }

    static func ipSuffixContains(pattern: String, ip: String) -> Bool? {
        // mihomo 的 IP-SUFFIX 语义为按点分的前缀匹配，例如 8.8.8.8/24 不可用；
        // 此处按字符串前缀 + 段边界实现。
        let p = pattern.lowercased()
        let s = ip.lowercased()
        if s == p { return true }
        guard s.hasPrefix(p) else { return false }
        let next = s[s.index(s.startIndex, offsetBy: p.count)]
        return next == "." || next == ":"
    }
}
