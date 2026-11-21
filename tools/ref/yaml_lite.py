"""
参考实现 (oracle)：与 Swift 端 YAMLLite 同算法的 Python 镜像。
用途：在 144KB 真实 mihomo 配置 + 边角用例上验证算法，之后逐行转写为 Swift。
不参与 App 运行。

设计要点
1. 文档层 (Document) 按顶层键切块，每块保留**原始行文本**，to_text() 可字节级还原原文。
   => 导出时 dns/tun/sniffer/证书等敏感段完全不动，不依赖发射器。
2. 结构层 (Parser) 只解析 proxies/proxy-groups/rules 等需要读写的子树。
3. 序列项保留 item_raw(原始行) 与 item_index，导出时按原样切片，进一步降风险。
"""
from __future__ import annotations
import re, sys
from typing import Any, List, Optional, Tuple

class YAMLError(Exception):
    pass

# ---------------------------------------------------------------- 行预处理

CLOSERS = ':-,[{'

def strip_comment(line: str) -> str:
    """去掉行尾注释。只有位于 token 起始处的引号才开启引号段。

    YAML 的 plain scalar 里出现 ' 或 " 时并不开启 quote（如 it's a secret），
    旧实现误判会导致行尾注释吞不掉。
    """
    out: List[str] = []
    quote: Optional[str] = None
    prev_sig = ''            # 最近一个非空白、非引号的字符
    i, n = 0, len(line)
    while i < n:
        c = line[i]
        if quote is not None:
            out.append(c)
            if c == '\\' and quote == '"' and i + 1 < n:
                out.append(line[i + 1]); i += 2; continue
            if c == quote:
                # '' 是单引号内的转义
                if quote == "'" and i + 1 < n and line[i + 1] == "'":
                    out.append("'"); i += 2; continue
                quote = None
            i += 1
            continue
        if c in '"\'' and prev_sig in CLOSERS:
            quote = c; out.append(c); prev_sig = c; i += 1; continue
        if c == '#' and (i == 0 or line[i - 1] in ' \t'):
            break
        out.append(c)
        if c not in ' \t':
            prev_sig = c
        i += 1
    return ''.join(out).rstrip()


def indent_of(line: str) -> int:
    return len(line) - len(line.lstrip(' '))


class Line:
    __slots__ = ('indent', 'text', 'raw', 'no')
    def __init__(self, indent: int, text: str, raw: str, no: int):
        self.indent, self.text, self.raw, self.no = indent, text, raw, no
    def __repr__(self):
        return f'Line({self.indent},{self.text!r})'


def split_lines(src: str) -> List[Line]:
    res: List[Line] = []
    for idx, raw in enumerate(src.split('\n')):
        if raw.endswith('\r'):
            raw = raw[:-1]
        s = strip_comment(raw)
        if s.strip() == '':
            continue
        ind = indent_of(s)
        res.append(Line(ind, s[ind:], raw, idx + 1))
    return res

# ---------------------------------------------------------------- 文档层

class Entry:
    """一个顶层键，保留原始行以便无损回写。"""
    __slots__ = ('key', 'inline', 'header_raw', 'block')
    def __init__(self, key: str, inline: str, header_raw: str, block: List[str]):
        self.key, self.inline, self.header_raw, self.block = key, inline, header_raw, block


class Document:
    def __init__(self, prologue: List[str], entries: List[Entry], epilogue: List[str]):
        self.prologue, self.entries, self.epilogue = prologue, entries, epilogue

    def get(self, key: str) -> Optional[Entry]:
        for e in self.entries:
            if e.key == key:
                return e
        return None

    def set_block(self, key: str, lines: List[str]):
        e = self.get(key)
        if e is None:
            self.entries.append(Entry(key, '', key + ':', lines))
        else:
            e.block = lines

    def remove(self, key: str):
        self.entries = [e for e in self.entries if e.key != key]

    def to_text(self) -> str:
        out: List[str] = list(self.prologue)
        for e in self.entries:
            if e.header_raw is not None:
                out.append(e.header_raw)
            out.extend(e.block)
        out.extend(self.epilogue)
        txt = '\n'.join(out)
        if txt and not txt.endswith('\n'):
            txt += '\n'
        return txt


TOPKEY = re.compile(r'^([A-Za-z0-9_.\-]+)\s*:(\s|$)')


