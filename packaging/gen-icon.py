#!/usr/bin/env python3
"""
FunFan 应用图标生成器

--------------------------------------------------------------------------
一、这个图标要说的事
--------------------------------------------------------------------------
FunFan 不是「风扇」工具，而是「接管风扇转速」的工具：曲线调速、规则调速、
只提速不压低、GUI 一退出就把控制权还给系统。核心动作是「你把转速从系统
手里接过来」。
所以标志 = 一台风扇，轮毂做成一个带滚花和指针的旋钮 —— 风扇和「可调的
旋钮」是同一个物体，不额外加装饰层。风扇负责 3 秒识别，旋钮负责说功能。

--------------------------------------------------------------------------
二、走过的弯路（别重走）
--------------------------------------------------------------------------
  · 锥形速度弧裹在风扇外：小尺寸读成一道划痕 / 铁丝。
  · 细弧 + 曲线控制点：读成加了铆钉的铁圈，且和扇叶抢戏。
  · 外圈刻度盘（24 / 36 齿）：16px 变成一圈灰尘噪点。
  · 叶片由短到长做「曲线」：读成叶片断了 / 渲染 bug。
  · 叶色由冷到暖表示温度：蓝橙过渡发脏，读成生锈。
  结论：图标尺度上不许加第二层装饰，功能必须由形体本身承担。

--------------------------------------------------------------------------
三、造型铁律（实战踩过的坑）
--------------------------------------------------------------------------
  1. 扇叶根部必须收进轮毂（R0 < R_HUB），且根部要有宽度、不能收成尖点，
     否则会被读成花瓣 / 胶片盘。
  2. 所有同心圆严格同圆心，禁止偏移式伪 3D 高光（向上偏 12px 就会被读成
     圆心没对齐）。旋钮里的滚花、面板、指针都绕同一个圆心。
  3. 叶形必须有后掠弧度：中心线随半径前移 + 前后缘半宽不对称，比对称
     花瓣更有「在转」的感觉。顶部高光一律渐隐，不留硬边。
  4. 对比度是生命线：叶根取深色与轮毂咬合，叶尖取亮色，远看仍有层次。
  5. 不烘焙大投影，靠留白 + 发丝边线立边界。
  6. 指针必须落在两片叶之间的空档里，否则和叶片糊成一根。

--------------------------------------------------------------------------
四、用法
--------------------------------------------------------------------------
  python3 packaging/gen-icon.py                  # 主推（浅银）+ 深色备选
  python3 packaging/gen-icon.py --concept plain  # 退回纯风扇做对照
  python3 packaging/gen-icon.py --only dark --no-icns

几何是唯一真源：SVG 与 PNG 预览由同一份几何派生，两边不会走样。
"""

import argparse
import math
import os
import shutil
import subprocess

from PIL import Image, ImageChops, ImageDraw

CANVAS = 1024
CX = CY = 512.0

# ---- 底板 ----------------------------------------------------------------
PLATE_HALF = 412.0        # 底板半边长（Apple 规范：824 主体 + 四周留白）
SQUIRCLE_N = 5.0          # 超椭圆指数，越大越方

# ---- 风扇本体 ------------------------------------------------------------
CONCEPT = "knob"          # knob = 旋钮轮毂（主推）；plain = 纯风扇（对照）
R1_SAFE = {"knob": 306.0, "plain": 312.0}
R1 = 306.0                # 叶尖半径

R_HUB = 92.0              # 轮毂半径 —— 必须 > R0
R0 = 62.0                 # 叶根半径（藏进轮毂）
SWEEP = 24.0              # 叶尖相对叶根的角位移（度），决定「后掠」强弱
W_ROOT_L = 20.0           # 前缘根部半张角
W_ROOT_T = 22.0           # 后缘根部半张角（略宽于前缘 → 后缘更饱满）
TAPER = 0.62              # 叶尖收窄比例
T_TIP = 0.86              # 从 86% 半径开始收圆叶尖
TIP_MIN = 0.34            # 叶尖末端保留的宽度比例（0 = 收成尖，1 = 不收）
RADIAL_POW = 0.92         # 半径方向密度分布
SWEEP_POW = 1.60          # 后掠集中在中后段的程度
N_BLADES = 5

