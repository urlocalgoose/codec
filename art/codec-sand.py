# Generates the cymatic sand layers for the Codec mark: grain scattered on a
# dark pool, piling into rings where the C's sound pushes it (sand on a
# speaker). Rings are crisp near the letter and dissolve with distance, with
# a slight extra push out of the C's mouth.
#
#   python3 codec-sand.py           (needs numpy + Pillow)
#
# Then open codec-logo.html / codec-logo-cropped.html in a browser (or
# headless Chrome --screenshot) to composite the C over the sand.
import numpy as np
from PIL import Image

SIZE = 1024

def sand(out, cx, cy, wavelength, damp, inner_radius, seed=13, n=2_400_000):
    rng = np.random.default_rng(seed)
    x = rng.uniform(0, SIZE, n)
    y = rng.uniform(0, SIZE, n)
    dx, dy = x - cx, y - cy
    r = np.hypot(dx, dy)
    theta = np.arctan2(dy, dx)

    # ring jitter grows with distance: tight piles near the letter,
    # loose scatter far out
    rj = r + rng.normal(0, 1, n) * (4.0 + r * 0.016)
    crest = (0.5 + 0.5 * np.sin(2 * np.pi * rj / wavelength)) ** (4.2 * np.exp(-r / 800) + 1.6)
    amp = np.exp(-r / damp)
    mouth = 0.72 + 0.28 * np.exp(-(theta / 1.2) ** 2)
    clear = 1 / (1 + np.exp(-(r - inner_radius) / 20))

    p = np.clip(0.016 + 1.15 * crest * amp * mouth * clear, 0, 1)
    keep = rng.uniform(0, 1, n) < p * 0.42
    xk, yk = x[keep].astype(int), y[keep].astype(int)
    inten = np.clip(p[keep] * 1.05 + 0.08, 0, 1)

    img = np.zeros((SIZE, SIZE, 4), dtype=np.float32)
    base = np.array([243, 138, 46], np.float32) / 255
    hot = np.array([255, 220, 150], np.float32) / 255
    t = np.clip(inten * 1.25, 0, 1)[:, None]
    cols = base * (1 - t) + hot * t
    alpha = np.clip(inten * 1.5, 0.14, 1.0)

    for (px, py, c, a) in zip(xk, yk, cols, alpha):
        img[py, px, :3] = np.maximum(img[py, px, :3], c * a)
        img[py, px, 3] = min(1.0, img[py, px, 3] + a)

    heavy = rng.uniform(0, 1, len(xk)) < np.clip((inten - 0.45) * 0.9, 0, 1)
    for (px, py, c, a) in zip(xk[heavy], yk[heavy], cols[heavy], alpha[heavy]):
        for ox, oy in ((1, 0), (0, 1), (1, 1)):
            qx, qy = min(px + ox, SIZE - 1), min(py + oy, SIZE - 1)
            img[qy, qx, :3] = np.maximum(img[qy, qx, :3], c * a * 0.85)
            img[qy, qx, 3] = min(1.0, img[qy, qx, 3] + a * 0.85)

    Image.fromarray((img * 255).astype(np.uint8), "RGBA").save(out)

sand("codec-sand.png", cx=470, cy=512, wavelength=96.0, damp=520, inner_radius=265)
sand("codec-sand-cropped.png", cx=330, cy=512, wavelength=110.0, damp=560, inner_radius=360)
