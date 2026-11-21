// 由 tools/runcheck.py 拼接进核心层源码后运行。
// 只在 Godbolt 上执行，不参与 App 构建。
//
// 断言基准来自 PyYAML 对同一 fixture 的独立解析结果：
//   top keys=39  proxies=55  groups=5  rules=10
//   proxy-providers=3  rule-providers=4
//   first proxy = socks/socks5
//   group names = auto, fallback-auto, load-balance, Proxy, UseProvider
//   first rule = RULE-SET,rule1,REJECT
//   last rule  = SUB-RULE,(AND,((NETWORK,UDP))),sub-rule-name2

var failures = 0
var checks = 0

func check(_ label: String, _ actual: Any, _ expected: Any) {
    checks += 1
    let a = "\(actual)"
    let e = "\(expected)"
    if a != e {
        failures += 1
        print("FAIL \(label): got \(a), want \(e)")
    }
}

func checkTrue(_ label: String, _ cond: Bool) {
    checks += 1
    if !cond {
        failures += 1
        print("FAIL \(label): expected true")
    }
}

func section(_ name: String) {
    print("---- \(name)")
}

// ============================================================
section("A. 字节级往返")
// fixtureText 去掉了结尾换行；toText() 总会补一个，所以基准补回来。
let fixtureSource = fixtureText + "\n"
let doc = parseDocument(fixtureSource)
let round1 = doc.toText()
checkTrue("A1 round-trip byte exact", round1 == fixtureSource)
checkTrue("A2 idempotent", parseDocument(round1).toText() == fixtureSource)
if round1 != fixtureSource {
    let a = Array(fixtureSource)
    let b = Array(round1)
    var i = 0
    while i < min(a.count, b.count) && a[i] == b[i] { i += 1 }
    print("FAIL A1 first diff at offset \(i) srcLen=\(a.count) outLen=\(b.count)")
    let lo = max(0, i - 60)
    print("FAIL A1 src: " + String(String(a[lo..<min(a.count, i + 60)])))
    print("FAIL A1 out: " + String(String(b[lo..<min(b.count, i + 60)])))
}
check("A3 top-level entries", doc.entries.count, 39)

// ============================================================
section("B. 结构解析（对比 PyYAML 基准）")
let cfg = MihomoConfig.parse(fixtureText)
check("B1 proxies", cfg.proxies.count, 55)
check("B2 groups", cfg.groups.count, 5)
check("B3 rules", cfg.rules.count, 10)
check("B4 first proxy name", cfg.proxies[0].name, "socks")
check("B5 first proxy type", cfg.proxies[0].type, "socks5")
check("B6 group names",
      cfg.groups.map { $0.name }.joined(separator: ","),
      "auto,fallback-auto,load-balance,Proxy,UseProvider")
check("B7 first rule type", cfg.rules[0].type, "RULE-SET")
check("B8 first rule payload", cfg.rules[0].payload, "rule1")
check("B9 first rule target", cfg.rules[0].target, "REJECT")
check("B10 last rule type", cfg.rules[9].type, "SUB-RULE")
check("B11 last rule payload", cfg.rules[9].payload, "(AND,((NETWORK,UDP)))")
check("B12 last rule target", cfg.rules[9].target, "sub-rule-name2")

// proxy-providers / rule-providers 顶层块必须存在
checkTrue("B13 proxy-providers block", doc.get("proxy-providers") != nil)
checkTrue("B14 rule-providers block", doc.get("rule-providers") != nil)
checkTrue("B15 listeners block", doc.get("listeners") != nil)
checkTrue("B16 dns block", doc.get("dns") != nil)
checkTrue("B17 tun block", doc.get("tun") != nil)
checkTrue("B18 sniffer block", doc.get("sniffer") != nil)

