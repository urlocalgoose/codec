#!/usr/bin/env python3
"""Render a programmatic Codec promo video.

The renderer builds SVG frames from the current app screenshots and encodes
them with ffmpeg. It intentionally avoids app source changes.
"""

from __future__ import annotations

import argparse
import base64
import concurrent.futures
import html
import math
import os
import shutil
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
OUT_DIR = ROOT / "promo" / "output"
WIDTH = 1920
HEIGHT = 1080
DEFAULT_FPS = 24
DEFAULT_DURATION = 36.0

SCREEN_DESKTOP = ROOT / "docs" / "screenshots" / "web-desktop.png"
SCREEN_IOS_DARK = ROOT / "docs" / "screenshots" / "ios-home.png"
SCREEN_IOS_LIGHT = ROOT / "docs" / "screenshots" / "ios-home-light.png"
APP_ICON = ROOT / "ios" / "CodecMobile" / "App" / "Assets.xcassets" / "AppIcon.appiconset" / "AppIcon1024.png"
CODIE_HAND = ROOT / "ios" / "CodecMobile" / "Resources" / "CodieHand-Regular.ttf"
RENDER_ASSETS = OUT_DIR / "render-assets"
IMAGE_URIS: dict[Path, str] = {}

BG = "#100f0c"
PANEL = "#181610"
PANEL_2 = "#211e17"
SURFACE = "#2b271e"
SURFACE_HOVER = "#373226"
TEXT = "#f5efe2"
MUTED = "#bbb3a2"
SUBTLE = "#8f8879"
ACCENT = "#f47b3f"
ACCENT_HOVER = "#ff9b61"
PRIMARY_TEXT = "#130f0a"


def clamp(value: float, lo: float = 0.0, hi: float = 1.0) -> float:
    return max(lo, min(hi, value))


def smooth(value: float) -> float:
    value = clamp(value)
    return value * value * (3.0 - 2.0 * value)


def ease_out(value: float) -> float:
    value = clamp(value)
    return 1.0 - pow(1.0 - value, 3.0)


def scene_alpha(p: float) -> float:
    return min(smooth(p / 0.16), smooth((1.0 - p) / 0.14))


def uri(path: Path) -> str:
    return html.escape(path.resolve().as_uri(), quote=True)


def data_uri(path: Path) -> str:
    mime = "image/png"
    if path.suffix.lower() in {".jpg", ".jpeg"}:
        mime = "image/jpeg"
    raw = base64.b64encode(path.read_bytes()).decode("ascii")
    return f"data:{mime};base64,{raw}"


def prepare_render_assets() -> None:
    RENDER_ASSETS.mkdir(parents=True, exist_ok=True)
    magick = shutil.which("magick") or shutil.which("convert")
    conversions = [
        (SCREEN_DESKTOP, RENDER_ASSETS / "web-desktop.jpg", "1440x900", "86"),
        (SCREEN_IOS_DARK, RENDER_ASSETS / "ios-home.jpg", "500x1087", "90"),
        (SCREEN_IOS_LIGHT, RENDER_ASSETS / "ios-home-light.jpg", "500x1087", "90"),
        (APP_ICON, RENDER_ASSETS / "app-icon.png", "256x256", "92"),
    ]
    for source, output, size, quality in conversions:
        if magick:
            run([magick, str(source), "-resize", size, "-strip", "-quality", quality, str(output)])
            IMAGE_URIS[source] = data_uri(output)
        else:
            IMAGE_URIS[source] = data_uri(source)


def esc(value: str) -> str:
    return html.escape(value, quote=False)


def attrs(**kwargs: object) -> str:
    return " ".join(f'{name.replace("_", "-")}="{value}"' for name, value in kwargs.items() if value is not None)


def rect(x: float, y: float, w: float, h: float, fill: str, rx: float = 0, extra: str = "") -> str:
    return f'<rect x="{x:.2f}" y="{y:.2f}" width="{w:.2f}" height="{h:.2f}" rx="{rx:.2f}" fill="{fill}" {extra}/>'


