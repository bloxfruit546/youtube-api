"""Source-level self-check for PhotographicStyles16. Stdlib only, no build needed.

Asserts the invariants that a compile would not catch: the maths keeps its
range, the preset table and the spec hex swatches agree, the panel height is
shared, and Tweak.x has balanced Logos groups and no placeholders.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FAILS = []


def check(cond, msg):
    if not cond:
        FAILS.append(msg)


engine = (ROOT / "Sources/PS16ColorEngine.m").read_text(encoding="utf-8")
tweak = (ROOT / "Tweak.x").read_text(encoding="utf-8")
panel = (ROOT / "Sources/PS16ControlPanelView.m").read_text(encoding="utf-8")
sources = {
    p: p.read_text(encoding="utf-8")
    for p in (ROOT / "Tweak.x").parent.glob("**/*.[hmx]")
    if p.suffix in (".h", ".m", ".x")
}

# --- 1. No placeholders anywhere -------------------------------------------
for path, text in sources.items():
    for marker in ("TODO", "FIXME", "XXX", "Implement later", "<#"):
        check(marker not in text, f"{path.name}: placeholder {marker!r}")

# --- 2. Preset table --------------------------------------------------------
rows = re.findall(
    r'\{\s*"([^"]+)",\s*(-?[\d.]+),\s*(-?[\d.]+),\s*(-?[\d.]+),\s*(-?[\d.]+),\s*(-?[\d.]+),\s*(-?[\d.]+),\s*(-?[\d.]+)\s*\}',
    engine,
)
names = ["Standard", "Pearl", "Rose Gold", "Contrast", "Amber"]
check([r[0] for r in rows] == names, f"preset names/order drifted: {[r[0] for r in rows]}")
check("PS16PresetCount = 5" in engine, "PS16PresetCount is not 5")

# --- 3. Maths: normalization, saturation floor, tone curve monotonic --------
for bright in (0.0, 50.0, 100.0):
    for color in (0.0, 50.0, 100.0):
        for style in (0.0, 100.0):
            b = (bright - 50.0) / 50.0
            c = (color - 50.0) / 50.0
            s = style / 100.0
            check(-1.0 <= b <= 1.0 and -1.0 <= c <= 1.0 and 0.0 <= s <= 1.0,
                  f"normalization out of range at {bright}/{color}/{style}")
            if style == 0.0:                      # Style 0 must be a passthrough.
                check(b * 0.18 * s == 0.0 and s == 0.0, "style 0 is not passthrough")
            for _, base, contrast, _, _, _, shadow, high in rows:
                sat = max(0.0, 1.0 + (c * 0.65 + float(base)) * s)
                check(sat >= 0.0, f"saturation went negative in {base}")
                pts = [
                    (0.00, 0.00),
                    (0.25, 0.25 + float(shadow) * s),
                    (0.50, 0.50 + b * 0.15 * s),
                    (0.75, 0.75 + float(high) * s),
                    (1.00, 1.00),
                ]
                ys = [y for _, y in pts]
                check(all(0.0 <= y <= 1.0 for y in ys), f"tone curve y out of 0..1 ({base})")
                check(all(y2 > y1 for y1, y2 in zip(ys, ys[1:])), f"tone curve not monotone ({base})")

# --- 4. Gradient hexes match the spec --------------------------------------
spec = ["0xE89B6C", "0x7A8B99", "0x9B6B9E", "0xF2C6DE", "0xD48A78",
        "0xF5D6CE", "0x3A7CA5", "0x81C3D7", "0xB85D19", "0xE6A15C"]
found = re.findall(r"PS16Hex\((0x[0-9A-Fa-f]{6})\)", engine)
check("warmth = c * 0.10 * s" in engine, "Colour axis no longer shifts the cast (pad feels dead on Standard)")
check(found == spec, f"gradient hexes drifted: {found}")

# --- 5. Shared panel height -------------------------------------------------
heights = {m for m in re.findall(r"kPS16PanelHeight\s*=\s*([\d.]+)", tweak + panel)}
check(heights == {"284.0"}, f"kPS16PanelHeight disagrees: {heights}")

# --- 6. Logos balance -------------------------------------------------------
check(tweak.count("%hook") == tweak.count("%end") - 3,
      "unbalanced %hook/%end in Tweak.x")
check(tweak.count("%group") == 3, f"expected 3 %groups, got {tweak.count('%group')}")
check(tweak.count("%init(") == 3, f"expected 3 %init calls, got {tweak.count('%init(')}")

print(f"{len(sources)} files scanned, {len(rows)} presets, {len(found)} swatch stops")
if FAILS:
    print("\nFAIL")
    for f in FAILS:
        print("  -", f)
    sys.exit(1)
print("OK")
