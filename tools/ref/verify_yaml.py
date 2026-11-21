"""用真实 mihomo 配置 + 边角用例验证 yaml_lite.py 的正确性。"""
import sys, io, json
sys.path.insert(0, '.')
import yaml as pyyaml
import yaml_lite as Y

FAIL = 0
def check(name, cond, detail=''):
    global FAIL
    if cond:
        print(f'  ok   {name}')
    else:
        FAIL += 1
        print(f'  FAIL {name} {detail}')

def norm(v):
    """把值规范化成可比较的形式：dict/list/scalar。"""
    if isinstance(v, dict):
        return {str(k): norm(x) for k, x in v.items()}
    if isinstance(v, list):
        return [norm(x) for x in v]
    if isinstance(v, bool):
        return v
    if isinstance(v, (int, float)):
        return v
    if v is None:
        return None
    return str(v)

def diff(a, b, path='$'):
    """返回差异列表（前几个），用于定位。"""
    out = []
    def rec(a, b, p):
        if len(out) > 8: return
        if type(a) is not type(b) and not (isinstance(a,(int,float)) and isinstance(b,(int,float))):
            out.append(f'{p}: type {type(a).__name__} != {type(b).__name__} ({a!r} vs {b!r})')
            return
        if isinstance(a, dict):
            ka, kb = set(a), set(b)
            for k in sorted(ka - kb): out.append(f'{p}.{k}: only in lite ({a[k]!r})')
            for k in sorted(kb - ka): out.append(f'{p}.{k}: only in pyyaml ({b[k]!r})')
            for k in sorted(ka & kb): rec(a[k], b[k], f'{p}.{k}')
        elif isinstance(a, list):
            if len(a) != len(b):
                out.append(f'{p}: len {len(a)} != {len(b)}')
                return
            for i, (x, y) in enumerate(zip(a, b)): rec(x, y, f'{p}[{i}]')
        else:
            if a != b: out.append(f'{p}: {a!r} != {b!r}')
    rec(a, b, path)
    return out

print('=== 1. 真实 mihomo 配置 (144KB) ===')
src = open('../../fixtures/mihomo-sample.yaml', encoding='utf-8').read()
doc = Y.parse_document(src)
ref = pyyaml.safe_load(src)
check('顶层键数量', len(doc.entries) == len([k for k in ref]), f'{len(doc.entries)} vs {len(ref)}')

KEYS = ['proxies', 'proxy-groups', 'proxy-providers', 'rule-providers', 'rules', 'sub-rules',
        'listeners', 'dns', 'tun', 'sniffer', 'tunnels', 'hosts', 'experimental', 'tls',
        'geox-url', 'profile', 'authentication', 'external-controller-cors']
for k in KEYS:
    got = norm(Y.entry_value(doc, k))
    want = norm(ref.get(k))
    if got == want:
        print(f'  ok   {k}')
    else:
        print(f'  FAIL {k}')
        FAIL += 1
        for d in diff(got, want, k)[:6]: print('       ', d)

print('\n=== 2. 无损往返（parse -> to_text == 原文）===')
rt = doc.to_text()
check('字节级往返一致', rt == src, f'len {len(rt)} vs {len(src)}')
if rt != src:
    import difflib
    d = list(difflib.unified_diff(src.split('\n'), rt.split('\n'), 'orig', 'rt', lineterm='', n=2))
    print('\n'.join(d[:40]))

print('\n=== 3. 二次往返（幂等）===')
rt2 = Y.parse_document(rt).to_text()
check('二次往返稳定', rt2 == rt)

print('\n=== 4. proxies 深比对 ===')
proxies = Y.entry_value(doc, 'proxies')
refp = ref['proxies']
check('节点数=55', len(proxies) == 55, str(len(proxies)))
bad = 0
for i, p in enumerate(proxies):
    if norm(p) != norm(refp[i]):
        bad += 1
        if bad <= 3:
            print(f'  node[{i}] {p.get("name")} mismatch:')
            for d in diff(norm(p), norm(refp[i]), f'p[{i}]')[:5]: print('       ', d)
check('55 节点全等', bad == 0, f'{bad} bad')