def text(
    value: str,
    x: float,
    y: float,
    size: float,
    fill: str = TEXT,
    weight: int = 650,
    anchor: str = "start",
    opacity: float = 1.0,
    family: str = "system",
    tracking: float = 0,
) -> str:
    font = "Codie Hand, Arial, sans-serif" if family == "hand" else "-apple-system, BlinkMacSystemFont, 'SF Pro Display', Arial, sans-serif"
    return (
        f'<text x="{x:.2f}" y="{y:.2f}" fill="{fill}" font-family="{font}" '
        f'font-size="{size:.2f}" font-weight="{weight}" text-anchor="{anchor}" '
        f'letter-spacing="{tracking:.2f}" opacity="{opacity:.3f}">{esc(value)}</text>'
    )


def image(path: Path, x: float, y: float, w: float, h: float, clip: str | None = None, opacity: float = 1.0) -> str:
    clip_attr = f' clip-path="url(#{clip})"' if clip else ""
    source = html.escape(IMAGE_URIS.get(path, data_uri(path)), quote=True)
    return (
        f'<image href="{source}" xlink:href="{source}" x="{x:.2f}" y="{y:.2f}" width="{w:.2f}" height="{h:.2f}" '
        f'preserveAspectRatio="xMidYMid slice" opacity="{opacity:.3f}"{clip_attr}/>'
    )


def base_svg(body: str, frame: int) -> str:
    font_face = ""
    if CODIE_HAND.exists():
        font_face = f"""
        @font-face {{
          font-family: 'Codie Hand';
          src: url('{uri(CODIE_HAND)}') format('truetype');
        }}
        """
    return f"""<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="{WIDTH}" height="{HEIGHT}" viewBox="0 0 {WIDTH} {HEIGHT}">
  <defs>
    <style>
      {font_face}
      text {{ dominant-baseline: alphabetic; }}
    </style>
    <filter id="softShadow" x="-30%" y="-30%" width="160%" height="170%">
      <feDropShadow dx="0" dy="22" stdDeviation="26" flood-color="#000000" flood-opacity="0.34"/>
    </filter>
    <filter id="buttonShadow" x="-20%" y="-20%" width="140%" height="150%">
      <feDropShadow dx="0" dy="12" stdDeviation="10" flood-color="#000000" flood-opacity="0.35"/>
    </filter>
    <filter id="glow" x="-50%" y="-50%" width="200%" height="200%">
      <feGaussianBlur stdDeviation="18" result="blur"/>
      <feMerge>
        <feMergeNode in="blur"/>
        <feMergeNode in="SourceGraphic"/>
      </feMerge>
    </filter>
    <filter id="grain" x="0" y="0" width="100%" height="100%">
      <feTurbulence type="fractalNoise" baseFrequency="0.82" numOctaves="3" seed="{frame % 23}"/>
      <feColorMatrix type="saturate" values="0"/>
      <feComponentTransfer>
        <feFuncA type="table" tableValues="0 0.03"/>
      </feComponentTransfer>
    </filter>
    <linearGradient id="bgGlow" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="#1b1710"/>
      <stop offset="0.52" stop-color="{BG}"/>
      <stop offset="1" stop-color="#080706"/>
    </linearGradient>
  </defs>
  <rect width="{WIDTH}" height="{HEIGHT}" fill="url(#bgGlow)"/>
  <circle cx="1540" cy="120" r="420" fill="{ACCENT}" opacity="0.055"/>
  <circle cx="260" cy="990" r="520" fill="#f5efe2" opacity="0.025"/>
  {body}
  <rect width="{WIDTH}" height="{HEIGHT}" filter="url(#grain)" opacity="0.72"/>
</svg>"""


def title_stack(kicker: str, headline: str, sub: str, x: float, y: float, a: float, align: str = "start") -> str:
    anchor = "middle" if align == "center" else "start"
    parts = [
        text(kicker.upper(), x, y, 22, ACCENT, 700, anchor, a, tracking=3.0),
        text(headline, x, y + 86, 80, TEXT, 720, anchor, a),
        text(sub, x, y + 146, 30, MUTED, 520, anchor, a),
    ]
    return "\n".join(parts)