# ---- 旋钮 ----------------------------------------------------------------
KNOB_TICKS = 32           # 滚花齿数（再多就成噪点）
KNOB_T0, KNOB_T1 = 67.0, 83.0   # 滚花半径范围
KNOB_FACE = 61.0          # 面板半径
KNOB_POINTER_R = 54.0     # 指针长度
KNOB_POINTER_W = 13.0     # 指针宽度
KNOB_POINTER_A = -38.0    # 指针角度：落在叶片空档里

# 对照组（plain）用的同心装饰圈
R_HUB_RING = 54.0
R_HUB_CAP = 26.0

RENDER_SCALE = 4          # 超采样倍数，先大后缩

# ---- 配色 ----------------------------------------------------------------
THEMES = {
    # 主推：浅银底板 + 深蓝钢扇叶。底板压深一档、扇叶提饱和，16px 仍有对比。
    "light": {
        "plate_top": "#EBF2FA",
        "plate_bottom": "#AEBFD4",
        "blade_tip": "#5FA9E3",
        "blade_root": "#17487A",
        "hub_top": "#3D4A5E",
        "hub_bottom": "#1B232E",
        "hub_ring": "#8494A8",
        "hub_cap": "#B6C3D2",
        "sheen": 1.0,           # 顶部高光强度系数
    },
    # 备选：深板岩底板，Dock 里辨识度最高，冷感更强。
    "dark": {
        "plate_top": "#27384B",
        "plate_bottom": "#0E1621",
        "blade_tip": "#93D4F7",
        "blade_root": "#2B7CC2",
        "hub_top": "#37455A",
        "hub_bottom": "#0C1219",
        "hub_ring": "#5E7189",
        "hub_cap": "#9DB0C6",
        "sheen": 0.38,          # 深底上同样的高光会糊成一片雾，压到 38%
    },
}


# ---- 几何 ----------------------------------------------------------------
def squircle_points(half, n=SQUIRCLE_N, samples=720):
    """超椭圆采样，返回 1024 坐标系下的点。"""
    pts = []
    for i in range(samples):
        a = 2.0 * math.pi * i / samples
        c, s = math.cos(a), math.sin(a)
        x = CX + half * math.copysign(abs(c) ** (2.0 / n), c)
        y = CY + half * math.copysign(abs(s) ** (2.0 / n), s)
        pts.append((x, y))
    return pts


def _polar(r, deg):
    """屏幕角：0=右，90=下（y 轴向下）。"""
    a = math.radians(deg)
    return CX + r * math.cos(a), CY + r * math.sin(a)


def _tip_taper(t):
    """叶尖收圆：最后一段按椭圆收口，末端保留 TIP_MIN 的宽度。

    直接用直弦收口会得到一个「切平」的叶尖，远看像剪纸；收成尖又读成花瓣。
    椭圆收口是这两者之间的正解。
    """
    if t <= T_TIP:
        return 1.0
    u = (t - T_TIP) / (1.0 - T_TIP)
    return TIP_MIN + (1.0 - TIP_MIN) * math.sqrt(max(0.0, 1.0 - u * u))


def _radius(t):
    return R0 + (R1 - R0) * (t ** RADIAL_POW)


def _center_angle(t):
    return SWEEP * (t ** SWEEP_POW)


