"""生成 EZPcMonitor 应用图标（纯标准库，无 Pillow 依赖）。"""

import struct
import zlib
import math
import os

S = 1024
PAD = 78
RADIUS = 224

C1 = (14, 165, 233)   # sky-500
C2 = (99, 102, 241)   # indigo-500
C3 = (34, 211, 238)   # cyan-400

# 心电折线（相对 1024 画布）
PTS = [
    (196, 520),
    (330, 520),
    (398, 404),
    (470, 654),
    (540, 520),
    (828, 520),
]
STROKE = 46


def lerp(a, b, t):
    return tuple(int(round(a[i] + (b[i] - a[i]) * t)) for i in range(3))


def rounded_rect_alpha(x, y, pad, radius):
    """返回 0..1 的覆盖率，带 1.2px 抗锯齿。"""
    left, top, right, bottom = pad, pad, S - pad, S - pad
    cx = min(max(x, left + radius), right - radius)
    cy = min(max(y, top + radius), bottom - radius)
    d = math.hypot(x - cx, y - cy)
    # 内部为负
    inside = d - radius
    if left <= x <= right and top <= y <= bottom:
        if (left + radius) <= x <= (right - radius) or (top + radius) <= y <= (bottom - radius):
            inside = -radius
    return max(0.0, min(1.0, 0.5 - inside / 1.4))


def seg_dist(px, py, ax, ay, bx, by):
    dx, dy = bx - ax, by - ay
    L = dx * dx + dy * dy
    if L == 0:
        return math.hypot(px - ax, py - ay)
    t = max(0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / L))
    return math.hypot(px - (ax + t * dx), py - (ay + t * dy))


def glyph_dist(x, y):
    d = 1e9
    for i in range(len(PTS) - 1):
        d = min(d, seg_dist(x, y, *PTS[i], *PTS[i + 1]))
    return d


def build():
    raw = bytearray()
    for y in range(S):
        raw.append(0)  # filter type 0
        for x in range(S):
            a = rounded_rect_alpha(x, y, PAD, RADIUS)
            if a <= 0.002:
                raw.extend((0, 0, 0, 0))
                continue

            # 对角渐变
            t = (x * 0.55 + y * 0.45) / S
            col = lerp(C1, C2, t)

            # 左上柔光
            gx, gy = x - 250, y - 210
            glow = max(0.0, 1.0 - math.hypot(gx, gy) / 520.0) ** 2
            col = lerp(col, C3, glow * 0.42)

            # 心电折线
            d = glyph_dist(x, y)
            cov = max(0.0, min(1.0, (STROKE / 2 - d) / 1.6 + 0.5))
            if cov > 0:
                col = lerp(col, (255, 255, 255), cov)

            raw.extend((col[0], col[1], col[2], int(a * 255)))

    def chunk(tag, data):
        c = struct.pack(">I", len(data)) + tag + data
        return c + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", S, S, 8, 6, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(raw), 9))
    png += chunk(b"IEND", b"")
    return png


if __name__ == "__main__":
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "app-icon.png")
    with open(out, "wb") as f:
        f.write(build())
    print("wrote", os.path.abspath(out))