def desktop_mock(x: float, y: float, w: float, h: float, a: float, scale: float = 1.0) -> str:
    cx = x + w / 2
    cy = y + h / 2
    sw = w * scale
    sh = h * scale
    sx = cx - sw / 2
    sy = cy - sh / 2
    clip = "desktopClip"
    return f"""
    <g opacity="{a:.3f}" filter="url(#softShadow)">
      {rect(sx - 18, sy - 18, sw + 36, sh + 36, "#080706", 38)}
      <clipPath id="{clip}">{rect(sx, sy, sw, sh, "#fff", 28)}</clipPath>
      {image(SCREEN_DESKTOP, sx, sy, sw, sh, clip)}
      {rect(sx, sy, sw, 64, "#080706", 28, 'opacity="0.24"')}
      <circle cx="{sx + 36:.2f}" cy="{sy + 32:.2f}" r="7" fill="{ACCENT}" opacity="0.9"/>
      <circle cx="{sx + 62:.2f}" cy="{sy + 32:.2f}" r="7" fill="{MUTED}" opacity="0.45"/>
      <circle cx="{sx + 88:.2f}" cy="{sy + 32:.2f}" r="7" fill="{MUTED}" opacity="0.25"/>
    </g>
    """


def phone_mock(x: float, y: float, w: float, h: float, screen: Path, a: float, scale: float = 1.0, clip_id: str = "phoneClip") -> str:
    cx = x + w / 2
    cy = y + h / 2
    sw = w * scale
    sh = h * scale
    sx = cx - sw / 2
    sy = cy - sh / 2
    inset = 24 * scale
    return f"""
    <g opacity="{a:.3f}" filter="url(#softShadow)">
      {rect(sx, sy, sw, sh, "#050403", 54 * scale)}
      {rect(sx + 8 * scale, sy + 8 * scale, sw - 16 * scale, sh - 16 * scale, "#17140f", 48 * scale)}
      <clipPath id="{clip_id}">{rect(sx + inset, sy + inset, sw - inset * 2, sh - inset * 2, "#fff", 38 * scale)}</clipPath>
      {image(screen, sx + inset, sy + inset, sw - inset * 2, sh - inset * 2, clip_id)}
      {rect(sx + sw / 2 - 72 * scale, sy + 22 * scale, 144 * scale, 24 * scale, "#050403", 12 * scale)}
    </g>
    """