def blade_points(samples=96):
    """单叶片轮廓（指向正上方，圆心为原点），顺时针后掠。"""
    pts = []

    # 前缘：由根到尖
    for i in range(samples + 1):
        t = i / samples
        r, th = _radius(t), _center_angle(t)
        w = W_ROOT_L * (1.0 - TAPER * t ** 1.05) * _tip_taper(t)
        a = math.radians(th + w)
        pts.append((r * math.sin(a), -r * math.cos(a)))

    # 叶尖：沿 r=R1 的圆弧收口（真实风扇是平切尖，不是尖点花瓣）
    wl1 = W_ROOT_L * (1.0 - TAPER) * TIP_MIN
    wt1 = W_ROOT_T * (1.0 - TAPER) * TIP_MIN
    a_start, a_end = SWEEP + wl1, SWEEP - wt1
    n_tip = 16
    for i in range(1, n_tip):
        a = math.radians(a_start + (a_end - a_start) * i / n_tip)
        pts.append((R1 * math.sin(a), -R1 * math.cos(a)))

    # 后缘：由尖回根
    for i in range(samples, -1, -1):
        t = i / samples
        r, th = _radius(t), _center_angle(t)
        w = W_ROOT_T * (1.0 - TAPER * t ** 1.05) * _tip_taper(t)
        a = math.radians(th - w)
        pts.append((r * math.sin(a), -r * math.cos(a)))

    return pts


def knurl_segments():
    """滚花齿的端点列表（1024 坐标系）。"""
    return [
        (_polar(KNOB_T0, 360.0 * i / KNOB_TICKS), _polar(KNOB_T1, 360.0 * i / KNOB_TICKS))
        for i in range(KNOB_TICKS)
    ]


def pointer_ends():
    return _polar(5, KNOB_POINTER_A), _polar(KNOB_POINTER_R, KNOB_POINTER_A)


# ---- 绘制：底板 ----------------------------------------------------------
def _rgb(c):
    c = c.lstrip("#")
    return tuple(int(c[i : i + 2], 16) for i in (0, 2, 4))


def _vgradient(height, top, bottom, width=None):
    """竖直渐变条带；width 省略时按正方形处理。"""
    width = width or height
    t, b = _rgb(top), _rgb(bottom)
    ramp = Image.new("RGB", (1, height))
    px = ramp.load()
    for y in range(height):
        f = y / max(1, height - 1)
        px[0, y] = tuple(round(t[i] + (b[i] - t[i]) * f) for i in range(3))
    return ramp.resize((width, height), Image.NEAREST).convert("RGBA")


def _disk(S, radius, k):
    m = Image.new("L", (S, S), 0)
    ImageDraw.Draw(m).ellipse(
        [(CX - radius) * k, (CY - radius) * k, (CX + radius) * k, (CY + radius) * k],
        fill=255,
    )
    return m


def _vertical_ramp(S, gamma=1.4):
    ramp = Image.new("L", (1, S))
    for y in range(S):
        ramp.putpixel((0, y), int(255 * (1 - y / max(1, S - 1)) ** gamma))
    return ramp.resize((S, S), Image.NEAREST)


def _circle(draw, radius, fill=None, outline=None, width=1, k=1.0):
    draw.ellipse(
        [
            (CX - radius) * k,
            (CY - radius) * k,
            (CX + radius) * k,
            (CY + radius) * k,
        ],
        fill=fill,
        outline=outline,
        width=width,
    )


