#!/usr/bin/env python3
"""在 Godbolt 的 swift59 上真实编译并运行核心层，跑行为断言。

`typecheck.py` 只回答"能不能编译"。这个脚本回答"行为对不对"：
把 Core/Models/Services 拼成一个可执行程序，附带 fixture 与一小段
`main` 断言代码，然后把真实输出取回来比对。

用法：
  python tools/runcheck.py                 # 跑全部检查
  python tools/runcheck.py --keep          # 保留生成的临时源文件
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
FIXTURE = os.path.join(ROOT, 'fixtures', 'mihomo-sample.yaml')

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

STRIP_IMPORTS = frozenset(('import Combine', 'import SwiftUI', 'import UIKit'))
PROXY = os.environ.get('HTTPS_PROXY') or 'http://127.0.0.1:7897'
COMPILER = 'swift59'


def read_source(rel: str) -> str:
    path = os.path.join(SRC, *rel.split('/'))
    with open(path, 'r', encoding='utf-8') as f:
        text = f.read()
    return '\n'.join(
        '' if line.strip() in STRIP_IMPORTS else line for line in text.split('\n')
    )


def swift_string_literal(text: str) -> str:
    # 用 Swift 的原始多行字符串（井号包裹的三引号），
    # 避免样本里的反斜杠与插值语法被编译器解释。
    delimiter = '#' * 3
    quotes = '"' * 3
    if delimiter + quotes in text or quotes + delimiter in text:
        raise SystemExit('fixture 含有与原始字符串分隔符冲突的序列')
    return delimiter + quotes + '\n' + text + '\n' + quotes + delimiter


def build_program(fixture: str) -> str:
    parts = []
    parts.append('import Foundation')
    parts.append('// ==== 由 tools/runcheck.py 生成，不参与 App 构建 ====')
    shim = os.path.join(HERE, 'typecheck_shim.swift')
    if os.path.exists(shim):
        with open(shim, 'r', encoding='utf-8') as f:
            parts.append(f.read())
    for rel in CORE_FILES:
        parts.append(f'// >>>>> {rel}')
        parts.append(read_source(rel))
        parts.append(f'// <<<<< {rel}')

    parts.append('// >>>>> FIXTURE')
    parts.append('let fixtureText: String = ' + swift_string_literal(fixture))
    parts.append('// <<<<< FIXTURE')

    parts.append(open(os.path.join(HERE, 'runcheck_main.swift'), 'r', encoding='utf-8').read())
    return '\n'.join(parts)


def post(url: str, payload: dict, timeout: int = 300) -> dict:
    req = urllib.request.Request(
        url,
        data=json.dumps(payload).encode('utf-8'),
        method='POST',
    )
    req.add_header('Content-Type', 'application/json')
    req.add_header('Accept', 'application/json')
    req.add_header('User-Agent', 'clashmgr-runcheck/1.0')
    opener = urllib.request.build_opener(
        urllib.request.ProxyHandler({'http': PROXY, 'https': PROXY})
    )
    with opener.open(req, timeout=timeout) as r:
        return json.loads(r.read().decode('utf-8'))


def log(msg: str) -> None:
    sys.stdout.write(msg + '\n')
    sys.stdout.flush()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('--keep', action='store_true')
    args = ap.parse_args()

    with open(FIXTURE, 'r', encoding='utf-8') as f:
        fixture = f.read()
    # 末尾换行会让原始字符串多一行，统一剥掉。
    fixture = fixture.rstrip('\n')

    program = build_program(fixture)
    log(f'source chars={len(program)}  lines={program.count(chr(10)) + 1}')

    out_path = os.path.join(HERE, '_runcheck_generated.swift')
    if args.keep:
        with open(out_path, 'w', encoding='utf-8') as f:
            f.write(program)
        log(f'wrote {out_path}')

    payload = {
        'source': program,
        'options': {
            'userArguments': '',
            'filters': {'execute': True},
        },
        'lang': 'swift',
        'allowStoreCodeDebug': True,
    }
    try:
        res = post(f'https://godbolt.org/api/compiler/{COMPILER}/compile', payload)
    except Exception as e:  # noqa: BLE001
        log(f'REQUEST FAILED: {e}')
        return 3

    exec_result = res.get('execResult') or {}
    build_failed = res.get('code') != 0 or not exec_result
    if build_failed:
        log(f'BUILD FAILED exit={res.get("code")}')
        for item in res.get('stderr') or []:
            text = item.get('text', '')
            if text.strip():
                log(text)
        return 1
    stdout_lines = [x.get('text', '') for x in exec_result.get('stdout') or []]
    stderr_lines = [x.get('text', '') for x in exec_result.get('stderr') or []]

    log(f'exec code={exec_result.get("code")} timedOut={exec_result.get("timedOut")}')
    for line in stdout_lines:
        log(line)
    if stderr_lines:
        log('--- runtime stderr ---')
        for line in stderr_lines:
            log(line)

    if exec_result.get('code') != 0:
        log('RUNTIME FAIL')
        return 1

    failures = [l for l in stdout_lines if l.startswith('FAIL')]
    if failures:
        log(f'RUNCHECK FAIL ({len(failures)} 条)')
        return 1

    log('RUNCHECK OK')
    return 0


if __name__ == '__main__':
    sys.exit(main())
