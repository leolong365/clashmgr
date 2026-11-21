import Foundation

/// 解析后的 mihomo 配置。文档层保留原文以便无损回写；结构层提供读写视图。
public final class MihomoConfig {

    public private(set) var document: YAMLDocument

    public private(set) var proxies: [ProxyNode]
    public private(set) var groups: [ProxyGroup]
    public private(set) var rules: [Rule]

    /// 解析时收集的非致命问题，用于在 UI 上提示。
    public private(set) var warnings: [String]

    private init(document: YAMLDocument,
                 proxies: [ProxyNode],
                 groups: [ProxyGroup],
                 rules: [Rule],
                 warnings: [String]) {
        self.document = document
        self.proxies = proxies
        self.groups = groups
        self.rules = rules
        self.warnings = warnings
    }

    // MARK: - 解析

    public static func parse(_ source: String) -> MihomoConfig {
        var warnings: [String] = []

        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n")
        let doc = parseDocument(normalized)

        // proxies
        var proxies: [ProxyNode] = []
        if let pv = entryValue(doc, "proxies"), case .array(let items) = pv {
            for item in items {
                guard let m = item.mapValue else { continue }
                if let node = ProxyNode.from(m) {
                    proxies.append(node)
                } else {
                    let label = m["name"]?.scalarText ?? "(无名字)"
                    warnings.append("节点「\(label)」缺少 name 字段，已跳过")
                }
            }
        } else if doc.get("proxies") != nil {
            warnings.append("proxies 段不是数组，无法解析")
        }

        // proxy-groups
        var groups: [ProxyGroup] = []
        if let gv = entryValue(doc, "proxy-groups"), case .array(let items) = gv {
            for item in items {
                guard let m = item.mapValue else { continue }
                if let g = ProxyGroup.from(m) {
                    groups.append(g)
                } else {
                    let label = m["name"]?.scalarText ?? "(无名组)"
                    warnings.append("策略组「\(label)」缺少 name 字段，已跳过")
                }
            }
        } else if doc.get("proxy-groups") != nil {
            warnings.append("proxy-groups 段不是数组，无法解析")
        }

        // rules
        var rules: [Rule] = []
        let ruleLines = rawRuleLines(doc, "rules")
        for line in ruleLines {
            if let r = Rule.parse(line) {
                rules.append(r)
            } else {
                warnings.append("无法解析的规则：\(line)")
            }
        }
        if doc.get("sub-rules") != nil {
            let count = subRuleCount(doc)
            if count > 0 {
                warnings.append("配置含 \(count) 条子规则（sub-rules），本 App 仅展示主规则链")
            }
        }

        return MihomoConfig(document: doc, proxies: proxies, groups: groups,
                            rules: rules, warnings: warnings)
    }

    /// 从 `rules:` 段取出每条规则的原文（去掉前导 `- `）。
    static func rawRuleLines(_ doc: YAMLDocument, _ key: String) -> [String] {
        guard let e = doc.get(key) else { return [] }
        var out: [String] = []
        for raw in e.block {
            let s = stripComment(raw)
            let t = s.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { continue }
            if t.hasPrefix("- ") {
                let body = String(t.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                if !body.isEmpty { out.append(body) }
            } else if t == "-" {
                continue
            }
        }
        return out
    }

    static func subRuleCount(_ doc: YAMLDocument) -> Int {
        guard let e = doc.get("sub-rules") else { return 0 }
        return e.block.filter { stripComment($0).trimmingCharacters(in: .whitespaces).hasPrefix("- ") }.count
    }

    // MARK: - 查询辅助

    /// 所有出现过的节点类型，用于筛选。
    public var proxyTypes: [String] {
        Array(Set(proxies.map(\.type))).sorted()
    }

    /// 名字 → 节点。
    public func proxy(named name: String) -> ProxyNode? {
        proxies.first(where: { $0.name == name })
    }

    /// 名字 → 策略组。
    public func group(named name: String) -> ProxyGroup? {
        groups.first(where: { $0.name == name })
    }

    /// 目标名是否为内置策略（DIRECT / REJECT / REJECT-DROP / PASS / COMPATIBLE）。
    public static func isBuiltinTarget(_ target: String) -> Bool {
        switch target.uppercased() {
        case "DIRECT", "REJECT", "REJECT-DROP", "PASS", "COMPATIBLE":
            return true
        default:
            return false
        }
    }

    /// 规则里出现的目标名集合（去掉内置项）。
    public var ruleTargets: [String] {
        Array(Set(rules.map(\.target).filter { !MihomoConfig.isBuiltinTarget($0) })).sorted()
    }

    /// 把组名逐层展开成真实节点名（解析 relay / 嵌套组）。
    /// - Parameter guardDepth: 防止配置里出现环导致无限递归。
    public func resolveMembers(ofGroup name: String, depth: Int = 0) -> [String] {
        guard depth < 8, let g = group(named: name) else { return [] }
        var out: [String] = []
        for m in g.members {
            if group(named: m) != nil {
                out.append(contentsOf: resolveMembers(ofGroup: m, depth: depth + 1))
            } else {
                out.append(m)
            }
        }
        return out
    }

    /// 展开组成员并**去重**，用于界面展示。
    ///
    /// 与 `resolveMembers(ofGroup:depth:)` 的区别：
    /// - 内置策略（DIRECT / REJECT …）原样保留，因为它们也是可选项；
    /// - 用 visited 集合防止 A→B→A 这种环，而不是只靠深度上限；
    /// - 结果按首次出现顺序去重，避免同一节点在组里出现两次。
    public func flattenedMembers(of groupName: String) -> [String] {
        var out: [String] = []
        var seenNodes = Set<String>()
        var seenGroups = Set<String>([groupName])

        func walk(_ names: [String], depth: Int) {
            guard depth < 8 else { return }
            for m in names {
                if let child = group(named: m) {
                    if !seenGroups.contains(child.name) {
                        seenGroups.insert(child.name)
                        walk(child.members, depth: depth + 1)
                    }
                } else if !seenNodes.contains(m) {
                    seenNodes.insert(m)
                    out.append(m)
                }
            }
        }

        walk(group(named: groupName)?.members ?? [], depth: 0)
        return out
    }

    /// 引用了某个节点的所有策略组名。
    public func groupsReferencing(node name: String) -> [String] {
        groups.filter { $0.members.contains(name) }.map(\.name)
    }
}