// ============================================================
section("C. 重发射：只改 proxies / proxy-groups / rules")
var emittedOK = true
if let proxiesBlock = doc.get("proxies") {
    let value = entryValue(doc, "proxies")
    if let v = value {
        let emitted = YAMLEmitter.emitValue(v, indent: 2)
        // 发射后的文本必须能被本解析器再解析，且节点数一致
        let rebuilt = "proxies:\n" + emitted.joined(separator: "\n") + "\n"
        let reparsed = parseDocument(rebuilt)
        if let rv = entryValue(reparsed, "proxies"), case .array(let arr) = rv {
            check("C1 proxies reparse count", arr.count, 55)
            if let m = arr[0].mapValue {
                check("C2 reparse first name", m["name"]?.scalarText ?? "", "socks")
            } else {
                emittedOK = false
                print("FAIL C2: first reparse item is not a map")
            }
        } else {
            emittedOK = false
            print("FAIL C1: reparse of emitted proxies failed")
        }
    } else {
        emittedOK = false
        print("FAIL C0: entryValue(proxies) nil")
    }
    _ = proxiesBlock
} else {
    emittedOK = false
    print("FAIL C0: no proxies block")
}

// 发射 → 再解析幂等（emit(parse(x)) == emit(parse(emit(parse(x))))）
if let v = entryValue(doc, "rules") {
    let e1 = YAMLEmitter.emitValue(v, indent: 2)
    let text1 = "rules:\n" + e1.joined(separator: "\n") + "\n"
    let v2 = entryValue(parseDocument(text1), "rules")
    let e2 = v2.map { YAMLEmitter.emitValue($0, indent: 2) } ?? []
    checkTrue("C3 rules emit stable", e1 == e2)
    check("C4 rules emit line count", e1.count, 10)
}

// ============================================================
section("D. 规则匹配")
func matchLine(_ input: String) -> String {
    guard let parsed = RuleMatcher.inferInput(input) else { return "NOINPUT" }
    let r = RuleMatcher.test(parsed, rules: cfg.rules)
    if let rule = r.matchedRule {
        return "\(r.matchedIndex ?? -1)|\(rule.type)|\(rule.target)"
    }
    return "NOMATCH"
}

// 样本 10 条规则里，离线无法判定的有 4 条：
//   RULE-SET / IP-ASN / 两条 SUB-RULE，其余都能判定但不命中。
let r1 = RuleMatcher.test(RuleMatcher.inferInput("www.example.com")!, rules: cfg.rules)
check("D1 example.com skipped count", r1.skipped.count, 4)
check("D2 example.com no match", r1.matchedIndex == nil, true)
// 规则 3/4/5 应能命中（baidu / google / wildcard）
check("D2b suffix rule hit",
      RuleMatcher.test(RuleMatcher.inferInput("x.baidu.com")!, rules: cfg.rules).matchedIndex ?? -1, 3)
check("D2c keyword rule hit",
      RuleMatcher.test(RuleMatcher.inferInput("www.google.co.jp")!, rules: cfg.rules).matchedIndex ?? -1, 4)
check("D2d wildcard rule hit",
      RuleMatcher.test(RuleMatcher.inferInput("test.a.mihomo.com")!, rules: cfg.rules).matchedIndex ?? -1, 5)

// 自建小规则集验证各类型
let custom: [Rule] = [
    Rule.parse("DOMAIN-SUFFIX,example.com,Proxy")!,
    Rule.parse("DOMAIN-KEYWORD,google,DIRECT")!,
    Rule.parse("IP-CIDR,10.0.0.0/8,DIRECT,no-resolve")!,
    Rule.parse("DOMAIN,exact.test,REJECT")!,
    Rule.parse("MATCH,Proxy")!,
]
func matchCustom(_ s: String) -> String {
    let p = RuleMatcher.inferInput(s)!
    let r = RuleMatcher.test(p, rules: custom)
    return "\(r.matchedIndex ?? -1)|\(r.matchedRule?.target ?? "nil")"
}
check("D3 suffix hit", matchCustom("a.example.com"), "0|Proxy")
check("D4 exact-on-suffix-not-hit", matchCustom("example.com"), "0|Proxy")
check("D5 keyword", matchCustom("www.google.co.jp"), "1|DIRECT")
check("D6 ip cidr", matchCustom("10.1.2.3"), "2|DIRECT")
check("D7 ip outside cidr falls to MATCH", matchCustom("8.8.8.8"), "4|Proxy")
check("D8 domain exact", matchCustom("exact.test"), "3|REJECT")
check("D9 url input", matchCustom("https://sub.example.com/path?q=1"), "0|Proxy")
checkTrue("D10 wildcard", RuleMatcher.evaluate(
    Rule.parse("DOMAIN-WILDCARD,*.example.com,Proxy")!,
    input: RuleMatcher.inferInput("a.example.com")!,
    host: "a.example.com") == .matched)

