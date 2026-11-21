import XCTest
@testable import ClashMgr

/// 模型层与服务层测试：配置解析、规则匹配、导出裁剪、订阅信息解析。
///
/// 这些用例覆盖「点开 App 之后真正会跑的代码路径」，比纯粹的 YAML 往返更接近用户可见行为。
final class ModelTests: XCTestCase {

    // MARK: - 配置解析

    private let sample = """
    port: 7890
    mode: rule
    proxies:
      - name: hk
        type: ss
        server: hk.example.com
        port: 443
        cipher: aes-128-gcm
        password: pw
      - name: jp
        type: vmess
        server: jp.example.com
        port: 443
        uuid: 11111111-2222-3333-4444-555555555555
    proxy-groups:
      - name: 自动
        type: url-test
        proxies: [hk, jp]
        url: http://cp.cloudflare.com/generate_204
        interval: 300
      - name: 手动
        type: select
        proxies: [自动, hk, DIRECT]
    rules:
      - DOMAIN-SUFFIX,example.com,DIRECT
      - DOMAIN-KEYWORD,google,自动
      - IP-CIDR,1.1.1.0/24,手动
      - MATCH,自动
    """

    func testConfigParsesProxiesGroupsAndRules() {
        let cfg = MihomoConfig.parse(sample)
        XCTAssertEqual(cfg.proxies.count, 2)
        XCTAssertEqual(cfg.groups.count, 2)
        XCTAssertEqual(cfg.rules.count, 4)

        XCTAssertEqual(cfg.proxy(named: "hk")?.type, "ss")
        XCTAssertEqual(cfg.proxy(named: "hk")?.port, 443)
        XCTAssertEqual(cfg.proxy(named: "jp")?.server, "jp.example.com")

        XCTAssertEqual(cfg.group(named: "自动")?.groupType, .urlTest)
        XCTAssertEqual(cfg.group(named: "手动")?.groupType, .select)
        XCTAssertEqual(cfg.group(named: "自动")?.members, ["hk", "jp"])

        XCTAssertEqual(cfg.rules.first?.type, "DOMAIN-SUFFIX")
        XCTAssertEqual(cfg.rules.first?.payload, "example.com")
        XCTAssertEqual(cfg.rules.first?.target, "DIRECT")
        XCTAssertEqual(cfg.rules.last?.type, "MATCH")
    }

    func testProxyTypesAreDeduplicated() {
        let cfg = MihomoConfig.parse(sample)
        XCTAssertEqual(cfg.proxyTypes.sorted(), ["ss", "vmess"])
    }

    func testBuiltinTargets() {
        XCTAssertTrue(MihomoConfig.isBuiltinTarget("DIRECT"))
        XCTAssertTrue(MihomoConfig.isBuiltinTarget("reject"))
        XCTAssertTrue(MihomoConfig.isBuiltinTarget("REJECT-DROP"))
        XCTAssertFalse(MihomoConfig.isBuiltinTarget("自动"))
    }

    /// 嵌套组要能逐层展开出真实节点，并且不能因为环而死循环。
    func testResolveMembersFlattensNestedGroups() {
        let cfg = MihomoConfig.parse(sample)
        XCTAssertEqual(cfg.resolveMembers(ofGroup: "手动"), ["hk", "jp", "hk", "DIRECT"])
    }

    /// 界面用的展开：同一节点只出现一次（`resolveMembers` 会重复）。
    func testFlattenedMembersDeduplicates() {
        let cfg = MihomoConfig.parse(sample)
        XCTAssertEqual(cfg.flattenedMembers(of: "手动"), ["hk", "jp", "DIRECT"])
        XCTAssertEqual(cfg.flattenedMembers(of: "自动"), ["hk", "jp"])
    }

    func testFlattenedMembersSurvivesCycle() {
        let cyc = """
        proxies:
          - name: a
            type: ss
            server: a.com
            port: 1
        proxy-groups:
          - name: g1
            type: select
            proxies: [g2]
          - name: g2
            type: select
            proxies: [g1, a]
        """
        let cfg = MihomoConfig.parse(cyc)
        XCTAssertEqual(cfg.flattenedMembers(of: "g1"), ["a"])
    }

    func testResolveMembersSurvivesCycle() {
        let cyc = """
        proxies:
          - name: a
            type: ss
            server: a.com
            port: 1
        proxy-groups:
          - name: g1
            type: select
            proxies: [g2]
          - name: g2
            type: select
            proxies: [g1, a]
        """
        let cfg = MihomoConfig.parse(cyc)
        // 只要不崩且能在有限深度内返回就合格。
        let out = cfg.resolveMembers(ofGroup: "g1")
        XCTAssertFalse(out.isEmpty)
        XCTAssertTrue(out.contains("a") || out.isEmpty)
    }

    func testGroupsReferencing() {
        let cfg = MihomoConfig.parse(sample)
        XCTAssertEqual(cfg.groupsReferencing(node: "hk"), ["自动", "手动"])
    }

    func testRuleTargetsExcludesBuiltins() {
        let cfg = MihomoConfig.parse(sample)
        XCTAssertEqual(cfg.ruleTargets, ["手动", "自动"])
    }

    // MARK: - 规则匹配

    func testRuleMatcherHitsSuffixRule() {
        let cfg = MihomoConfig.parse(sample)
        guard let parsed = RuleMatcher.inferInput("www.example.com") else {
            return XCTFail("未能识别输入")
        }
        let result = RuleMatcher.test(parsed, rules: cfg.rules)
        XCTAssertEqual(result.matchedIndex, 0)
        XCTAssertEqual(result.matchedRule?.target, "DIRECT")
    }

