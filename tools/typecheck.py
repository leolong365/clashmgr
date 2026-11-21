#!/usr/bin/env python3
"""用 Godbolt 的 swift59 编译器做类型检查（本机无法安装 Swift 工具链）。

只检查 Foundation-only 的代码（Core / Models / Services / AppState）。
SwiftUI 视图层无法在 Linux 上类型检查，用 syntaxcheck.py 做 `-parse` 兜底。

用法:
  python tools/typecheck.py                 # 检查核心层 + AppState
  python tools/typecheck.py --file A.swift  # 只看指定文件
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, '..'))
SRC = os.path.join(ROOT, 'ios', 'ClashMgr')

# 检查顺序：先基础类型，再依赖它们的文件
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

# Linux 上没有 Combine / SwiftUI / UIKit 模块。这些 import 由
# typecheck_shim.swift 提供最小桩件替代，所以把 import 行剥掉再送编译器。
STRIP_IMPORTS = frozenset(('import Combine', 'import SwiftUI', 'import UIKit'))

PROXY = os.environ.get('HTTPS_PROXY') or os.environ.get('https_proxy') or 'http://127.0.0.1:7897'
COMPILER = 'swift59'


def post(url: str, payload: dict, timeout: int = 300) -> dict:
    body = json.dumps(payload).encode('utf-8')
    req = urllib.request.Request(url, data=body, method='POST')
    req.add_header('Content-Type', 'application/json')
    req.add_header('Accept', 'application/json')
    req.add_header('User-Agent', 'clashmgr-typecheck/1.0')
    opener = urllib.request.build_opener(
        urllib.request.ProxyHandler({'http': PROXY, 'https': PROXY})
    )
    with opener.open(req, timeout=timeout) as r:
        return json.loads(r.read().decode('utf-8'))


def read_source(rel: str) -> str:
    """读文件并剥掉 Linux 上不存在的模块 import。"""
    path = os.path.join(SRC, *rel.split('/'))
    with open(path, 'r', encoding='utf-8') as f:
        text = f.read()
    out = []
    for line in text.split('\n'):
        out.append('' if line.strip() in STRIP_IMPORTS else line)
    return '\n'.join(out)


def log(msg: str) -> None:
    sys.stdout.write(msg + '\n')
    sys.stdout.flush()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('--file', action='append', default=None)
    args = ap.parse_args()

    files = args.file if args.file else CORE_FILES
    chunks = []

    shim = os.path.join(HERE, 'typecheck_shim.swift')
    if os.path.exists(shim):
        with open(shim, 'r', encoding='utf-8') as f:
            chunks.append(f.read())

    used = 0
    for rel in files:
        path = os.path.join(SRC, *rel.split('/'))
        if not os.path.exists(path):
            log(f'SKIP (missing): {rel}')
            continue
        # 分隔注释必须独立成行，否则会吞掉下一个文件的首行。
        chunks.append(f'// ==== {rel} ====')
        chunks.append(read_source(rel))
        used += 1

    if used == 0:
        log('no sources found')
        return 2

    source = '\n'.join(chunks)
    log(f'files={used}  chars={len(source)}  lines={source.count(chr(10)) + 1}')

    payload = {
        'source': source,
        'options': {'userArguments': '-typecheck', 'filters': {'execute': False}},
        'lang': 'swift',
        'allowStoreCodeDebug': True,
    }
    try:
        res = post(f'https://godbolt.org/api/compiler/{COMPILER}/compile', payload)
    except Exception as e:  # noqa: BLE001
        log(f'REQUEST FAILED: {e}')
        return 3

    code = res.get('code', -1)
    log(f'compile exit={code}')
    stderr = res.get('stderr') or []
    printed = False
    for item in stderr:
        text = item.get('text', '')
        if text.strip():
            log(text)
            printed = True

    if code != 0 or printed:
        log('TYPECHECK FAIL')
        return 1
    log('TYPECHECK OK')
    return 0


if __name__ == '__main__':
    sys.exit(main())