def icon_symbol(name: str, x: float, y: float, size: float, color: str, opacity: float = 1.0) -> str:
    lw = max(4, size * 0.07)
    if name == "pause":
        return f"""
        <g opacity="{opacity:.3f}" stroke="{color}" stroke-width="{lw:.2f}" stroke-linecap="round">
          <line x1="{x - size * 0.14:.2f}" y1="{y - size * 0.26:.2f}" x2="{x - size * 0.14:.2f}" y2="{y + size * 0.26:.2f}"/>
          <line x1="{x + size * 0.14:.2f}" y1="{y - size * 0.26:.2f}" x2="{x + size * 0.14:.2f}" y2="{y + size * 0.26:.2f}"/>
        </g>"""
    if name == "play":
        return f'<path d="M {x - size * 0.18:.2f} {y - size * 0.30:.2f} L {x + size * 0.28:.2f} {y:.2f} L {x - size * 0.18:.2f} {y + size * 0.30:.2f} Z" fill="none" stroke="{color}" stroke-width="{lw:.2f}" stroke-linejoin="round" opacity="{opacity:.3f}"/>'
    if name == "next":
        return f"""
        <g opacity="{opacity:.3f}" stroke="{color}" stroke-width="{lw:.2f}" stroke-linecap="round" stroke-linejoin="round" fill="none">
          <path d="M {x - size * 0.28:.2f} {y - size * 0.32:.2f} L {x + size * 0.12:.2f} {y:.2f} L {x - size * 0.28:.2f} {y + size * 0.32:.2f} Z"/>
          <line x1="{x + size * 0.24:.2f}" y1="{y - size * 0.32:.2f}" x2="{x + size * 0.24:.2f}" y2="{y + size * 0.32:.2f}"/>
        </g>"""
    if name == "prev":
        return f"""
        <g opacity="{opacity:.3f}" stroke="{color}" stroke-width="{lw:.2f}" stroke-linecap="round" stroke-linejoin="round" fill="none">
          <path d="M {x + size * 0.28:.2f} {y - size * 0.32:.2f} L {x - size * 0.12:.2f} {y:.2f} L {x + size * 0.28:.2f} {y + size * 0.32:.2f} Z"/>
          <line x1="{x - size * 0.24:.2f}" y1="{y - size * 0.32:.2f}" x2="{x - size * 0.24:.2f}" y2="{y + size * 0.32:.2f}"/>
        </g>"""
    if name == "shuffle":
        return f"""
        <g opacity="{opacity:.3f}" stroke="{color}" stroke-width="{lw:.2f}" stroke-linecap="round" stroke-linejoin="round" fill="none">
          <path d="M {x - size * 0.34:.2f} {y - size * 0.20:.2f} C {x - size * 0.05:.2f} {y - size * 0.20:.2f}, {x - size * 0.02:.2f} {y + size * 0.20:.2f}, {x + size * 0.28:.2f} {y + size * 0.20:.2f}"/>
          <path d="M {x - size * 0.34:.2f} {y + size * 0.20:.2f} C {x - size * 0.05:.2f} {y + size * 0.20:.2f}, {x - size * 0.02:.2f} {y - size * 0.20:.2f}, {x + size * 0.28:.2f} {y - size * 0.20:.2f}"/>
          <path d="M {x + size * 0.20:.2f} {y - size * 0.31:.2f} L {x + size * 0.34:.2f} {y - size * 0.20:.2f} L {x + size * 0.20:.2f} {y - size * 0.09:.2f}"/>
          <path d="M {x + size * 0.20:.2f} {y + size * 0.09:.2f} L {x + size * 0.34:.2f} {y + size * 0.20:.2f} L {x + size * 0.20:.2f} {y + size * 0.31:.2f}"/>
        </g>"""
    if name == "repeat":
        return f"""
        <g opacity="{opacity:.3f}" stroke="{color}" stroke-width="{lw:.2f}" stroke-linecap="round" stroke-linejoin="round" fill="none">
          <path d="M {x - size * 0.26:.2f} {y - size * 0.20:.2f} H {x + size * 0.22:.2f} V {y - size * 0.02:.2f}"/>
          <path d="M {x + size * 0.12:.2f} {y - size * 0.13:.2f} L {x + size * 0.22:.2f} {y - size * 0.02:.2f} L {x + size * 0.32:.2f} {y - size * 0.13:.2f}"/>
          <path d="M {x + size * 0.26:.2f} {y + size * 0.20:.2f} H {x - size * 0.22:.2f} V {y + size * 0.02:.2f}"/>
          <path d="M {x - size * 0.12:.2f} {y + size * 0.13:.2f} L {x - size * 0.22:.2f} {y + size * 0.02:.2f} L {x - size * 0.32:.2f} {y + size * 0.13:.2f}"/>
        </g>"""
    return ""


def transport_stack(x: float, y: float, a: float, p: float, scale: float = 1.0) -> str:
    widths = [154, 154, 226, 154, 154]
    h = 130 * scale
    xs = [x]
    for width in widths[:-1]:
        xs.append(xs[-1] + width * scale)
    total = sum(widths) * scale
    clip = "transportClip"
    pulse = 0.5 + 0.5 * math.sin(p * math.tau * 2.0)
    parts = [
        f'<g opacity="{a:.3f}" filter="url(#buttonShadow)">',
        f'<clipPath id="{clip}">{rect(x, y, total, h, "#fff", 28 * scale)}</clipPath>',
        f'<g clip-path="url(#{clip})">',
    ]
    names = ["shuffle", "prev", "pause", "next", "repeat"]
    for i, width in enumerate(widths):
        bx = xs[i]
        fill = ACCENT if i == 2 else PANEL_2
        by = y + (8 * scale if i == 2 else 0)
        bh = h
        parts.append(rect(bx, by, width * scale, bh, fill, 0))
        parts.append(rect(bx, by + bh - (2 if i == 2 else 5) * scale, width * scale, 5 * scale, "#000000", 0, f'opacity="{0.20 if i == 2 else 0.30:.2f}"'))
        if i > 0:
            parts.append(rect(bx, y, 1.2 * scale, h, "#f5efe2", 0, 'opacity="0.055"'))
        icon_color = PRIMARY_TEXT if i == 2 else MUTED
        parts.append(icon_symbol(names[i], bx + width * scale / 2, y + h / 2 + (6 * scale if i == 2 else 0), 68 * scale, icon_color, 0.88 + 0.12 * pulse if i == 2 else 0.85))
    parts.append("</g></g>")
    return "\n".join(parts)


