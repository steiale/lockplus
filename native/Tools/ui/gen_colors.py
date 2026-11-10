#!/usr/bin/env python3
"""Writes the LockPlus color sets (UI-CONCEPT §2.2, §8.2) into native/App/Assets.xcassets/Colors.

Run with `python3 -I native/Tools/ui/gen_colors.py` from the repo root. Committed output.
Every role has Any (light), Dark, and High Contrast variants for both. Views use `Color.lp.*` only.
"""
import json
import os

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", "App", "Assets.xcassets"))
COLORS = os.path.join(ROOT, "Colors")

MINT = (0xB5, 0xD1, 0xAE)
INK = (0, 30, 40)          # light-mode label ink
LINE = (0, 60, 50)         # light-mode stroke ink


def hx(s, a=1.0):
    s = s.lstrip("#")
    return (int(s[0:2], 16), int(s[2:4], 16), int(s[4:6], 16), a)


def rgba(rgb, a):
    return (rgb[0], rgb[1], rgb[2], a)


# role: (light, dark, light high contrast, dark high contrast)
ROLES = {
    "lp.sage":           (hx("2d7a68"), hx("80ae9a"), hx("1f5f50"), hx("a3cbb9")),
    "lp.protected":      (hx("2d7a68"), hx("80ae9a"), hx("1f5f50"), hx("a3cbb9")),
    "lp.transition":     (hx("a07000"), hx("e8c547"), hx("7d5800"), hx("f0d470")),
    "lp.transitionText": (hx("7d5800"), hx("e8c547"), hx("5f4300"), hx("f0d470")),
    "lp.attention":      (hx("b85500"), hx("e0873a"), hx("9a4700"), hx("eba062")),
    "lp.attentionText":  (hx("9a4700"), hx("e0873a"), hx("7a3800"), hx("eba062")),
    "lp.critical":       (hx("d03025"), hx("ef5b5b"), hx("b8291f"), hx("f47a7a")),
    "lp.criticalText":   (hx("b8291f"), hx("f08888"), hx("931f17"), hx("f6a5a5")),
    "lp.canvas":         (hx("f0f7f5"), hx("001429"), hx("f0f7f5"), hx("000c1a")),
    "lp.grouped":        (hx("e2eeea"), hx("001d36"), hx("e2eeea"), hx("00152a")),
    "lp.card":           (hx("ffffff"), hx("0d2b47"), hx("ffffff"), hx("0a2440")),
    "lp.sunken":         (hx("ffffff"), hx("000f20"), hx("ffffff"), hx("000a16")),
    # Grouped rows under a tile (tables in Activity and Diagnostics, draft 8.3, review S-8.17): white in light mode
    # (as the system table), a navy between canvas and card in dark mode instead of the system's grey.
    "lp.panel":          (hx("ffffff"), hx("0b2239"), hx("ffffff"), hx("071a2e")),
    # Text fields (LPField, draft 8.3, review S-4.04): a fill close to the window background and a soft border.
    "lp.field":          (rgba((255, 255, 255), 0.70), rgba((255, 255, 255), 0.05), rgba((255, 255, 255), 1.0), rgba((255, 255, 255), 0.08)),
    "lp.fieldBorder":    (rgba(LINE, 0.24), rgba(MINT, 0.28), rgba(LINE, 0.55), rgba(MINT, 0.50)),
    "lp.label":          (rgba(INK, 0.88), rgba(MINT, 1.0), rgba(INK, 1.0), rgba(MINT, 1.0)),
    "lp.label2":         (rgba(INK, 0.62), rgba(MINT, 0.65), rgba(INK, 0.80), rgba(MINT, 0.80)),
    "lp.label3":         (rgba(INK, 0.40), rgba(MINT, 0.55), rgba(INK, 0.55), rgba(MINT, 0.65)),
    "lp.stroke":         (rgba(LINE, 0.55), rgba(MINT, 0.50), rgba(LINE, 0.70), rgba(MINT, 0.65)),  # dark 45 % → 50 %: 45 % is 2.93:1 on lp.card
    "lp.hairline":       (rgba(LINE, 0.18), rgba(MINT, 0.18), rgba(LINE, 0.30), rgba(MINT, 0.30)),
    "lp.rx":             (hx("2d7a68"), hx("80ae9a"), hx("1f5f50"), hx("a3cbb9")),
    "lp.tx":             (hx("1a6e8a"), hx("5ab4c9"), hx("125670"), hx("7cc6d8")),
    # ConnectButtonStyle (pastel, §2.2a): pastel sage fill with dark ink in both modes.
    # Dark: the selection sage with light ink (owner 2026-11-10: "everywhere there is mint" = the sidebar selection).
    "lp.connectFill":    (hx("a9d9c6"), hx("4a6e62"), hx("96cfb8"), hx("3f6658")),
    "lp.connectLabel":   (hx("001e28"), hx("eaf4ee"), hx("001e28"), hx("ffffff")),
    # Links and the 2 pt focus ring: AccentColor (#4a6e62) is the selection/Connect sage and is only ~2.9:1 on the dark
    # window, so these roles are lighter in dark (the old accent #80ae9a, 5.9:1 on #1e1e1e-ish) and deep in light (text 4.5:1, ring 3:1).
    "lp.accentText":     (hx("3f6658"), hx("80ae9a"), hx("2b5547"), hx("a3cbb9")),
    "lp.navy":           (hx("001429"), hx("001429"), hx("001429"), hx("001429")),
    # App icon tile (AppIcon.icon fills): off-white in light, navy in dark; AppIconTile uses it in the UI.
    "lp.iconTile":       (hx("f4f2ec"), hx("082e4d"), hx("f4f2ec"), hx("082e4d")),
    # Pastel palette (§2.2a): everything outside the status tiles. Surfaces are pastel fills (light) and muted pastel
    # fills (dark) under onPastel text; marks (icons, chart lines) are medium tones in light mode (3:1 on canvas) and
    # true pastels in dark mode.
    "lp.pastelSage":     (hx("d3eae0"), hx("2f5648"), hx("c4e3d6"), hx("2a4f42")),
    "lp.pastelAmber":    (hx("fce5c8"), hx("5a4128"), hx("fadcb4"), hx("523a23")),
    "lp.pastelRose":     (hx("f9d5d2"), hx("5c3534"), hx("f6c6c2"), hx("542e2d")),
    "lp.pastelTeal":     (hx("d0e8f0"), hx("28495a"), hx("bfe0eb"), hx("234252")),
    "lp.pastelYellow":   (hx("f8edb8"), hx("52471f"), hx("f4e6a0"), hx("4a401b")),
    # Selection and Connect share one sage (owner 2026-11-10): the sidebar selection is the system's, drawn in AccentColor
    # (#4a6e62, HC #3f6658) with white text; lp.connectFill/lp.connectLabel above carry the same sage on the buttons.
    "lp.onPastel":       (rgba(INK, 1.0), hx("eaf4ee"), rgba(INK, 1.0), hx("ffffff")),
    "lp.onPastel2":      (rgba(INK, 0.74), rgba(hx("eaf4ee"), 0.78), rgba(INK, 0.86), rgba(hx("ffffff"), 0.88)),
    "lp.softSage":       (hx("3f8e78"), hx("a9d8c6"), hx("2f7a65"), hx("c2e6d8")),
    "lp.softAmber":      (hx("b8651a"), hx("f2b97a"), hx("9c5412"), hx("f7cc9b")),
    "lp.softRose":       (hx("cc4a4a"), hx("f2a0a0"), hx("b03a3a"), hx("f7bcbc")),
    "lp.softTeal":       (hx("2b7a99"), hx("8fd0e2"), hx("1f6683"), hx("aedfee")),
    "lp.softYellow":     (hx("9a7a10"), hx("f0dc85"), hx("7f6408"), hx("f5e6a5")),
    # Editor syntax (§6.9): dark "Navy" theme on lp.sunken; light GitHub-like, headers green (red means error).
    "lp.syntaxSection":  (hx("2d7a68"), hx("80ae9a"), hx("1f5f50"), hx("a3cbb9")),
    "lp.syntaxKey":      (hx("953800"), hx("b5d1ae"), hx("7a2e00"), hx("cfe3ca")),
    "lp.syntaxValue":    (hx("0a3069"), hx("5ab4c9"), hx("082650"), hx("7cc6d8")),
    "lp.syntaxNumber":   (hx("0550ae"), hx("e8c547"), hx("03408c"), hx("f0d470")),
    "lp.syntaxComment":  (hx("6e7781"), rgba(MINT, 0.65), hx("57606a"), rgba(MINT, 0.75)),  # 55 % is 4.16:1 on lp.sunken
    # Color icon style (§6.1): v1.0.61 tiles with a navy glyph (white glyphs fail at 2.2:1).
    "lp.trayIdle":       (hx("ffffff"), hx("ffffff"), hx("ffffff"), hx("ffffff")),
    "lp.trayProtected":  (hx("34c759"), hx("34c759"), hx("34c759"), hx("34c759")),
    "lp.trayAttention":  (hx("ff9f0a"), hx("ff9f0a"), hx("ff9f0a"), hx("ff9f0a")),
}
# AccentColor drives the system's sidebar selection (white text on it: 5.6:1 in both modes) and the default tint; the
# user's own system accent still overrides it. Links and the focus ring use `lp.accentText` instead (dark: 2.9:1 here).
ACCENT = (hx("4a6e62"), hx("4a6e62"), hx("3f6658"), hx("3f6658"))


