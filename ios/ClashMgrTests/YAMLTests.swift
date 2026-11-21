import XCTest
@testable import ClashMgr

/// YAML 词法 + 文档层 + 结构层测试。
final class YAMLTests: XCTestCase {

    // MARK: - 词法

    func testStripCommentRespectsQuotes() {
        XCTAssertEqual(stripComment("key: value # note"), "key: value")
        XCTAssertEqual(stripComment("key: \"a # b\""), "key: \"a # b\"")
        XCTAssertEqual(stripComment("# whole line"), "")
        XCTAssertEqual(stripComment("key: value#notcomment"), "key: value#notcomment")
    }

    func testStripCommentHandlesApostropheInsidePlainScalar() {
        // 真实订阅里出现过 `it's a secret # comment`：撇号不能开启引号态。
        XCTAssertEqual(stripComment("password: it's a secret # comment"), "password: it's a secret")
    }

    func testFindColonSkipsSchemeAndFlow() {
        // `http://a` 里的冒号不是映射分隔符，找不到时返回 -1。
        XCTAssertEqual(findColon("http://example.com"), -1)
        XCTAssertEqual(findColon("url: http://example.com"), 3)
        // flow 结构内部的冒号要跳过。
        XCTAssertEqual(findColon("m: {a: 1}"), 1)
        // 引号内的冒号跳过。
        XCTAssertEqual(findColon("k: \"a: b\""), 1)
    }

    // MARK: - 往返

    private func roundTrip(_ src: String) {
        // `toText()` 收尾总会保证一个换行，而 Swift 多行字面量不含结尾换行，
        // 所以先把期望值补齐，再比对。
        let expected = src.hasSuffix("\n") ? src : src + "\n"
        let doc = parseDocument(src)
        XCTAssertEqual(doc.toText(), expected, "字节级往返失败")
        // 二次往返必须幂等
        XCTAssertEqual(parseDocument(doc.toText()).toText(), expected)
    }

    func testByteExactRoundTripSimple() {
        roundTrip("""
        mixed-port: 7890
        mode: rule
        proxies:
          - name: a
            type: ss
            port: 443
        rules:
          - MATCH,DIRECT
        """)
    }

    func testRoundTripWithComments() {
        roundTrip("""
        # 顶部注释
        port: 7890

        proxies:
          # 组内注释
          - name: "a"   # 行尾注释
            type: ss
        """)
    }

    func testRoundTripTrailingBlankLinesAreStable() {
        let src = "port: 7890\n\n\n"
        let doc = parseDocument(src)
        // 最后连续空行进 epilogue，不重复膨胀
        XCTAssertEqual(doc.toText(), src)
        XCTAssertEqual(parseDocument(doc.toText()).toText(), src)
    }

    // MARK: - 结构解析

    func testParseNestedMapAndSeq() {
        let src = """
        proxies:
          - name: a
            type: ss
            port: 443
            plugin-opts:
              mode: websocket
              host: example.com
        """
        let doc = parseDocument(src)
        guard let v = entryValue(doc, "proxies"), case .array(let items) = v else {
            return XCTFail("proxies 应为数组")
        }
        XCTAssertEqual(items.count, 1)
        let m = items[0].mapValue
        XCTAssertEqual(m?["name"]?.stringValue, "a")
        XCTAssertEqual(m?["port"]?.intValue, 443)
        XCTAssertEqual(m?["plugin-opts"]?.mapValue?["host"]?.stringValue, "example.com")
    }

    func testParseInlineFlowSequence() {
        let src = """
        proxy-groups:
          - name: g
            type: url-test
            proxies: [a, b, c]
        """
        let doc = parseDocument(src)
        guard let v = entryValue(doc, "proxy-groups"),
              case .array(let items) = v,
              let m = items.first?.mapValue else {
            return XCTFail("proxy-groups 解析失败")
        }
        XCTAssertEqual(m["proxies"]?.stringList, ["a", "b", "c"])
    }