def draw_plate(img, S, k, col):
    plate = [(x * k, y * k) for x, y in squircle_points(PLATE_HALF, samples=1440)]
    mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(mask).polygon(plate, fill=255)
    img.paste(_vgradient(S, col["plate_top"], col["plate_bottom"]), (0, 0), mask)

    # 顶部径向渐隐高光：同心椭圆逐级叠透明度，天然无接缝
    sheen = Image.new("L", (S, S), 0)
    sd = ImageDraw.Draw(sheen)
    steps, rx, ry = 90, 520 * k, 440 * k
    for i in range(steps, 0, -1):
        f = i / steps
        a = int(140 * col["sheen"] * (1 - f) ** 1.6)
        if a > 0:
            sd.ellipse(
                [CX * k - rx * f, 300 * k - ry * f, CX * k + rx * f, 300 * k + ry * f],
                fill=a,
            )
    img.paste(
        Image.new("RGBA", (S, S), (255, 255, 255, 255)),
        (0, 0),
        ImageChops.multiply(sheen, mask),
    )

    # 边缘发丝线：上白下黑，让浅色底板在白背景上仍有边界
    ring = Image.new("L", (S, S), 0)
    ImageDraw.Draw(ring).line(
        plate + [plate[0]], fill=255, width=max(1, int(3 * k)), joint="curve"
    )
    ramp = _vertical_ramp(S)
    img.paste(
        Image.new("RGBA", (S, S), (255, 255, 255, 255)),
        (0, 0),
        ImageChops.multiply(ring, ramp).point(lambda v: int(v * 0.30)),
    )
    img.paste(
        Image.new("RGBA", (S, S), (12, 20, 30, 255)),
        (0, 0),
        ImageChops.multiply(ring, ImageChops.invert(ramp)).point(lambda v: int(v * 0.14)),
    )


def draw_fan(img, S, k, col):
    """五片后掠扇叶 + 轮毂（旋钮或同心环）。"""
    blade = blade_points()
    bx = [p[0] for p in blade]
    by = [p[1] for p in blade]
    pad = 6.0
    lx0, lx1 = min(bx) - pad, max(bx) + pad
    ly0, ly1 = min(by) - pad, max(by) + pad
    bw, bh = int((lx1 - lx0) * k) + 1, int((ly1 - ly0) * k) + 1

    layer = Image.new("RGBA", (bw, bh), (0, 0, 0, 0))
    lmask = Image.new("L", (bw, bh), 0)
    ImageDraw.Draw(lmask).polygon(
        [((x - lx0) * k, (y - ly0) * k) for x, y in blade], fill=255
    )
    layer.paste(
        _vgradient(bh, col["blade_tip"], col["blade_root"], bw), (0, 0), lmask
    )

    # 旋转用正方形画布（以圆心为中心），避免 expand 带来的坐标漂移
    R = int(math.ceil(max(abs(v) for v in bx + by) + pad) * k) + 2
    spin = Image.new("RGBA", (2 * R, 2 * R), (0, 0, 0, 0))
    spin.paste(layer, (R + int(round(lx0 * k)), R + int(round(ly0 * k))))
    for i in range(N_BLADES):
        img.alpha_composite(
            spin.rotate(-360.0 / N_BLADES * i, resample=Image.BICUBIC),
            (int(CX * k) - R, int(CY * k) - R),
        )

    # 轮毂：三圈严格同心
    hub = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    gy0, gy1 = int((CY - R_HUB) * k), int((CY + R_HUB) * k)
    hub.paste(_vgradient(gy1 - gy0, col["hub_top"], col["hub_bottom"], S), (0, gy0))
    img.paste(hub, (0, 0), _disk(S, R_HUB, k))

    # 半透明元素必须走 RGBA 混合模式，否则会用 alpha 硬替换、打穿下层
    draw = ImageDraw.Draw(img, "RGBA")

    if CONCEPT == "knob":
        # 滚花：一圈细齿，读成「可以拧」的旋钮而不是平轮毂
        for p0, p1 in knurl_segments():
            draw.line(
                [(p0[0] * k, p0[1] * k), (p1[0] * k, p1[1] * k)],
                fill=(255, 255, 255, 58),
                width=max(1, int(3.2 * k)),
            )
        # 面板：比轮毂更深，衬出滚花与指针
        _circle(draw, KNOB_FACE, fill=_rgb(col["hub_bottom"]) + (255,), k=k)
        # 指针：白色胶囊，从中心指出去，32px 也读得出来
        c0, c1 = pointer_ends()
        r = KNOB_POINTER_W / 2
        draw.line(
            [(c0[0] * k, c0[1] * k), (c1[0] * k, c1[1] * k)],
            fill=(255, 255, 255, 244),
            width=max(1, int(KNOB_POINTER_W * k)),
        )
        for c in (c0, c1):
            draw.ellipse(
                [(c[0] - r) * k, (c[1] - r) * k, (c[0] + r) * k, (c[1] + r) * k],
                fill=(255, 255, 255, 244),
            )
    else:
        _circle(
            draw,
            R_HUB_RING,
            outline=_rgb(col["hub_ring"]) + (255,),
            width=max(1, int(7 * k)),
            k=k,
        )
        _circle(draw, R_HUB_CAP, fill=_rgb(col["hub_cap"]) + (255,), k=k)