def comp(c):
    r, g, b, a = c
    return {"color-space": "srgb", "components": {
        "red": f"0x{r:02X}", "green": f"0x{g:02X}", "blue": f"0x{b:02X}", "alpha": f"{a:.3f}"}}


def colorset(values):
    light, dark, hc_light, hc_dark = values
    dark_app = {"appearance": "luminosity", "value": "dark"}
    high = {"appearance": "contrast", "value": "high"}
    return {
        "colors": [
            {"color": comp(light), "idiom": "universal"},
            {"appearances": [dark_app], "color": comp(dark), "idiom": "universal"},
            {"appearances": [high], "color": comp(hc_light), "idiom": "universal"},
            {"appearances": [dark_app, high], "color": comp(hc_dark), "idiom": "universal"},
        ],
        "info": {"author": "xcode", "version": 1},
    }


def write(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as fh:
        json.dump(data, fh, indent=2)
        fh.write("\n")


def main():
    write(os.path.join(ROOT, "Contents.json"), {"info": {"author": "xcode", "version": 1}})
    write(os.path.join(COLORS, "Contents.json"), {"info": {"author": "xcode", "version": 1}})
    for name, values in ROLES.items():
        write(os.path.join(COLORS, f"{name}.colorset", "Contents.json"), colorset(values))
    write(os.path.join(ROOT, "AccentColor.colorset", "Contents.json"), colorset(ACCENT))
    print(f"wrote {len(ROLES) + 1} color sets")


if __name__ == "__main__":
    main()
