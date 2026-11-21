#!/usr/bin/env python3
"""把核心源文件 + 单元测试文件一起送 Godbolt 做 -typecheck。

目的是在推 CI 之前确认 `ClashMgrTests/YAMLTests.swift` 本身能编译
（CI 里 xcodebuild test 会编译它，写错一个符号就要多跑一轮）。
"""
import json
import os
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
    'App/AppState.swift',
]
TEST_FILES = ['YAMLTests.swift', 'ModelTests.swift']

STRIP_IMPORTS = frozenset((
    'import Combine',
    'import SwiftUI',
    'import UIKit',
    # 拼成单文件后不需要跨模块导入，留着会在 Linux 上报 no such module。
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


def main():
    chunks = []
    shim = os.path.join(HERE, 'typecheck_shim.swift')
    if os.path.exists(shim):
        with open(shim, encoding='utf-8') as fh:
            chunks.append(fh.read())
    total = 0
    for rel in CORE_FILES:
        body = read_source(os.path.join(SRC, rel), rel)
        if body is None:
            continue
        chunks.append('// ==== ' + rel + ' ====')
        chunks.append(body)
        total += 1
    for rel in TEST_FILES:
        body = read_source(os.path.join(TESTS, rel), 'ClashMgrTests/' + rel)
        if body is None:
            continue
        chunks.append('// ==== ClashMgrTests/' + rel + ' ====')
        chunks.append(body)
        total += 1

    source = '\n'.join(chunks)
    log('files=%d chars=%d lines=%d' % (total, len(source), source.count('\n') + 1))

    body = json.dumps({
        'source': source,
        'options': {
            'userArguments': '-typecheck',
            'filters': {'execute': False},
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
    res = json.loads(opener.open(req, timeout=180).read().decode('utf-8'))

    code = res.get('code')
    log('compile exit=%s' % code)
    stderr = res.get('stderr') or []
    if stderr:
        for item in stderr:
            log('  ' + str(item.get('text')))
        return 1
    if code != 0:
        return 1
    log('TESTS TYPECHECK OK')
    return 0


if __name__ == '__main__':
    sys.exit(main())