def progress_slot(x: float, y: float, w: float, a: float, p: float) -> str:
    knob = x + w * (0.18 + 0.62 * smooth(p))
    return f"""
    <g opacity="{a:.3f}">
      {text("1:09", x - 66, y + 20, 24, MUTED, 620, opacity=a)}
      {rect(x, y, w, 28, "#070605", 14, 'opacity="0.86"')}
      {rect(x + 4, y + 10, w - 8, 8, "#211e17", 4, 'opacity="0.92"')}
      {rect(x + 4, y + 10, knob - x - 4, 8, ACCENT, 4, 'opacity="0.62"')}
      {rect(knob - 16, y - 9, 32, 46, SURFACE, 8)}
      {text("3:50", x + w + 24, y + 20, 24, MUTED, 620, opacity=a)}
    </g>
    """


def qr_pattern(x: float, y: float, size: float, dark: str, light: str) -> str:
    n = 29
    cell = size / n
    parts = [rect(x, y, size, size, light, 18)]

    def module(row: int, col: int) -> bool:
        finders = [(0, 0), (0, n - 7), (n - 7, 0)]
        for fr, fc in finders:
            if fr <= row < fr + 7 and fc <= col < fc + 7:
                edge = row in (fr, fr + 6) or col in (fc, fc + 6)
                center = fr + 2 <= row <= fr + 4 and fc + 2 <= col <= fc + 4
                return edge or center
        return ((row * 17 + col * 31 + row * col * 7) % 9) in (0, 2, 5)

    for row in range(n):
        for col in range(n):
            if module(row, col):
                parts.append(rect(x + col * cell + cell * 0.14, y + row * cell + cell * 0.14, cell * 0.72, cell * 0.72, dark, cell * 0.12))
    return "\n".join(parts)


def aux_pass(x: float, y: float, w: float, h: float, a: float, p: float) -> str:
    qr_size = 330
    code = "8K2F"
    shine = x + 60 + (w - 120) * smooth(p)
    return f"""
    <g opacity="{a:.3f}" filter="url(#softShadow)">
      {rect(x, y, w, h, PANEL_2, 36)}
      {rect(x + 16, y + 16, w - 32, h - 32, SURFACE, 26, 'opacity="0.72"')}
      <path d="M {shine - 110:.2f} {y + 18:.2f} L {shine + 10:.2f} {y + 18:.2f} L {shine - 190:.2f} {y + h - 18:.2f} L {shine - 310:.2f} {y + h - 18:.2f} Z" fill="#ffffff" opacity="0.045"/>
      {image(APP_ICON, x + 58, y + 56, 92, 92)}
      {text("Codec Aux", x + 176, y + 98, 34, TEXT, 720, opacity=a)}
      {text("join the queue", x + 178, y + 137, 19, MUTED, 620, opacity=a, tracking=1.8)}
      {qr_pattern(x + w - qr_size - 58, y + 70, qr_size, "#100f0c", "#f5efe2")}
      {text(code, x + 78, y + 286, 112, ACCENT, 760, opacity=a)}
      {text("Friends can play here. Your library stays yours.", x + 82, y + 344, 25, MUTED, 520, opacity=a)}
      {rect(x + 78, y + h - 92, 206, 58, ACCENT, 18)}
      {text("Share", x + 181, y + h - 55, 24, PRIMARY_TEXT, 760, "middle", a)}
      {rect(x + 294, y + h - 92, 178, 58, PANEL, 18)}
      {text("Copy", x + 383, y + h - 55, 24, TEXT, 680, "middle", a)}
    </g>
    """


