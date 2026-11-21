#!/usr/bin/env python3
"""生成 App 图标与 AccentColor。

Xcode 的 1024 图标不能带 alpha 通道，否则侧载 / 提审会报错。
这里直接画 RGB PNG（无 alpha），并用 4x 超采样消除锯齿。

用法：python tools/make_assets.py
"""
from __future__ import annotations

import json
import os
import struct
import zlib

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, '..'))
ASSETS = os.path.join(ROOT, 'ios', 'ClashMgr', 'Resources', 'Assets.xcassets')

FINAL = 1024
SS = 4  # 超采样倍数


def chunk(tag: bytes, data: bytes) -> bytes:
    return (
        struct.pack('>I', len(data))
        + tag
        + data
        + struct.pack('>I', zlib.crc32(tag + data) & 0xFFFFFFFF)
    )


def write_rgb_png(path: str, rgb: np.ndarray) -> None:
    """rgb: (H, W, 3) uint8。"""
    h, w, _ = rgb.shape
    raw = bytearray()
    for y in range(h):
        raw.append(0)  # filter 0
        raw.extend(rgb[y].tobytes())
    png = b'\x89PNG\r\n\x1a\n'
    png += chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
    png += chunk(b'IDAT', zlib.compress(bytes(raw), 9))
    png += chunk(b'IEND', b'')
    with open(path, 'wb') as f:
        f.write(png)


def smoothstep(edge0: float, edge1: float, x: np.ndarray) -> np.ndarray:
    t = np.clip((x - edge0) / (edge1 - edge0), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


def render_icon(n: int) -> np.ndarray:
    """深夜蓝底 + 三条从左侧汇聚到右侧节点的流线，返回 (n,n,3) float [0,1]。

    构图意图：多条线路归拢到一个出口 —— 订阅与策略组的路由语义。
    整体居中对称，避开四角，缩到 60pt 仍然可辨。
    """
    ys = (np.arange(n) + 0.5) / n
    xs = (np.arange(n) + 0.5) / n
    X, Y = np.meshgrid(xs, ys)

    # 背景：从左上深色到右下青蓝的对角渐变
    t = np.clip(X * 0.45 + Y * 0.55, 0.0, 1.0)
    c0 = np.array([0.035, 0.047, 0.094])
    c1 = np.array([0.078, 0.180, 0.278])
    img = c0[None, None, :] + (c1 - c0)[None, None, :] * t[:, :, None]

    px = 1.0 / n
    # 构图居中：三条流线从画布左侧外缘进入，汇聚到正中心的节点。
    node_x, node_y = 0.590, 0.500

    # 参数 (y0, 半线宽, 亮度)
    lanes = [
        (0.235, 0.0125, 1.00),
        (0.500, 0.0125, 0.52),
        (0.765, 0.0125, 1.00),
    ]
    accent = np.array([0.396, 0.760, 1.000])

    x_start = -0.02   # 从画布外开始，避免出现硬切口
    fade_len = 0.20   # 渐隐长度

    for y0, half, bright in lanes:
        ctrl_x = 0.330
        ctrl_y = y0 + (node_y - y0) * 0.22
        span = max(1e-6, node_x - x_start)
        tt = np.clip((X - x_start) / span, 0.0, 1.0)
        line_y = (1 - tt) ** 2 * y0 + 2 * (1 - tt) * tt * ctrl_y + tt ** 2 * node_y

        fade_in = smoothstep(0.0, fade_len, X - x_start)
        inside = (X >= x_start) & (X <= node_x + px)
        dist = np.abs(Y - line_y)
        cov = (1.0 - smoothstep(half - px, half + px, dist)) * inside.astype(float) * fade_in
        col = accent * bright
        img = img + (col[None, None, :] - img) * cov[:, :, None]

    # 节点：实心圆 + 外圈光环
    dx, dy = X - node_x, Y - node_y
    r = np.sqrt(dx * dx + dy * dy)

    ring_in, ring_out = 0.105, 0.118
    ring = smoothstep(ring_in - px, ring_in + px, r) * (
        1.0 - smoothstep(ring_out - px, ring_out + px, r))
    img = img + (accent[None, None, :] - img) * (ring * 0.85)[:, :, None]

    core_r = 0.058
    core = 1.0 - smoothstep(core_r - 1.5 * px, core_r + 1.5 * px, r)
    img = img + (np.array([1.0, 1.0, 1.0])[None, None, :] - img) * core[:, :, None]

    # 四角轻微压暗
    dd = np.sqrt((X - 0.5) ** 2 + (Y - 0.5) ** 2) / 0.5
    dim = 1.0 - 0.38 * smoothstep(0.70, 1.04, dd)
    img = img * dim[:, :, None]

    return np.clip(img, 0.0, 1.0)


def downsample(img: np.ndarray, factor: int) -> np.ndarray:
    h, w, c = img.shape
    assert h % factor == 0 and w % factor == 0
    return img.reshape(h // factor, factor, w // factor, factor, c).mean(axis=(1, 3))


def write_contents_json(directory: str, payload: dict) -> None:
    os.makedirs(directory, exist_ok=True)
    with open(os.path.join(directory, 'Contents.json'), 'w', encoding='utf-8') as f:
        json.dump(payload, f, indent=2, ensure_ascii=False)
        f.write('\n')


def main() -> int:
    appicon = os.path.join(ASSETS, 'AppIcon.appiconset')
    accent = os.path.join(ASSETS, 'AccentColor.colorset')
    os.makedirs(appicon, exist_ok=True)
    os.makedirs(accent, exist_ok=True)

    hi = render_icon(FINAL * SS)
    rgb = downsample(hi, SS)
    rgb8 = (rgb * 255.0 + 0.5).astype(np.uint8)

    png_path = os.path.join(appicon, 'AppIcon-1024.png')
    write_rgb_png(png_path, rgb8)
    print(f'wrote {png_path} ({os.path.getsize(png_path)} bytes)')

    write_contents_json(ASSETS, {
        'info': {'author': 'xcode', 'version': 1},
    })

    # iOS 16+ 单尺寸图标
    write_contents_json(appicon, {
        'images': [
            {'filename': 'AppIcon-1024.png', 'idiom': 'universal',
             'platform': 'ios', 'size': '1024x1024'},
        ],
        'info': {'author': 'xcode', 'version': 1},
    })

    # AccentColor 取自流线的青蓝色
    write_contents_json(accent, {
        'colors': [
            {
                'color': {
                    'color-space': 'srgb',
                    'components': {
                        'alpha': '1.000',
                        'red': '0.298',
                        'green': '0.635',
                        'blue': '0.855',
                    },
                },
                'idiom': 'universal',
            }
        ],
        'info': {'author': 'xcode', 'version': 1},
    })
    print('wrote AccentColor.colorset')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