# ---- 渲染 ----------------------------------------------------------------
def render(theme, size=1024, ss=RENDER_SCALE):
    col = THEMES[theme]
    S = size * ss
    k = S / CANVAS
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    draw_plate(img, S, k, col)
    draw_fan(img, S, k, col)
    return img.resize((size, size), Image.LANCZOS)


# ---- SVG -----------------------------------------------------------------
def write_svg(theme, path):
    col = THEMES[theme]
    plate = squircle_points(PLATE_HALF)
    d = "M " + " L ".join(f"{x:.1f} {y:.1f}" for x, y in plate) + " Z"

    blade = blade_points()   # 采样数与光栅化一致，避免两边形状分叉
    bd = "M " + " L ".join(f"{x:.1f} {y:.1f}" for x, y in blade) + " Z"
    blades = "\n".join(
        f'  <g transform="translate({CX:.0f},{CY:.0f}) rotate({i * 72})">\n'
        f'    <path d="{bd}" fill="url(#blade)"/>\n'
        f"  </g>"
        for i in range(N_BLADES)
    )

    if CONCEPT == "knob":
        knurl = "\n".join(
            f'  <line x1="{p0[0]:.1f}" y1="{p0[1]:.1f}" x2="{p1[0]:.1f}" '
            f'y2="{p1[1]:.1f}" stroke="#FFFFFF" stroke-opacity="0.23" '
            f'stroke-width="3.2"/>'
            for p0, p1 in knurl_segments()
        )
        c0, c1 = pointer_ends()
        hub = f"""  <circle cx="{CX:.0f}" cy="{CY:.0f}" r="{R_HUB}" fill="url(#hub)"/>
{knurl}
  <circle cx="{CX:.0f}" cy="{CY:.0f}" r="{KNOB_FACE}" fill="{col['hub_bottom']}"/>
  <line x1="{c0[0]:.1f}" y1="{c0[1]:.1f}" x2="{c1[0]:.1f}" y2="{c1[1]:.1f}"
        stroke="#FFFFFF" stroke-opacity="0.96" stroke-width="{KNOB_POINTER_W}"
        stroke-linecap="round"/>"""
    else:
        hub = f"""  <circle cx="{CX:.0f}" cy="{CY:.0f}" r="{R_HUB}" fill="url(#hub)"/>
  <circle cx="{CX:.0f}" cy="{CY:.0f}" r="{R_HUB_RING}" fill="none"
          stroke="{col['hub_ring']}" stroke-width="7"/>
  <circle cx="{CX:.0f}" cy="{CY:.0f}" r="{R_HUB_CAP}" fill="{col['hub_cap']}"/>"""

    svg = f"""<!-- 由 packaging/gen-icon.py 生成，不要手改；改参数后重新生成 -->
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024"
     role="img" aria-labelledby="ff-title ff-desc" id="funfan-icon">
  <title id="ff-title">FunFan 应用图标</title>
  <desc id="ff-desc">圆角方形底板上的一台正视角五叶风扇，轮毂是一个带滚花与指针的旋钮 —— 转速由你接管。</desc>

  <defs>
    <clipPath id="plate"><path d="{d}"/></clipPath>

    <linearGradient id="plateFill" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="{col['plate_top']}"/>
      <stop offset="1" stop-color="{col['plate_bottom']}"/>
    </linearGradient>

    <!-- 顶部高光：径向渐隐，绝不留硬边 -->
    <radialGradient id="plateSheen" cx="0.5" cy="0.16" r="0.78">
      <stop offset="0" stop-color="#FFFFFF" stop-opacity="{0.55 * col['sheen']:.3f}"/>
      <stop offset="0.55" stop-color="#FFFFFF" stop-opacity="{0.16 * col['sheen']:.3f}"/>
      <stop offset="1" stop-color="#FFFFFF" stop-opacity="0"/>
    </radialGradient>

    <!-- 叶身：沿 bbox 上下（= 叶尖到叶根）由亮到深 -->
    <linearGradient id="blade" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="{col['blade_tip']}"/>
      <stop offset="1" stop-color="{col['blade_root']}"/>
    </linearGradient>

    <linearGradient id="hub" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="{col['hub_top']}"/>
      <stop offset="1" stop-color="{col['hub_bottom']}"/>
    </linearGradient>
  </defs>

  <g clip-path="url(#plate)">
    <rect x="0" y="0" width="1024" height="1024" fill="url(#plateFill)"/>
    <ellipse cx="512" cy="300" rx="520" ry="440" fill="url(#plateSheen)"/>
  </g>

{blades}

{hub}
</svg>
"""
    with open(path, "w", encoding="utf-8") as f:
        f.write(svg)