def library_panel(x: float, y: float, w: float, h: float, a: float, p: float) -> str:
    rows = [
        ("New Slang", "The Shins", "3:50"),
        ("Woman", "Doja Cat", "2:52"),
        ("Tape Hiss", "The Codec Ensemble", "0:24"),
        ("See You Again", "Tyler, The Creator", "3:00"),
    ]
    parts = [
        f'<g opacity="{a:.3f}" filter="url(#softShadow)">',
        rect(x, y, w, h, PANEL, 32),
        text("All Songs", x + 48, y + 76, 38, TEXT, 720, opacity=a),
        text("332 tracks - 20 hr 38 min", x + 48, y + 116, 23, MUTED, 560, opacity=a),
        rect(x + 48, y + 154, 150, 54, ACCENT, 15),
        text("Play", x + 123, y + 188, 22, PRIMARY_TEXT, 760, "middle", a),
        rect(x + 207, y + 154, 170, 54, SURFACE, 15),
        text("Shuffle", x + 292, y + 188, 22, TEXT, 650, "middle", a),
        rect(x + 48, y + 240, w - 96, 1, "#ffffff", 0, 'opacity="0.055"'),
    ]
    for i, (title, artist, dur) in enumerate(rows):
        ry = y + 262 + i * 90
        if i == int(1 + smooth(p) * 2):
            parts.append(rect(x + 28, ry - 18, w - 56, 76, SURFACE, 18, 'opacity="0.58"'))
        parts.extend([
            rect(x + 52, ry - 8, 54, 54, ACCENT if i % 2 == 0 else "#73a7ff", 12, 'opacity="0.86"'),
            text(title, x + 126, ry + 14, 27, TEXT, 650, opacity=a),
            text(artist, x + 126, ry + 45, 19, MUTED, 520, opacity=a),
            text(dur, x + w - 72, ry + 24, 22, MUTED, 600, "end", a),
        ])
    parts.append("</g>")
    return "\n".join(parts)


def hero_scene(t: float, p: float, frame: int) -> str:
    a = scene_alpha(p)
    lift = 30 * (1 - ease_out(p))
    icon_size = 182 + 10 * math.sin(p * math.tau)
    return f"""
    <g transform="translate(0 {lift:.2f})">
      <g opacity="{a:.3f}" filter="url(#softShadow)">
        {rect(858, 238, 204, 204, ACCENT, 48)}
        {image(APP_ICON, 872, 252, 176, 176, opacity=0.98)}
      </g>
      {text("Codec", 960, 560, 102, TEXT, 760, "middle", a)}
      {text("Local music, connected.", 960, 622, 34, MUTED, 520, "middle", a)}
      {rect(760, 700, 400, 2, ACCENT, 1, f'opacity="{0.5 * a:.3f}"')}
    </g>
    """


def desktop_scene(t: float, p: float, frame: int) -> str:
    a = scene_alpha(p)
    slide = 90 * (1 - ease_out(p))
    scale = 0.94 + 0.05 * smooth(p)
    return f"""
    <g transform="translate({slide:.2f} 0)">
      {title_stack("Desktop", "Your library, fast.", "Local files. Native controls. No rented shelf.", 170, 180, a)}
      {desktop_mock(520, 330, 1200, 750, a, scale)}
    </g>
    """


def controls_scene(t: float, p: float, frame: int) -> str:
    a = scene_alpha(p)
    glow = 0.12 + 0.08 * math.sin(p * math.tau)
    return f"""
    <circle cx="960" cy="545" r="{300 + 34 * smooth(p):.2f}" fill="{ACCENT}" opacity="{glow * a:.3f}" filter="url(#glow)"/>
    {title_stack("Controls", "Buttons with weight.", "Raised, pressed, latched. Like hardware should feel.", 960, 210, a, "center")}
    {transport_stack(534, 486, a, p, 1.08)}
    {progress_slot(638, 710, 640, a, p)}
    """


