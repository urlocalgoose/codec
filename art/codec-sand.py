# The Codec mark is a particle sim: ~900k grains scattered on a plate and
# vibrated by a warped radial wave - Chladni dynamics with low-order
# harmonic wobble so the rings settle organic, never perfect circles.
# Grains slide down the vibration-energy gradient toward the quiet rings
# while the plate rattles them; a blurred underlayer gives the field
# depth. The mark is wherever the sand ended up.
#
#   python3 codec-sand.py           (needs numpy + Pillow, ~10s per layer)
#
# Then open codec-logo.html / codec-logo-cropped.html (or screenshot them
# headless) to composite the sand over the pool gradient.
import numpy as np
from PIL import Image, ImageFilter

SIZE = 1024

def simulate(cx, cy, out, wavelength=300.0, damp=360.0, calm_radius=130,
             n=900_000, steps=170, seed=48):
    rng = np.random.default_rng(seed)
    k = np.float32(2 * np.pi / wavelength)
    pos = rng.uniform(0, SIZE, (n, 2)).astype(np.float32)
    # ring wobble: a few low harmonics with random phases
    harm = [(2, 14.0, rng.uniform(0, 2 * np.pi)),
            (3, 9.0, rng.uniform(0, 2 * np.pi)),
            (5, 6.0, rng.uniform(0, 2 * np.pi))]

    for _ in range(steps):
        dx = pos[:, 0] - cx
        dy = pos[:, 1] - cy
        r = np.sqrt(dx * dx + dy * dy) + 1e-3
        theta = np.arctan2(dy, dx)
        wobble = np.zeros_like(r)
        for m, a, ph in harm:
            wobble += a * np.sin(m * theta + ph + r * 0.003)
        rw = r + wobble
        calm = 1 / (1 + np.exp(-(r - calm_radius) / 40))
        env = (np.exp(-r / damp) * calm).astype(np.float32)
        A = np.sin(k * rw) * env
        dAdr = (k * np.cos(k * rw)) * env
        f = -2.0 * A * dAdr
        pos[:, 0] += 34.0 * f * (dx / r)
        pos[:, 1] += 34.0 * f * (dy / r)
        jitter = (0.5 + 2.2 * np.abs(A))[:, None]
        pos += rng.normal(0, 1, (n, 2)).astype(np.float32) * jitter
        np.clip(pos, 0, SIZE - 1, out=pos)

    dens = np.zeros((SIZE, SIZE), dtype=np.float32)
    np.add.at(dens, (pos[:, 1].astype(np.int32), pos[:, 0].astype(np.int32)), 1.0)

    sharp = 1.0 - np.exp(-dens * 0.30)
    soft = np.asarray(
        Image.fromarray((np.clip(sharp, 0, 1) * 255).astype(np.uint8), "L")
             .filter(ImageFilter.GaussianBlur(10)), dtype=np.float32) / 255
    b = np.clip(0.65 * soft + sharp, 0, 1)

    # resting far-field fades to dark so the rings float
    yy, xx = np.mgrid[0:SIZE, 0:SIZE].astype(np.float32)
    rr = np.sqrt((xx - cx) ** 2 + (yy - cy) ** 2)
    b *= 0.30 + 0.70 * np.exp(-rr / 480)

    t = np.clip(b * 1.2, 0, 1)[..., None]
    base = np.array([132, 140, 158], np.float32) / 255
    hot = np.array([238, 243, 252], np.float32) / 255
    rgb = base * (1 - t) + hot * t
    alpha = np.clip(b * 1.4, 0, 1)[..., None]
    img = np.concatenate([rgb * alpha, alpha], axis=2)
    Image.fromarray((img * 255).astype(np.uint8), "RGBA").save(out)

simulate(512, 512, "codec-sand.png")
simulate(340, 512, "codec-sand-cropped.png", wavelength=330.0, damp=420.0, calm_radius=180, seed=51)