# ---- icns ----------------------------------------------------------------
def write_icns(master_png, out_icns, tmpdir=".build/AppIcon.iconset"):
    """iconutil 要求目录名以 .iconset 结尾。"""
    if os.path.isdir(tmpdir):
        shutil.rmtree(tmpdir)
    os.makedirs(tmpdir, exist_ok=True)
    master = Image.open(master_png)
    specs = [
        (16, "icon_16x16.png"),
        (32, "icon_16x16@2x.png"),
        (32, "icon_32x32.png"),
        (64, "icon_32x32@2x.png"),
        (128, "icon_128x128.png"),
        (256, "icon_128x128@2x.png"),
        (256, "icon_256x256.png"),
        (512, "icon_256x256@2x.png"),
        (512, "icon_512x512.png"),
        (1024, "icon_512x512@2x.png"),
    ]
    for px, name in specs:
        master.resize((px, px), Image.LANCZOS).save(os.path.join(tmpdir, name))
    subprocess.run(["iconutil", "-c", "icns", tmpdir, "-o", out_icns], check=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", choices=list(THEMES), default=None)
    ap.add_argument("--concept", choices=list(R1_SAFE), default=None)
    ap.add_argument("--variant-dir", default="packaging/icon-variants")
    ap.add_argument("--no-icns", action="store_true")
    args = ap.parse_args()

    global CONCEPT, R1
    if args.concept:
        CONCEPT = args.concept
    R1 = R1_SAFE[CONCEPT]

    themes = [args.only] if args.only else ["light", "dark"]
    os.makedirs(args.variant_dir, exist_ok=True)

    for t in themes:
        big = render(t, 1024)
        if t == "light":
            write_svg(t, "packaging/AppIcon.svg")
            big.save("packaging/AppIcon-1024.png")
            if not args.no_icns:
                write_icns("packaging/AppIcon-1024.png", "packaging/AppIcon.icns")
        write_svg(t, os.path.join(args.variant_dir, f"AppIcon-{t}.svg"))
        big.save(os.path.join(args.variant_dir, f"AppIcon-{t}-1024.png"))
        for px in (256, 128, 64, 32, 16):
            big.resize((px, px), Image.LANCZOS).save(
                os.path.join(args.variant_dir, f"AppIcon-{t}-{px}.png")
            )
        print(f"[ok] {t} concept={CONCEPT}")


if __name__ == "__main__":
    main()
