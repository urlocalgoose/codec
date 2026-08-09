# The Codec mark IS the simulation: ~1.4M grains scattered on a plate,
# vibrated by a radial wave - no letterform, just what the sound does to
# the sand. Each step, grains drift down the
# vibration-energy gradient (away from antinodes, toward the quiet nodes)
# and get thermal kicks proportional to how hard the plate shakes under
# them - classic Chladni dynamics. What you see is where the sand ended up.
#
#   python3 codec-sand.py           (needs numpy + Pillow, ~10s per layer)
#
# Then open codec-logo.html / codec-logo-cropped.html (or screenshot them
# headless) to composite the sand over the pool gradient.
import numpy as np
from PIL import Image

SIZE = 1024

def simulate(cx, cy, wavelength, damp, calm_radius, n=1_400_000, steps=170, seed=42, out="sand.png"):
    rng = np.random.default_rng(seed)
    pos = rng.uniform(0, SIZE, (n, 2)).astype(np.float32)
    k = np.float32(2 * np.pi / wavelength)

    for _ in range(steps):
        dx = pos[:, 0] - cx
        dy = pos[:, 1] - cy
        r = np.sqrt(dx * dx + dy * dy) + 1e-3
        theta = np.arctan2(dy, dx)

        # the wave: radial sine, damped with distance, a touch stronger out
        # the C's mouth, calm under the letter itself
        mouth = (0.60 + 0.40 * np.exp(-(theta / 1.15) ** 2)).astype(np.float32)
        calm = 1 / (1 + np.exp(-(r - calm_radius) / 35))
        env = (np.exp(-r / damp) * calm).astype(np.float32)
        A = np.sin(k * r) * env * mouth
        dAdr = (k * np.cos(k * r)) * env * mouth

        # drift toward the nodes (down the energy gradient)...
        f = -2.0 * A * dAdr
        pos[:, 0] += 30.0 * f * (dx / r)
        pos[:, 1] += 30.0 * f * (dy / r)
        # ...while the shaking plate rattles them around
        jitter = (0.32 + 1.9 * np.abs(A))[:, None]
        pos += rng.normal(0, 1, (n, 2)).astype(np.float32) * jitter
        np.clip(pos, 0, SIZE - 1, out=pos)

    # bin the grains and tone-map: lone grains stay as speckle, piles go hot
    dens = np.zeros((SIZE, SIZE), dtype=np.float32)
    np.add.at(dens, (pos[:, 1].astype(np.int32), pos[:, 0].astype(np.int32)), 1.0)
    b = 1.0 - np.exp(-dens * 0.24)
    t = np.clip(b * 1.2, 0, 1)[..., None]
    base = np.array([234, 122, 38], np.float32) / 255
    hot = np.array([255, 228, 165], np.float32) / 255
    rgb = base * (1 - t) + hot * t
    alpha = np.clip(b * 1.5, 0, 1)[..., None]
    img = np.concatenate([rgb * alpha, alpha], axis=2)
    Image.fromarray((img * 255).astype(np.uint8), "RGBA").save(out)

simulate(512, 512, wavelength=170.0, damp=400, calm_radius=110, out="codec-sand.png")
simulate(330, 512, wavelength=200.0, damp=460, calm_radius=330, out="codec-sand-cropped.png")