def parse_document(src: str) -> Document:
    raw_lines = src.split('\n')
    prologue: List[str] = []
    entries: List[Entry] = []
    epilogue: List[str] = []
    cur: Optional[Entry] = None
    started = False
    trailing = 0     # cur.block 末尾连续空行数

    for raw in raw_lines:
        line = raw[:-1] if raw.endswith('\r') else raw
        if line.strip() in ('---', '...'):
            if not started:
                prologue.append(line)
            continue
        if indent_of(line) == 0:
            m = TOPKEY.match(line)
            if m:
                started = True
                body = strip_comment(line)
                colon = body.find(':')
                cur = Entry(m.group(1), body[colon + 1:].strip(), line, [])
                entries.append(cur)
                trailing = 0
                continue
        if not started:
            prologue.append(line)
            continue
        if cur is not None:
            cur.block.append(line)
            trailing = trailing + 1 if line.strip() == '' else 0
    if cur is not None and trailing:
        del cur.block[len(cur.block) - trailing:]
        epilogue.extend([''] * trailing)
    return Document(prologue, entries, epilogue)

# ---------------------------------------------------------------- 结构层

class Parser:
    def __init__(self, lines: List[Line]):
        self.lines = lines
        self.i = 0

    # --- 工具
    def at_end(self) -> bool:
        return self.i >= len(self.lines)

    def cur(self) -> Optional[Line]:
        return None if self.at_end() else self.lines[self.i]

    @staticmethod
    def is_seq_item(ln: Line) -> bool:
        return ln.text == '-' or ln.text.startswith('- ')

    # --- 入口：从当前行自动判断类型
    def parse_block(self, min_indent: int) -> Any:
        if self.at_end():
            return None
        ln = self.cur()
        if ln.indent < min_indent:
            return None
        return self.parse_node(ln.indent)

    def parse_node(self, ind: int) -> Any:
        ln = self.cur()
        if ln is None or ln.indent < ind:
            return None
        if self.is_seq_item(ln):
            return self.parse_seq(ln.indent)
        if find_colon(ln.text) >= 0:
            return self.parse_map(ln.indent)
        return self.parse_plain_block(ln.indent)

    # --- 键值映射
    def parse_map(self, ind: int) -> dict:
        out: dict = {}
        while not self.at_end():
            ln = self.cur()
            if ln.indent < ind:
                break
            if ln.indent > ind:
                self.i += 1          # 非法缩进，容错跳过
                continue
            if self.is_seq_item(ln):
                break
            colon = find_colon(ln.text)
            if colon < 0:
                self.i += 1
                continue
            key = unquote(ln.text[:colon].strip())
            rest = ln.text[colon + 1:].strip()
            self.i += 1
            out[key] = self.parse_value_after_key(ind, rest)
        return out

    def parse_value_after_key(self, ind: int, rest: str):
        if rest == '':
            return self.parse_child(ind)
        if rest in ('|', '>', '|-', '>-', '|+', '>+'):
            return self.read_block_scalar(ind, rest)
        return parse_scalar(rest)

    def parse_child(self, ind: int):
        """key: 之后换行。子块缩进可 > ind；若为序列，允许与 key 同缩进。"""
        if self.at_end():
            return None
        ln = self.cur()
        if ln.indent > ind:
            return self.parse_node(ln.indent)
        if ln.indent == ind and self.is_seq_item(ln):
            return self.parse_seq(ind)
        return None

    def read_block_scalar(self, ind: int, style: str) -> str:
        buf: List[str] = []
        base = None
        while not self.at_end():
            ln = self.cur()
            if ln.indent <= ind and ln.text.strip() != '':
                break
            if base is None and ln.text.strip() != '':
                base = ln.indent
            cut = ln.raw[(base if base is not None else ind + 1):]
            buf.append(cut)
            self.i += 1
        body = ' '.join(x.strip() for x in buf if x.strip()) if style[0] == '>' \
               else '\n'.join(buf)
        # clip(|) 保留单个结尾换行；strip(|-)去掉；keep(|+)保留全部
        if style.endswith('-'):
            return body
        if style.endswith('+'):
            return body + '\n'
        return body + '\n' if body else body

    def parse_plain_block(self, ind: int) -> Any:
        """键后换行写出的标量：把 >= ind 的连续非结构行折叠成一个值。"""
        parts: List[str] = []
        while not self.at_end():
            ln = self.cur()
            if ln.indent < ind:
                break
            if ln.indent == ind and self.is_seq_item(ln):
                break
            if find_colon(ln.text) >= 0 and ln.indent == ind:
                break
            parts.append(ln.text.strip())
            self.i += 1
        if not parts:
            return None
        if len(parts) == 1:
            return parse_scalar(parts[0])
        return ' '.join(parts)

    # --- 序列
    def parse_seq(self, ind: int) -> List[Any]:
        items: List[Any] = []
        while not self.at_end():
            ln = self.cur()
            if ln.indent != ind or not self.is_seq_item(ln):
                break
            if ln.text == '-':
                self.i += 1
                items.append(self.parse_child(ind))
                continue
            rest = ln.text[2:]
            lead = len(rest) - len(rest.lstrip(' '))
            rest = rest.strip()
            inner = ind + 2 + lead          # 内联内容的有效缩进
            if rest in ('|', '>', '|-', '>-', '|+', '>+'):
                self.i += 1
                items.append(self.read_block_scalar(ind, rest))
                continue
            if rest.startswith('- ') or rest == '-':
                fake = Line(inner, rest, ln.raw, ln.no)
                self.lines[self.i] = fake
                items.append(self.parse_seq(inner))
                continue
            if find_colon(rest) >= 0:
                fake = Line(inner, rest, ln.raw, ln.no)
                self.lines[self.i] = fake
                items.append(self.parse_map(inner))
                continue
            self.i += 1
            v = parse_scalar(rest)
            # 该标量可能的续行
            cont: List[str] = []
            while not self.at_end():
                nxt = self.cur()
                if nxt.indent <= ind or self.is_seq_item(nxt) or find_colon(nxt.text) >= 0:
                    break
                cont.append(nxt.text.strip()); self.i += 1
            if cont:
                v = ' '.join([str(v)] + cont)
            items.append(v)
        return items