def connected_scene(t: float, p: float, frame: int) -> str:
    a = scene_alpha(p)
    dot_x = 760 + 400 * smooth(p)
    return f"""
    {title_stack("Sync", "Pick where it plays.", "Phone controls desktop. Desktop sends it back.", 184, 186, a)}
    {desktop_mock(154, 348, 880, 550, a, 0.94)}
    {phone_mock(1238, 238, 352, 724, SCREEN_IOS_DARK, a, 0.96, "phoneClipConnected")}
    <g opacity="{a:.3f}">
      <path d="M 790 560 C 910 450, 1050 450, 1168 560" fill="none" stroke="{MUTED}" stroke-width="2" opacity="0.24"/>
      <circle cx="{dot_x:.2f}" cy="{520 - 70 * math.sin(smooth(p) * math.pi):.2f}" r="12" fill="{ACCENT}"/>
      {rect(760, 668, 402, 86, PANEL_2, 24)}
      {text("Playing on", 794, 704, 18, SUBTLE, 700, opacity=a, tracking=1.6)}
      {text("Batman", 794, 738, 34, TEXT, 720, opacity=a)}
      {rect(1040, 698, 78, 30, ACCENT, 15)}
      {text("live", 1079, 719, 16, PRIMARY_TEXT, 760, "middle", a)}
    </g>
    """


def aux_scene(t: float, p: float, frame: int) -> str:
    a = scene_alpha(p)
    return f"""
    {title_stack("Aux", "Pass the queue around.", "A room code for shared playback, not shared ownership.", 160, 226, a)}
    {aux_pass(742, 214, 900, 586, a, p)}
    """


def library_scene(t: float, p: float, frame: int) -> str:
    a = scene_alpha(p)
    return f"""
    {library_panel(196, 170, 760, 742, a, p)}
    <g opacity="{a:.3f}">
      {text("Downloaded stays", 1090, 302, 68, TEXT, 720, opacity=a)}
      {text("downloaded.", 1090, 374, 68, TEXT, 720, opacity=a)}
      {text("MP3s stay on disk. Playlists point at one clean library.", 1094, 438, 30, MUTED, 520, opacity=a)}
      {rect(1096, 526, 518, 74, PANEL_2, 22)}
      {text(".loud/state.json", 1132, 573, 28, ACCENT, 720, opacity=a)}
      {rect(1096, 626, 350, 62, SURFACE, 18)}
      {text("no duplicate likes", 1128, 665, 24, TEXT, 650, opacity=a)}
      {rect(1096, 704, 394, 62, SURFACE, 18)}
      {text("real local files", 1128, 743, 24, TEXT, 650, opacity=a)}
    </g>
    """


def outro_scene(t: float, p: float, frame: int) -> str:
    a = scene_alpha(p)
    return f"""
    <g opacity="{a:.3f}">
      <g filter="url(#softShadow)">
        {rect(842, 260, 236, 236, ACCENT, 58)}
        {image(APP_ICON, 860, 278, 200, 200)}
      </g>
      {text("Codec", 960, 620, 96, TEXT, 760, "middle", a)}
      {text("Your music. Your devices. Your files.", 960, 686, 34, MUTED, 520, "middle", a)}
    </g>
    """


SCENES = [
    (0.0, 4.0, hero_scene),
    (4.0, 9.5, desktop_scene),
    (9.5, 14.5, controls_scene),
    (14.5, 21.0, connected_scene),
    (21.0, 27.0, aux_scene),
    (27.0, 33.0, library_scene),
    (33.0, DEFAULT_DURATION, outro_scene),
]


def scene_for_time(t: float):
    for start, end, fn in SCENES:
        if start <= t < end:
            p = (t - start) / (end - start)
            return fn, p
    start, end, fn = SCENES[-1]
    return fn, 1.0


def render_svg_at(t: float, frame: int) -> str:
    fn, p = scene_for_time(t)
    return base_svg(fn(t, p, frame), frame)


def run(cmd: list[str]) -> None:
    subprocess.run(cmd, check=True)


def require_tools() -> None:
    missing = [name for name in ("rsvg-convert", "ffmpeg") if not shutil.which(name)]
    if missing:
        raise SystemExit(f"Missing required tool(s): {', '.join(missing)}")
    for path in (SCREEN_DESKTOP, SCREEN_IOS_DARK, SCREEN_IOS_LIGHT, APP_ICON):
        if not path.exists():
            raise SystemExit(f"Missing input asset: {path}")


