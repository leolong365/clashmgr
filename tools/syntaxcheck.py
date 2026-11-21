#!/usr/bin/env python3
"""用 Godbolt 的 swift59 编译器做语法检查（-parse）。

`-typecheck` 需要 SwiftUI/UIKit 模块，Linux 上没有，所以视图层无法类型检查；
但 `-parse` 只做语法分析，不解析 import，可以抓出括号/字符串/语法层面的错误。

用法：python tools/syntaxcheck.py
"""
import json
import os
import sys
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, '..'))
SRC = os.path.join(ROOT, 'ios', 'ClashMgr')

FILES = [
    'Views/Components.swift',
    'Views/SubscriptionsView.swift',
    'Views/AddSubscriptionView.swift',
    'Views/ProxiesView.swift',
    'Views/RulesView.swift',
    'Views/RuleTesterView.swift',
    'Views/SettingsView.swift',
    'Views/ExportView.swift',
]

PROXY = 'http://127.0.0.1:7897'
URL = 'https://godbolt.org/api/compiler/swift59/compile'


def main() -> int:
    chunks = []
    missing = []
    for rel in FILES:
        path = os.path.join(SRC, *rel.split('/'))
        if not os.path.exists(path):
            missing.append(rel)
            continue
        with open(path, 'r', encoding='utf-8') as f:
            chunks.append(f.read())

    if missing:
        print('SKIP missing: ' + ', '.join(missing))
    if not chunks:
        print('NO FILES')
        return 1

    source = '\n'.join(chunks)
    print('files=%d  chars=%d' % (len(chunks), len(source)))

    body = {
        'source': source,
        'options': {
            'userArguments': '-parse',
            'filters': {'execute': False},
        },
        'lang': 'swift',
        'allowStoreCodeDebug': True,
    }
    req = urllib.request.Request(
        URL,
        data=json.dumps(body).encode('utf-8'),
        headers={'Content-Type': 'application/json', 'Accept': 'application/json'},
    )
    opener = urllib.request.build_opener(
        urllib.request.ProxyHandler({'https': PROXY, 'http': PROXY})
    )
    with opener.open(req, timeout=180) as resp:
        data = json.loads(resp.read().decode('utf-8'))

    code = data.get('code')
    print('parse exit=%s' % code)
    for entry in data.get('stderr', []):
        text = entry.get('text', '')
        if text:
            print(text)

    if code != 0:
        print('SYNTAX FAIL')
        return 1
    print('SYNTAX OK')
    return 0


if __name__ == '__main__':
    sys.exit(main())