def find_colon(text: str) -> int:
    """映射分隔冒号：后面必须跟空白/行尾，且不在引号或 flow 结构内。"""
    i, n = 0, len(text)
    quote: Optional[str] = None
    depth = 0
    while i < n:
        c = text[i]
        if quote is not None:
            if c == '\\' and quote == '"':
                i += 2; continue
            if c == quote:
                quote = None
            i += 1; continue
        if c in '"\'' and (i == 0 or text[i - 1] in ' ,[{'):
            quote = c; i += 1; continue
        if c in '[{':
            depth += 1; i += 1; continue
        if c in ']}':
            depth -= 1; i += 1; continue
        if c == ':' and depth == 0 and (i + 1 >= n or text[i + 1] in ' \t'):
            return i
        i += 1
    return -1


def unquote(s: str) -> str:
    if len(s) >= 2 and s[0] == s[-1] and s[0] in '"\'':
        body = s[1:-1]
        if s[0] == "'":
            return body.replace("''", "'")
        if '\\' in body:
            out: List[str] = []
            i = 0
            while i < len(body):
                c = body[i]
                if c == '\\' and i + 1 < len(body):
                    nx = body[i + 1]
                    m = {'n': '\n', 't': '\t', 'r': '\r', '"': '"', '\\': '\\', '0': '\0', '/': '/'}
                    out.append(m.get(nx, '\\' + nx)); i += 2; continue
                out.append(c); i += 1
            return ''.join(out)
        return body
    return s


NUM_RE = re.compile(r'^[+-]?\d+$')
FLT_RE = re.compile(r'^[+-]?(\d+\.\d*|\.\d+|\d+)([eE][+-]?\d+)?$')


def parse_scalar(text: str) -> Any:
    t = text.strip()
    if t == '':
        return None
    if t[0] in '[{':
        v, _ = parse_flow(t, 0)
        return v
    if len(t) >= 2 and t[0] == t[-1] and t[0] in '"\'':
        return unquote(t)
    low = t.lower()
    if low in ('null', '~'):
        return None
    if low == 'true':
        return True
    if low == 'false':
        return False
    if NUM_RE.match(t):
        return int(t)
    if FLT_RE.match(t):
        return float(t)
    return t