def render_one_frame(frame_dir: Path, fps: int, frame: int) -> None:
    t = frame / fps
    svg_path = frame_dir / f"frame_{frame:04d}.svg"
    png_path = frame_dir / f"frame_{frame:04d}.png"
    svg_path.write_text(render_svg_at(t, frame), encoding="utf-8")
    run(["rsvg-convert", "-w", str(WIDTH), "-h", str(HEIGHT), "-o", str(png_path), str(svg_path)])


def render_frames(frame_dir: Path, fps: int, duration: float, workers: int) -> int:
    frames = int(round(fps * duration))
    done = 0
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
        futures = [pool.submit(render_one_frame, frame_dir, fps, frame) for frame in range(frames)]
        for future in concurrent.futures.as_completed(futures):
            future.result()
            done += 1
            if done % max(1, fps * 2) == 0 or done == frames:
                print(f"rendered {done:04d}/{frames}", flush=True)
    return frames


def render_poster(output: Path) -> None:
    svg_path = OUT_DIR / "codec-promo-poster.svg"
    svg_path.write_text(render_svg_at(5.2, 999), encoding="utf-8")
    run(["rsvg-convert", "-w", str(WIDTH), "-h", str(HEIGHT), "-o", str(output), str(svg_path)])


def encode_video(frame_dir: Path, fps: int, duration: float, output: Path) -> None:
    frame_pattern = str(frame_dir / "frame_%04d.png")
    audio_filter = (
        "[1:a]volume=0.035,lowpass=f=900,afade=t=in:st=0:d=2,afade=t=out:st=34:d=2[a1];"
        "[2:a]volume=0.020,lowpass=f=1400,tremolo=f=0.32:d=0.22,afade=t=in:st=4:d=2,afade=t=out:st=34:d=2[a2];"
        "[3:a]volume=0.012,lowpass=f=1800,tremolo=f=0.18:d=0.18,afade=t=in:st=10:d=4,afade=t=out:st=34:d=2[a3];"
        "[a1][a2][a3]amix=inputs=3:normalize=0,volume=1.0[a]"
    )
    run(
        [
            "ffmpeg",
            "-y",
            "-hide_banner",
            "-loglevel",
            "error",
            "-framerate",
            str(fps),
            "-i",
            frame_pattern,
            "-f",
            "lavfi",
            "-i",
            f"sine=frequency=110:duration={duration}",
            "-f",
            "lavfi",
            "-i",
            f"sine=frequency=220:duration={duration}",
            "-f",
            "lavfi",
            "-i",
            f"sine=frequency=330:duration={duration}",
            "-filter_complex",
            audio_filter,
            "-map",
            "0:v",
            "-map",
            "[a]",
            "-c:v",
            "libx264",
            "-profile:v",
            "high",
            "-pix_fmt",
            "yuv420p",
            "-crf",
            "18",
            "-preset",
            "medium",
            "-r",
            str(fps),
            "-c:a",
            "aac",
            "-b:a",
            "128k",
            "-shortest",
            "-movflags",
            "+faststart",
            str(output),
        ]
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--fps", type=int, default=DEFAULT_FPS)
    parser.add_argument("--duration", type=float, default=DEFAULT_DURATION)
    parser.add_argument("--output", type=Path, default=OUT_DIR / "codec-promo.mp4")
    parser.add_argument("--workers", type=int, default=max(2, min(8, os.cpu_count() or 4)))
    args = parser.parse_args()

    require_tools()
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    prepare_render_assets()

    poster = OUT_DIR / "codec-promo-poster.png"
    render_poster(poster)
    print(f"poster: {poster}", flush=True)

    with tempfile.TemporaryDirectory(prefix="codec-promo-frames-") as temp:
        frame_dir = Path(temp)
        render_frames(frame_dir, args.fps, args.duration, args.workers)
        encode_video(frame_dir, args.fps, args.duration, args.output)

    print(f"video: {args.output}", flush=True)


if __name__ == "__main__":
    main()