// 逻辑规则必须被判为 unknown 而不是静默放过
let logicRules: [Rule] = [Rule.parse("AND,((DOMAIN,a.com),(NETWORK,TCP)),Proxy")!,
                          Rule.parse("MATCH,DIRECT")!]
let lr = RuleMatcher.test(RuleMatcher.inferInput("a.com")!, rules: logicRules)
check("D11 logic rule skipped", lr.skipped.count, 1)
check("D12 falls to MATCH", lr.viaFallback, true)

// ============================================================
section("E. 导出")
let keep: Set<String> = Set(cfg.proxies.prefix(3).map { $0.name })
let ex = Exporter().export(cfg, options: Exporter.Options(keepNodeNames: keep, includeRules: true))
check("E1 kept nodes", ex.keptNodes, 3)
check("E2 dropped nodes", ex.droppedNodes, 52)
let exDoc = parseDocument(ex.text)
checkTrue("E3 exported text reparses", exDoc.entries.count > 0)
let exCfg = MihomoConfig.parse(ex.text)
check("E4 exported proxies", exCfg.proxies.count, 3)
check("E5 exported rules preserved", exCfg.rules.count, 10)
checkTrue("E6 exported round-trip byte exact", parseDocument(ex.text).toText() == ex.text)
// 未被引用的段落必须原样保留
checkTrue("E7 dns preserved", ex.text.contains("\ndns:"))
checkTrue("E8 tun preserved", ex.text.contains("\ntun:"))
// 策略组里被删掉的成员必须被清理
checkTrue("E9 no dangling member", !ex.text.contains("socks4"))

let exNoRules = Exporter().export(cfg, options: Exporter.Options(keepNodeNames: keep, includeRules: false))
checkTrue("E10 rules removed", parseDocument(exNoRules.text).get("rules") == nil)

// ============================================================
section("F. 订阅 userinfo")
if let info = SubscriptionUserInfo.parse("upload=1024; download=2048; total=1073741824; expire=1893456000") {
    check("F1 upload", info.upload ?? -1, 1024)
    check("F2 download", info.download ?? -1, 2048)
    check("F3 total", info.total ?? -1, 1073741824)
    check("F4 used", info.used ?? -1, 3072)
} else {
    failures += 1
    print("FAIL F1: parse returned nil")
}
checkTrue("F5 tolerant parse", SubscriptionUserInfo.parse("upload=1,download=2,total=3") != nil)
checkTrue("F6 nil on garbage", SubscriptionUserInfo.parse("hello") == nil)

// ============================================================
section("G. 边角 YAML 用例")
let edge1 = "a:\n  - |\n    x\n    y\nb: 1\n"
let d1 = parseDocument(edge1)
if let v = entryValue(d1, "a"), case .array(let arr) = v, let s = arr.first?.scalarText {
    check("G1 seq block scalar", s, "x\ny\n")
} else {
    failures += 1
    print("FAIL G1: seq block scalar")
}
let edge2 = "key: it's fine # c\n"
check("G2 apostrophe comment", entryValue(parseDocument(edge2), "key")?.scalarText ?? "", "it's fine")
let edge3 = "l:\n  - a: 1\n    b: [x, y]\n"
if let v = entryValue(parseDocument(edge3), "l"), case .array(let arr) = v,
   let m = arr.first?.mapValue {
    check("G3 nested seq map", m["a"]?.intValue ?? -1, 1)
    check("G4 nested flow", (m["b"]?.stringList ?? []).joined(separator: ","), "x,y")
} else {
    failures += 1
    print("FAIL G3: nested seq map")
}

// ============================================================
print("============================================")
print("checks=\(checks) failures=\(failures)")
if failures == 0 {
    print("RUNCHECK MAIN OK")
} else {
    print("RUNCHECK MAIN FAIL")
}