    func testRuleMatcherFallsThroughToMatch() {
        let cfg = MihomoConfig.parse(sample)
        guard let parsed = RuleMatcher.inferInput("nothing.matches.here") else {
            return XCTFail("未能识别输入")
        }
        let result = RuleMatcher.test(parsed, rules: cfg.rules)
        XCTAssertEqual(result.matchedRule?.type, "MATCH")
        XCTAssertTrue(result.viaFallback)
    }

    func testRuleMatcherAcceptsURL() {
        let cfg = MihomoConfig.parse(sample)
        guard let parsed = RuleMatcher.inferInput("https://www.google.com/search?q=1") else {
            return XCTFail("未能识别 URL")
        }
        let result = RuleMatcher.test(parsed, rules: cfg.rules)
        XCTAssertEqual(result.matchedRule?.type, "DOMAIN-KEYWORD")
    }

    func testRuleMatcherHandlesIPv4CIDR() {
        let cfg = MihomoConfig.parse(sample)
        guard let parsed = RuleMatcher.inferInput("1.1.1.7") else {
            return XCTFail("未能识别 IP")
        }
        let result = RuleMatcher.test(parsed, rules: cfg.rules)
        XCTAssertEqual(result.matchedRule?.type, "IP-CIDR")
        XCTAssertEqual(result.matchedRule?.target, "手动")
    }

    // MARK: - 导出

    func testExportKeepsOnlySelectedNodesAndPrunesGroups() {
        let cfg = MihomoConfig.parse(sample)
        let result = Exporter().export(cfg, options: .init(keepNodeNames: ["hk"]))
        XCTAssertEqual(result.keptNodes, 1)
        XCTAssertEqual(result.droppedNodes, 1)

        // 导出结果必须还能被自己解析回来。
        let again = MihomoConfig.parse(result.text)
        XCTAssertEqual(again.proxies.map(\.name), ["hk"])
        XCTAssertFalse(again.groups.isEmpty)

        // 被排除的节点不应再出现在任何组的成员里。
        for g in again.groups {
            XCTAssertFalse(g.members.contains("jp"), "组 \(g.name) 仍引用了已排除节点")
        }
    }

    func testExportCanDropRules() {
        let cfg = MihomoConfig.parse(sample)
        let result = Exporter().export(cfg, options: .init(keepNodeNames: ["hk", "jp"],
                                                           includeRules: false))
        let again = MihomoConfig.parse(result.text)
        XCTAssertTrue(again.rules.isEmpty)
    }

    func testExportKeepsUnrelatedSections() {
        let src = sample + "\ndns:\n  enable: true\n  nameserver:\n    - 1.1.1.1\n"
        let cfg = MihomoConfig.parse(src)
        let result = Exporter().export(cfg, options: .init(keepNodeNames: ["hk"]))
        XCTAssertTrue(result.text.contains("dns:"))
        XCTAssertTrue(result.text.contains("1.1.1.1"))
    }

    func testExportFileNameSanitises() {
        let name = Exporter.exportFileName(subscriptionName: "a/b:c")
        XCTAssertFalse(name.contains("/"))
        XCTAssertFalse(name.contains(":"))
        XCTAssertTrue(name.hasSuffix(".yaml"))
    }

    // MARK: - 订阅信息

    func testSubscriptionUserInfoParsing() {
        let raw = "upload=1024; download=2048; total=1073741824; expire=1893456000"
        guard let info = SubscriptionUserInfo.parse(raw) else {
            return XCTFail("userinfo 解析失败")
        }
        XCTAssertEqual(info.upload, 1024)
        XCTAssertEqual(info.download, 2048)
        XCTAssertEqual(info.total, 1073741824)
        XCTAssertEqual(info.used, 3072)
        XCTAssertNotNil(info.expireDate)
    }

    func testSubscriptionUserInfoToleratesCommas() {
        let raw = "upload=1, download=2, total=10, expire=1893456000"
        let info = SubscriptionUserInfo.parse(raw)
        XCTAssertEqual(info?.used, 3)
    }

    func testSubscriptionUserInfoRejectsGarbage() {
        XCTAssertNil(SubscriptionUserInfo.parse("not a userinfo"))
    }

    func testSubscriptionHostLabel() {
        var sub = Subscription(name: "本地", url: nil, fileName: "x.yaml")
        XCTAssertEqual(sub.hostLabel, "本地配置")
        XCTAssertFalse(sub.isRemote)

        sub = Subscription(name: "远程", url: "https://sub.example.com/a?token=1",
                           fileName: "y.yaml")
        XCTAssertEqual(sub.hostLabel, "sub.example.com")
        XCTAssertTrue(sub.isRemote)
    }

    // MARK: - 设置钳制

    func testSettingsClamping() {
        let settings = AppSettings(defaults: UserDefaults(suiteName: "clashmgr.tests")!)
        settings.concurrency = 999
        XCTAssertEqual(settings.clampedConcurrency, 32)
        settings.concurrency = 0
        XCTAssertEqual(settings.clampedConcurrency, 1)
        settings.timeout = 99
        XCTAssertEqual(settings.clampedTimeout, 30)
        settings.timeout = 0
        XCTAssertEqual(settings.clampedTimeout, 1)
    }
}
