import Foundation

/// 把订阅导出成可被电脑端 mihomo / Clash Verge 直接使用的配置文件。
///
/// 设计要点：
/// - **不在导出途中重写无关段落**。`dns` / `tun` / `sniffer` / `tunnels` / 证书 / `hosts`
///   等段落在文档层原样保留，只有 `proxies`、`proxy-groups` 走结构重发射。
/// - 策略组里被裁掉的节点引用会被移除；若某组被剪空，则回填 `DIRECT`，
///   这样即使规则仍指向该组也不会出现悬空引用。
public struct Exporter {

    public struct Options {
        /// 要保留的节点名集合。
        public var keepNodeNames: Set<String>
        /// 是否保留规则段。
        public var includeRules: Bool
        /// 被剪空的策略组回填的目标。
        public var emptyGroupFallback: String

        public init(keepNodeNames: Set<String>,
                    includeRules: Bool = true,
                    emptyGroupFallback: String = "DIRECT") {
            self.keepNodeNames = keepNodeNames
            self.includeRules = includeRules
            self.emptyGroupFallback = emptyGroupFallback
        }
    }

    public struct Result {
        public let text: String
        public let keptNodes: Int
        public let droppedNodes: Int
        public let keptGroups: Int
        public let droppedMembers: Int
    }

    public init() {}

    /// 生成导出文本。
    public func export(_ config: MihomoConfig, options: Options) -> Result {
        let doc = config.document

        // 1. proxies —— 按原始顺序保留选中项，其余丢弃。
        var keptNodes: [ProxyNode] = []
        var droppedNodes = 0
        for node in config.proxies {
            if options.keepNodeNames.contains(node.name) {
                keptNodes.append(node)
            } else {
                droppedNodes += 1
            }
        }

        // 保留未在解析结果中出现的条目（例如缺少 name 而被跳过的），避免静默丢数据。
        let knownNames = Set(config.proxies.map { $0.name })
        var extraProxyValues: [YAMLValue] = []
        if let rawProxies = entryValue(doc, "proxies"), case .array(let items) = rawProxies {
            for item in items {
                guard let m = item.mapValue else { continue }
                let name = m["name"]?.scalarText
                if name == nil || !knownNames.contains(name!) {
                    // 解析不出来的条目：只要用户没明确丢弃，就原样带上。
                    extraProxyValues.append(item)
                }
            }
        }

        var proxyValues = keptNodes.map { YAMLValue.object($0.raw) } + extraProxyValues
        if proxyValues.isEmpty {
            proxyValues = []
        }
        setSection(doc, key: "proxies", value: .array(proxyValues))

        // 2. proxy-groups —— 逐组裁剪成员引用。
        let groupNames = Set(config.groups.map { $0.name })
        var keptGroups: [YAMLValue] = []
        var droppedMembers = 0

        for group in config.groups {
            var m = group.raw
            var newMembers: [YAMLValue] = []

            for member in group.members {
                let keep = options.keepNodeNames.contains(member)
                    || groupNames.contains(member)
                    || MihomoConfig.isBuiltinTarget(member)
                if keep {
                    newMembers.append(.string(member))
                } else {
                    droppedMembers += 1
                }
            }

            if newMembers.isEmpty {
                newMembers = [.string(options.emptyGroupFallback)]
            }

            if m.contains("proxies") {
                m["proxies"] = .array(newMembers)
            } else {
                m["proxies"] = .array(newMembers)
            }
            keptGroups.append(.object(m))
        }

        if !keptGroups.isEmpty || doc.get("proxy-groups") != nil {
            setSection(doc, key: "proxy-groups", value: .array(keptGroups))
        }

        // 3. rules —— 可选保留。规则内容本身不因剪节点而失效（目标组仍存在）。
        if !options.includeRules {
            doc.remove("rules")
        }

        return Result(
            text: doc.toText(),
            keptNodes: keptNodes.count + extraProxyValues.count,
            droppedNodes: droppedNodes,
            keptGroups: keptGroups.count,
            droppedMembers: droppedMembers
        )
    }

    /// 把某个顶层键整段替换成结构值。保留原 header 行以维持注释与行内写法。
    private func setSection(_ doc: YAMLDocument, key: String, value: YAMLValue) {
        var lines = YAMLEmitter.emitValue(value, indent: 2)
        // 空数组时 emitValue 返回 ["  []"]，对顶层键应写成 `key: []`。
        if case .array(let arr) = value, arr.isEmpty {
            lines = []
        }
        doc.setBlock(key, lines)
    }

    /// 返回可分享的文件名。
    public static func exportFileName(subscriptionName: String) -> String {
        let base = subscriptionName
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let safe = base.isEmpty ? "config" : base
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "")
        return "\(safe)-\(stamp).yaml"
    }
}