def parse_flow(text: str, i: int) -> Tuple[Any, int]:
    n = len(text)
    def skip_ws(j):
        while j < n and text[j] in ' \t':
            j += 1
        return j
    i = skip_ws(i)
    if i >= n:
        return None, i
    c = text[i]
    if c == '[':
        i += 1
        arr: List[Any] = []
        while True:
            while i < n and text[i] in ' \t,':
                i += 1
            if i >= n:
                return arr, i
            if text[i] == ']':
                return arr, i + 1
            v, i = parse_flow(text, i)
            arr.append(v)
    if c == '{':
        i += 1
        obj: dict = {}
        while True:
            while i < n and text[i] in ' \t,':
                i += 1
            if i >= n:
                return obj, i
            if text[i] == '}':
                return obj, i + 1
            k, i = parse_flow(text, i)
            i = skip_ws(i)
            key = '' if k is None else str(k)
            if i < n and text[i] == ':':
                v, i = parse_flow(text, i + 1)
                obj[key] = v
            else:
                obj[key] = None
    if c in '"\'':
        q = c
        i += 1
        buf: List[str] = []
        while i < n:
            if text[i] == '\\' and q == '"' and i + 1 < n:
                buf.append(text[i:i + 2]); i += 2; continue
            if text[i] == q:
                i += 1
                break
            buf.append(text[i]); i += 1
        return unquote(q + ''.join(buf) + q), i
    start = i
    while i < n and text[i] not in ',]}':
        if text[i] == ':' and (i + 1 >= n or text[i + 1] in ' \t'):
            break
        i += 1
    seg = text[start:i].strip()
    return (None if seg == '' else parse_scalar(seg)), i


def entry_value(doc: Document, key: str) -> Any:
    """把顶层键重新按完整语法解析（支持 key: | 与 key: 后换行标量）。"""
    e = doc.get(key)
    if e is None:
        return None
    head = e.header_raw
    # 去掉行尾注释后取 inline 部分
    body = strip_comment(head)
    colon = body.find(':')
    inline = body[colon + 1:].strip() if colon >= 0 else ''
    text = key + ': ' + inline + '\n' + '\n'.join(e.block)
    lines = split_lines(text)
    if not lines:
        return None
    p = Parser(lines)
    m = p.parse_map(0)
    return m.get(key)

# ---------------------------------------------------------------- 发射层

def dump_scalar(v: Any) -> str:
    if v is None:
        return 'null'
    if v is True:
        return 'true'
    if v is False:
        return 'false'
    if isinstance(v, int):
        return str(v)
    if isinstance(v, float):
        return repr(v)
    s = str(v)
    if s == '':
        return "''"
    need = False
    if s[0] in '-?:,[]{}#&*!|>\'"%@` ' or s[-1] == ' ':
        need = True
    if ': ' in s or ' #' in s or s.endswith(':'):
        need = True
    if s.lower() in ('null', '~', 'true', 'false', 'yes', 'no', 'on', 'off'):
        need = True
    if NUM_RE.match(s) or re.match(r'^[+-]?\d+\.\d*$', s):
        need = True
    if '\n' in s:
        need = True
    if not need:
        return s
    if '"' not in s and '\n' not in s and '\\' not in s:
        return '"' + s + '"'
    return '"' + s.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n') + '"'


def emit_scalar_inline(v: Any) -> str:
    if isinstance(v, dict):
        return '{}' if not v else flow_dump(v)
    if isinstance(v, list):
        return '[]' if not v else flow_dump(v)
    return dump_scalar(v)


def flow_dump(v: Any) -> str:
    if isinstance(v, dict):
        return '{' + ', '.join(f'{dump_scalar(k)}: {flow_dump(x)}' for k, x in v.items()) + '}'
    if isinstance(v, list):
        return '[' + ', '.join(flow_dump(x) for x in v) + ']'
    return dump_scalar(v)


def emit_value(v: Any, indent: int) -> List[str]:
    pad = ' ' * indent
    if isinstance(v, dict):
        if not v:
            return [pad + '{}']
        out: List[str] = []
        for k, val in v.items():
            ks = dump_scalar(k)
            if isinstance(val, (dict, list)) and val:
                out.append(f'{pad}{ks}:')
                out.extend(emit_value(val, indent + 2))
            else:
                out.append(f'{pad}{ks}: {emit_scalar_inline(val)}')
        return out
    if isinstance(v, list):
        if not v:
            return [pad + '[]']
        out = []
        for item in v:
            if isinstance(item, dict) and item:
                sub = emit_value(item, indent + 2)
                sub[0] = pad + '- ' + sub[0][indent + 2:]
                out.extend(sub)
            elif isinstance(item, list) and item:
                out.append(pad + '-')
                out.extend(emit_value(item, indent + 2))
            else:
                out.append(f'{pad}- {emit_scalar_inline(item)}')
        return out
    return [pad + emit_scalar_inline(v)]
