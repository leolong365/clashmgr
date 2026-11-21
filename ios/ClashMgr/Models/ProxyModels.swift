import Foundation

/// 一个代理节点。字段来自 mihomo 配置里 `proxies:` 的单项。
public struct ProxyNode: Identifiable, Equatable {
    public let id: String
    public var name: String
    public var type: String
    public var server: String
    public var port: Int
    /// 原始该项的所有键值（保序），导出时原样回写，因此未知协议字段也不会丢。
    public var raw: YAMLMap

    public init(name: String, type: String, server: String, port: Int, raw: YAMLMap) {
        self.id = name
        self.name = name
        self.type = type
        self.server = server
        self.port = port
        self.raw = raw
    }

    /// 从 YAML 映射构造。
    public static func from(_ map: YAMLMap) -> ProxyNode? {
        guard let name = map["name"]?.scalarText, !name.isEmpty else { return nil }
        let type = map["type"]?.scalarText ?? ""
        let server = map["server"]?.scalarText ?? ""
        let port = map["port"]?.intValue ?? 0
        return ProxyNode(name: name, type: type, server: server, port: port, raw: map)
    }

    /// 用于 UI 的副标题：`协议 · server:port`。
    public var subtitle: String {
        let host = server.isEmpty ? "—" : server
        return port > 0 ? "\(type) · \(host):\(port)" : "\(type) · \(host)"
    }
}

/// 策略组类型。
public enum ProxyGroupType: String, CaseIterable {
    case select
    case urlTest = "url-test"
    case fallback
    case loadBalance = "load-balance"
    case relay

    public var displayName: String {
        switch self {
        case .select: return "手动选择"
        case .urlTest: return "自动测速"
        case .fallback: return "故障转移"
        case .loadBalance: return "负载均衡"
        case .relay: return "链式代理"
        }
    }
}

/// 一个策略组。
public struct ProxyGroup: Identifiable, Equatable {
    public let id: String
    public var name: String
    public var type: String
    /// 组成员名（可以是节点名，也可以是其它组名）。
    public var members: [String]
    /// 是否引用了 provider（`use:`）。
    public var uses: [String]
    public var url: String?
    public var interval: Int?
    /// 该项原始键值，导出时保留 tolerance / lazy / strategy / filter 等全部字段。
    public var raw: YAMLMap

    public init(name: String, type: String, members: [String], uses: [String],
                url: String?, interval: Int?, raw: YAMLMap) {
        self.id = name
        self.name = name
        self.type = type
        self.members = members
        self.uses = uses
        self.url = url
        self.interval = interval
        self.raw = raw
    }

    public static func from(_ map: YAMLMap) -> ProxyGroup? {
        guard let name = map["name"]?.scalarText, !name.isEmpty else { return nil }
        let type = map["type"]?.scalarText ?? "select"
        let members = map["proxies"]?.stringList ?? []
        let uses = map["use"]?.stringList ?? []
        let url = map["url"]?.stringValue
        let interval = map["interval"]?.intValue
        return ProxyGroup(name: name, type: type, members: members, uses: uses,
                          url: url, interval: interval, raw: map)
    }

    public var groupType: ProxyGroupType? { ProxyGroupType(rawValue: type) }

    /// 组内成员数（含 use 引用时无法静态展开，只算显式 proxies）。
    public var memberCount: Int { members.count }
}

/// 一条规则。
public struct Rule: Identifiable, Equatable {
    public let id: String
    /// 规则类型，如 DOMAIN-SUFFIX / IP-CIDR / MATCH。
    public var type: String
    /// 匹配内容，如 `baidu.com`、`1.1.1.1/32`；MATCH 时为空。
    public var payload: String
    /// 命中的目标，如 `DIRECT` / `REJECT` / 组名。
    public var target: String
    /// 可选的尾部参数（`no-resolve`），以及内联逻辑规则的额外内容。
    public var params: [String]
    /// 规则原文，导出时原样写回。
    public var line: String

    public init(type: String, payload: String, target: String, params: [String], line: String) {
        self.type = type
        self.payload = payload
        self.target = target
        self.params = params
        self.line = line
        self.id = line
    }

    /// 解析 `TYPE,payload,target[,params...]` 形式的规则。
    /// 注意 SUB-RULE 与逻辑规则内含逗号，需按括号深度切分。
    public static func parse(_ line: String) -> Rule? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let fields = splitTopLevelComma(trimmed)
        guard let first = fields.first else { return nil }
        let type = first.trimmingCharacters(in: .whitespaces)
        guard !type.isEmpty else { return nil }

        if type.uppercased() == "MATCH" {
            let target = fields.count > 1 ? fields[1].trimmingCharacters(in: .whitespaces) : ""
            return Rule(type: type, payload: "", target: target, params: [], line: trimmed)
        }

        guard fields.count >= 2 else {
            return Rule(type: type, payload: "", target: "", params: [], line: trimmed)
        }
        let payload = fields[1].trimmingCharacters(in: .whitespaces)
        let target = fields.count >= 3 ? fields[2].trimmingCharacters(in: .whitespaces) : ""
        let params = fields.count > 3
            ? fields[3...].map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            : []
        return Rule(type: type, payload: payload, target: target, params: params, line: trimmed)
    }

    /// 按顶层逗号切分，忽略括号与引号内部的逗号。
    static func splitTopLevelComma(_ s: String) -> [String] {
        var out: [String] = []
        var buf = String()
        var depth = 0
        var quote: Character?
        for c in s {
            if let q = quote {
                buf.append(c)
                if c == q { quote = nil }
                continue
            }
            if c == "\"" || c == "'" { quote = c; buf.append(c); continue }
            if c == "(" || c == "[" || c == "{" { depth += 1; buf.append(c); continue }
            if c == ")" || c == "]" || c == "}" { depth -= 1; buf.append(c); continue }
            if c == "," && depth == 0 { out.append(buf); buf = ""; continue }
            buf.append(c)
        }
        if !buf.isEmpty || !out.isEmpty { out.append(buf) }
        return out
    }
}