    /// 序列与父键同缩进（`header.User-Agent:` 后直接跟同缩进 `- x`）。
    func testParseSeqAtSameIndentAsParentKey() {
        let src = """
        proxy-providers:
          - name: p
            header:
              User-Agent:
              - "clash.meta"
              - "other"
        """
        let doc = parseDocument(src)
        guard let v = entryValue(doc, "proxy-providers"),
              case .array(let items) = v,
              let m = items.first?.mapValue,
              let header = m["header"]?.mapValue else {
            return XCTFail("proxy-providers 解析失败")
        }
        XCTAssertEqual(header["User-Agent"]?.stringList, ["clash.meta", "other"])
    }

    /// 键后换行再缩进写标量。
    func testParseScalarOnFollowingLine() {
        let src = """
        proxies:
          - name: a
            client-fingerprint:
              chrome
        """
        let doc = parseDocument(src)
        guard let v = entryValue(doc, "proxies"),
              case .array(let items) = v,
              let m = items.first?.mapValue else {
            return XCTFail("解析失败")
        }
        XCTAssertEqual(m["client-fingerprint"]?.stringValue, "chrome")
    }

    // MARK: - 块标量

    func testBlockScalarClipKeepsSingleTrailingNewline() {
        let src = """
        ca: |
          line1
          line2
        other: 1
        """
        let doc = parseDocument(src)
        let v = entryValue(doc, "ca")
        XCTAssertEqual(v?.stringValue, "line1\nline2\n")
    }

    func testBlockScalarStripRemovesTrailingNewline() {
        let src = """
        ca: |-
          line1
          line2
        other: 1
        """
        let doc = parseDocument(src)
        XCTAssertEqual(entryValue(doc, "ca")?.stringValue, "line1\nline2")
    }

    func testFoldedBlockScalar() {
        let src = """
        desc: >
          aaa
          bbb
        other: 1
        """
        let doc = parseDocument(src)
        XCTAssertEqual(entryValue(doc, "desc")?.stringValue, "aaa bbb\n")
    }

    // MARK: - 标量类型

    func testScalarTypes() {
        let src = """
        a: 123
        b: -4.5
        c: true
        d: null
        e: ~
        f: hello
        g: "quoted string"
        h: 1e3
        """
        let doc = parseDocument(src)
        if case .int(let n)? = entryValue(doc, "a") { XCTAssertEqual(n, 123) }
        else { XCTFail("a 应为 int") }
        if case .double(let d)? = entryValue(doc, "b") { XCTAssertEqual(d, -4.5, accuracy: 1e-9) }
        else { XCTFail("b 应为 double") }
        if case .bool(let b)? = entryValue(doc, "c") { XCTAssertTrue(b) }
        else { XCTFail("c 应为 bool") }
        if case .null? = entryValue(doc, "d") {} else { XCTFail("d 应为 null") }
        if case .null? = entryValue(doc, "e") {} else { XCTFail("e 应为 null") }
        XCTAssertEqual(entryValue(doc, "f")?.stringValue, "hello")
        XCTAssertEqual(entryValue(doc, "g")?.stringValue, "quoted string")
        if case .double(let e)? = entryValue(doc, "h") { XCTAssertEqual(e, 1000, accuracy: 1e-9) }
        else { XCTFail("h 应为 double") }
    }

    // MARK: - 修改与回写

    func testSetBlockReplacesOnlyThatSection() {
        let src = """
        port: 7890
        proxies:
          - name: a
            type: ss
        rules:
          - MATCH,DIRECT
        """
        let doc = parseDocument(src)
        doc.setBlock("proxies", ["  - name: b", "    type: vmess"])
        let out = doc.toText()
        XCTAssertTrue(out.contains("port: 7890"))
        XCTAssertTrue(out.contains("- name: b"))
        XCTAssertFalse(out.contains("- name: a"))
        XCTAssertTrue(out.contains("- MATCH,DIRECT"))
    }

    func testRemoveSection() {
        let src = """
        port: 7890
        rules:
          - MATCH,DIRECT
        """
        let doc = parseDocument(src)
        doc.remove("rules")
        let out = doc.toText()
        XCTAssertFalse(out.contains("MATCH"))
        XCTAssertTrue(out.contains("port: 7890"))
    }
}
