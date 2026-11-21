#!/usr/bin/env python3
"""在 Godbolt 上真正跑一遍 ClashMgrTests 里的 XCTest 用例。

为什么需要：本机没有 Xcode，CI 是唯一的真实编译环境。但 Godbolt 的
`filters.execute = true` 会编译成可执行文件并运行，而且 Linux 版
swift-corelibs-xctest 可用，所以可以在推 CI 之前把 XCTest 用例跑一遍，
避免「测试代码写错 → CI 红 → 改一轮」的往返。

用法：
    cd /e/clash/clashmgr
    PYTHONIOENCODING=utf-8 python tools/runtests.py

必须带 PYTHONIOENCODING=utf-8，否则打印中文断言信息时 Windows GBK stdout 会炸。
必须能连代理 http://127.0.0.1:7897。
"""
import json
import os
import re
import sys
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, '..'))
SRC = os.path.join(ROOT, 'ios', 'ClashMgr')
TESTS = os.path.join(ROOT, 'ios', 'ClashMgrTests')

CORE_FILES = [
    'Core/YAMLValue.swift',
    'Core/YAMLLexer.swift',
    'Core/YAMLParser.swift',
    'Core/YAMLEmitter.swift',
    'Models/ProxyModels.swift',
    'Models/RuleMatcher.swift',
    'Models/MihomoConfig.swift',
    'Models/Subscription.swift',
    'Services/AppSettings.swift',
    'Services/ConfigStore.swift',
    'Services/SubscriptionFetcher.swift',
    'Services/LatencyTester.swift',
    'Services/Exporter.swift',
]

TEST_FILES = ['YAMLTests.swift', 'ModelTests.swift']

STRIP_IMPORTS = frozenset((
    'import Combine',
    'import SwiftUI',
    'import UIKit',
    '@testable import ClashMgr',
))

PROXY = 'http://127.0.0.1:7897'


def log(msg):
    sys.stdout.write(msg + '\n')
    sys.stdout.flush()


def read_source(path, rel_for_log):
    if not os.path.exists(path):
        log('SKIP missing ' + rel_for_log)
        return None
    out = []
    with open(path, encoding='utf-8') as fh:
        for line in fh.read().splitlines():
            if line.strip() in STRIP_IMPORTS:
                continue
            out.append(line)
    return '\n'.join(out)


def find_test_classes(source):
    """返回 [(类名, [测试方法名...]), ...]，保持文件内顺序。"""
    result = []
    class_re = re.compile(r'final class (\w+): XCTestCase')
    matches = list(class_re.finditer(source))
    for i, m in enumerate(matches):
        start = m.end()
        end = matches[i + 1].start() if i + 1 < len(matches) else len(source)
        body = source[start:end]
        names = re.findall(r'func (test\w+)\s*\(\s*\)', body)
        result.append((m.group(1), names))
    return result


def make_main(classes):
    ext = []
    args = []
    for klass, names in classes:
        if not names:
            continue
        entries = ',\n            '.join('("%s", %s.%s)' % (n, klass, n) for n in names)
        ext.append(
            'extension ' + klass + ' {\n'
            '    static var __allTests: [(String, (' + klass + ') -> () throws -> Void)] {\n'
            '        return [\n            ' + entries + ',\n        ]\n'
            '    }\n'
            '}\n')
        args.append('testCase(' + klass + '.__allTests)')
    return '\n'.join(ext) + '\nXCTMain([' + ', '.join(args) + '])\n'


def main():
    shim = os.path.join(HERE, 'typecheck_shim.swift')
    chunks = []
    if os.path.exists(shim):
        with open(shim, encoding='utf-8') as fh:
            chunks.append(fh.read())

    count = 0
    for rel in CORE_FILES:
        body = read_source(os.path.join(SRC, rel), rel)
        if body is None:
            continue
        chunks.append('// ==== ' + rel + ' ====')
        chunks.append(body)
        count += 1

    classes = []
    for rel in TEST_FILES:
        test_src = read_source(os.path.join(TESTS, rel), 'ClashMgrTests/' + rel)
        if test_src is None:
            continue
        classes.extend(find_test_classes(test_src))
        chunks.append('// ==== ClashMgrTests/' + rel + ' ====')
        chunks.append(test_src)
        count += 1

    if not classes:
        raise SystemExit('没有找到任何 XCTestCase 子类')
    total_cases = sum(len(n) for _, n in classes)
    if total_cases == 0:
        raise SystemExit('测试文件里没有 func testXXX()')

    chunks.append('// ==== main ====')
    chunks.append(make_main(classes))

    source = '\n'.join(chunks)
    log('files=%d classes=%d cases=%d chars=%d'
        % (count, len(classes), total_cases, len(source)))

    body = json.dumps({
        'source': source,
        'options': {
            'userArguments': '',
            'filters': {'execute': True},
        },
        'lang': 'swift',
        'allowStoreCodeDebug': True,
    }).encode('utf-8')

    opener = urllib.request.build_opener(
        urllib.request.ProxyHandler({'http': PROXY, 'https': PROXY}))
    req = urllib.request.Request(
        'https://godbolt.org/api/compiler/swift59/compile',
        data=body,
        headers={'Content-Type': 'application/json', 'Accept': 'application/json'})
    res = json.loads(opener.open(req, timeout=300).read().decode('utf-8'))

    code = res.get('code')
    stderr = res.get('stderr') or []
    if code != 0 or stderr:
        log('BUILD FAILED exit=%s' % code)
        for item in stderr:
            log('  ' + str(item.get('text')))
        return 1

    exec_result = res.get('execResult')
    if exec_result is None:
        log('execResult 缺失：编译器没有执行（检查 filters.execute）')
        return 1

    for item in (exec_result.get('stdout') or []):
        log(str(item.get('text')))
    for item in (exec_result.get('stderr') or []):
        log('  ' + str(item.get('text')))

    log('program exit=%s' % exec_result.get('code'))
    if exec_result.get('code') != 0:
        return 1
    log('RUNTESTS OK')
    return 0


if __name__ == '__main__':
    sys.exit(main())