print('\n=== 5. 边角用例 ===')
CASES = [
 ('flow list', 'proxies: [a, b, c]\n', {'proxies': ['a','b','c']}),
 ('flow map', 'x: {a: 1, b: "2"}\n', {'x': {'a': 1, 'b': '2'}}),
 ('nested seq of maps', 'p:\n  - name: a\n    port: 1\n  - name: b\n    port: 2\n',
   {'p': [{'name':'a','port':1},{'name':'b','port':2}]}),
 ('comment after value', 'k: v # note\n', {'k': 'v'}),
 ('hash in url', 'k: "http://a#b"\n', {'k': 'http://a#b'}),
 ('no space hash', 'k: a#b\n', {'k': 'a#b'}),
 ('quoted colon', 'k: "a: b"\n', {'k': 'a: b'}),
 ('bool/int/float', 'a: true\nb: false\nc: 12\nd: 1.5\ne: null\nf: ~\n',
   {'a': True,'b': False,'c':12,'d':1.5,'e':None,'f':None}),
 ('empty value -> null', 'k:\n', {'k': None}),
 ('deep nest', 'a:\n  b:\n    c:\n      - 1\n      - 2\n', {'a':{'b':{'c':[1,2]}}}),
 ('seq of seq', 'a:\n  - - 1\n    - 2\n', {'a':[[1,2]]}),
 ('block literal', 'k: |\n  line1\n  line2\n', {'k':'line1\nline2\n'}),
 ('block fold', 'k: >\n  a\n  b\n', {'k':'a b\n'}),
 ('block strip', 'k: |-\n  a\n  b\n', {'k':'a\nb'}),
 ('single quote', "k: 'it''s'\n", {'k': "it's"}),
 ('dash in value', 'k: -1\n', {'k': -1}),
 ('ip:port value', 'server: 1.2.3.4:8080\n', {'server': '1.2.3.4:8080'}),
 ('star value', 'cipher: "*"\n', {'cipher': '*'}),
 ('list of strings flow', 'rules:\n  - MATCH,DIRECT\n  - DOMAIN,a.com,REJECT\n',
   {'rules': ['MATCH,DIRECT', 'DOMAIN,a.com,REJECT']}),
 ('nested flow in seq', 'p:\n  - a: [1, 2]\n    b: {x: y}\n', {'p':[{'a':[1,2],'b':{'x':'y'}}]}),
 ('leading dash string', 'k: "- x"\n', {'k': '- x'}),
 ('url with query', 'url: "https://a.com/p?q=1&r=2"\n', {'url':'https://a.com/p?q=1&r=2'}),
 ('url unquoted', 'url: https://a.com/p?q=1\n', {'url':'https://a.com/p?q=1'}),
 ('key with dot', 'a.b.c: 1\n', {'a.b.c': 1}),
 ('comment only line', '# hi\nk: v\n', {'k': 'v'}),
 ('trailing spaces', 'k: v   \n', {'k': 'v'}),
]
for name, text, want in CASES:
    try:
        d = Y.parse_document(text)
        got = norm({e.key: Y.entry_value(d, e.key) for e in d.entries})
    except Exception as ex:
        got = f'<exception {ex}>'
    if got == norm(want):
        print(f'  ok   {name}')
    else:
        print(f'  FAIL {name}\n         got  {got}\n         want {norm(want)}')
        FAIL += 1

print('\n=== 6. 发射器往返（emit -> 再 parse 得到相同值）===')
for k in ['proxies', 'proxy-groups', 'rules']:
    v = Y.entry_value(doc, k)
    txt = '\n'.join(Y.emit_value(v, 0)) + '\n'
    # 用 pyyaml 解析发射结果，验证语义等价
    try:
        back = norm(pyyaml.safe_load(txt))
    except Exception as ex:
        print(f'  FAIL emit {k}: pyyaml 解析失败 {ex}')
        FAIL += 1
        print(txt[:400])
        continue
    if back == norm(v):
        print(f'  ok   emit {k} ({len(txt)} bytes)')
    else:
        print(f'  FAIL emit {k}')
        FAIL += 1
        for d in diff(back, norm(v), k)[:6]: print('       ', d)

print(f'\n===== 结果: {"ALL PASS" if FAIL == 0 else f"{FAIL} FAILURES"} =====')
sys.exit(1 if FAIL else 0)
