"""生成菜单栏用的模板图标（纯标准库，无 Pillow 依赖）。

菜单栏图标和 App 图标得认得出是同一个东西，所以几何直接复用 `gen_icon.py`
的 `PTS` / `STROKE` / `S`，不另画一份——改一处，两处都跟着变。

输出的是**模板图**（template image）：AppKit 只看 alpha 通道，把形状按菜单栏
当前颜色（浅色栏上是黑、深色栏上是白）重新着色。所以这里画成纯黑 + alpha，
RGB 值其实没人看。

用法：
    python3 scripts/gen_tray_icon.py
"""

import math
import os
import struct
import sys
import zlib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gen_icon import PTS, STROKE, seg_dist  # noqa: E402  同一条折线

# 菜单栏里的成稿尺寸（pt）。宽 20 / 高 10 是按图标本身的长宽比（678:296）定的，
# 折线铺满宽度后高度自然落在这个区间，和 SF Symbols 里 waveform.path.ecg 一类
# 的「扁平波形」视觉分量接近。
W_PT = 20.0
H_PT = 10.0
PAD_PT = 0.5      # 左右各留 0.5pt，贴满会挤到相邻图标
STROKE_PT = 1.5   # 等比算出来只有 1.29pt，菜单栏里偏淡，加粗一档
SS = 4            # 超采样倍数，最后再箱式降采样

OUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "macos", "Resources")


def glyph_bbox():
    """折线加上线宽后的外接框（1024 坐标系）。"""
    h = STROKE / 2.0
    xs = [p[0] for p in PTS]
    ys = [p[1] for p in PTS]
    return min(xs) - h, min(ys) - h, max(xs) + h, max(ys) + h


def render(scale):
    """返回 (宽, 高, RGBA 原始像素)。scale 是 @1x/@2x/@3x 的倍数。"""
    w = int(round(W_PT * scale))
    h = int(round(H_PT * scale))
    W, H = w * SS, h * SS

    x0, y0, x1, y1 = glyph_bbox()
    gw, gh = x1 - x0, y1 - y0

    k = ((W_PT - PAD_PT * 2) * scale * SS) / gw
    # 把外接框的中心对到画布中心，不靠经验偏移
    ox = W / 2.0 - (gw * k) / 2.0 - x0 * k
    oy = H / 2.0 - (gh * k) / 2.0 - y0 * k
    pts = [(p[0] * k + ox, p[1] * k + oy) for p in PTS]
    half = (STROKE_PT * scale * SS) / 2.0

    # 先在超采样分辨率上算覆盖率
    cov = []
    for y in range(H):
        py = y + 0.5
        row = []
        for x in range(W):
            px = x + 0.5
            d = min(seg_dist(px, py, *pts[i], *pts[i + 1]) for i in range(len(pts) - 1))
            row.append(max(0.0, min(1.0, (half - d) + 0.5)))
        cov.append(row)

    # 箱式降采样：SS×SS 平均，边缘就有了 16 级灰阶
    raw = bytearray()
    for y in range(h):
        raw.append(0)  # filter type 0
        for x in range(w):
            acc = 0.0
            for dy in range(SS):
                base = cov[y * SS + dy]
                for dx in range(SS):
                    acc += base[x * SS + dx]
            alpha = int(round(acc / (SS * SS) * 255))
            raw.extend((0, 0, 0, alpha))
    return w, h, bytes(raw)


def png(w, h, raw):
    def chunk(tag, data):
        body = struct.pack(">I", len(data)) + tag + data
        return body + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    out = b"\x89PNG\r\n\x1a\n"
    out += chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
    out += chunk(b"IDAT", zlib.compress(raw, 9))
    out += chunk(b"IEND", b"")
    return out


if __name__ == "__main__":
    os.makedirs(OUT_DIR, exist_ok=True)
    for scale, suffix in ((1, ""), (2, "@2x"), (3, "@3x")):
        w, h, raw = render(scale)
        path = os.path.join(OUT_DIR, f"tray-template{suffix}.png")
        with open(path, "wb") as f:
            f.write(png(w, h, raw))
        print(f"wrote {os.path.abspath(path)}  {w}x{h}")
