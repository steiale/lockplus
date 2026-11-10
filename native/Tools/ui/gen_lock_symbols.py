#!/usr/bin/env python3
"""Generates the custom `lockplus.lock` SF Symbol family (UI-CONCEPT §7.1, §7.2) as symbol templates.

Run with `python3 -I native/Tools/ui/gen_lock_symbols.py` from the repo root. It (re)writes
`native/App/Assets.xcassets/Symbols/<name>.symbolset/`. Committed output; not run at build time.
The shipping lock is V2 "Sturdy" with a larger + cut into the body (owner pick "p2", review S-12.02, UI-CONCEPT §7.2).

Design rules carried in the geometry:
- every state has its own silhouette at 16 px (§2.4): open vs closed shackle, filled vs outline body, and a
  badge whose OUTLINE differs per state (dots, circular arrow, disc, triangle, two bars), never only interior detail;
- the badge always sits in the bottom-right quadrant and the body gets a real circular notch around it
  (template images can't knock out, so the gap is geometry);
- all symbols share one margin box, so the status item never changes width between states;
- layer order is the same in every symbol (0 body, 1 shackle, 2 badge) so Magic Replace can morph the shackle
  between `lockplus.lock.open` and `lockplus.lock.closed`;
- Ultralight, Regular and Black have identical path structure (same commands, different coordinates), so the
  system can interpolate every weight from them.

Not done here (needs the SF Symbols 7 app): Draw On/Off guide-point annotations. Without them Magic Replace
still morphs the shared shackle layer; Draw falls back to the system's default per-layer animation.
"""
import math
import os
import json

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", "App", "Assets.xcassets", "Symbols"))

WEIGHTS = ("Ultralight", "Regular", "Black")
COLUMNS = {"Ultralight": 500.0, "Regular": 1400.0, "Black": 2700.0}


def f(v):
    s = f"{v:.3f}".rstrip("0").rstrip(".")
    return "0" if s in ("-0", "") else s


class P:
    """Tiny path builder that only emits M/L/C/Z (no arcs, so structure is explicit and interpolatable)."""

    def __init__(self):
        self.d = []
        self.cur = None

    def m(self, x, y):
        self.d.append(f"M{f(x)} {f(y)}"); self.cur = (x, y); return self

    def l(self, x, y):
        self.d.append(f"L{f(x)} {f(y)}"); self.cur = (x, y); return self

    def c(self, x1, y1, x2, y2, x, y):
        self.d.append(f"C{f(x1)} {f(y1)} {f(x2)} {f(y2)} {f(x)} {f(y)}"); self.cur = (x, y); return self

    def arc(self, cx, cy, r, a0, a1, segments):
        """Circular arc from angle a0 to a1 (radians, y-down), split into a FIXED number of cubic segments."""
        da = (a1 - a0) / segments
        k = 4.0 / 3.0 * math.tan(da / 4.0)
        for i in range(segments):
            s, e = a0 + da * i, a0 + da * (i + 1)
            p0 = (cx + r * math.cos(s), cy + r * math.sin(s))
            p3 = (cx + r * math.cos(e), cy + r * math.sin(e))
            p1 = (p0[0] - k * r * math.sin(s), p0[1] + k * r * math.cos(s))
            p2 = (p3[0] + k * r * math.sin(e), p3[1] - k * r * math.cos(e))
            self.c(*p1, *p2, *p3)
        return self

    def z(self):
        self.d.append("Z"); return self

    def __str__(self):
        return "".join(self.d)


def rect(p, x0, y0, x1, y1, reverse=False):
    if reverse:
        p.m(x0, y0).l(x0, y1).l(x1, y1).l(x1, y0).z()
    else:
        p.m(x0, y0).l(x1, y0).l(x1, y1).l(x0, y1).z()


def circle(p, cx, cy, r, reverse=False):
    p.m(cx + r, cy)
    if reverse:
        p.arc(cx, cy, r, 0, -2 * math.pi, 4)
    else:
        p.arc(cx, cy, r, 0, 2 * math.pi, 4)
    p.z()


def badge(kind, w, centre, radius):
    """Badge drawn around `centre` (k scales the details with the radius)."""
    cx, cy = centre
    R = radius
    k = radius / 18.0
    s = w["s"]
    p = P()
    if kind == "ellipsis":                    # three dots in a row: a wide, flat outline
        r = w["dot"]
        for dx in (-12.5 * k, 0.0, 12.5 * k):
            circle(p, cx + dx, cy, r)
    elif kind == "arrow":                     # circular arrow: open ring plus arrowhead
        ro = R - 1.0 * k
        ri = ro - s
        a0, a1 = math.radians(-60), math.radians(210)
        p.m(cx + ro * math.cos(a0), cy + ro * math.sin(a0))
        p.arc(cx, cy, ro, a0, a1, 4)
        p.l(cx + ri * math.cos(a1), cy + ri * math.sin(a1))
        p.arc(cx, cy, ri, a1, a0, 4)
        p.z()
        # arrowhead at the a0 end, pointing along the clockwise direction
        mid = (ro + ri) / 2
        tip_a = a0 - math.radians(38)
        hx, hy = cx + mid * math.cos(a0), cy + mid * math.sin(a0)
        spread = s * 0.5 + 4.0 * k
        p.m(hx + (spread) * math.cos(a0), hy + (spread) * math.sin(a0))
        p.l(cx + mid * math.cos(tip_a), cy + mid * math.sin(tip_a))
        p.l(hx - (spread) * math.cos(a0), hy - (spread) * math.sin(a0))
        p.z()
    elif kind == "blocked":                   # no-entry: a full disc with a horizontal bar cut out
        circle(p, cx, cy, R)
        bar_h = s * 0.55 + 2.0
        rect(p, cx - 11.0 * k, cy - bar_h / 2, cx + 11.0 * k, cy + bar_h / 2, reverse=True)
    elif kind == "exclamation":               # warning triangle with "!" cut out
        r = R + 1.5 * k
        pts = [(cx + r * math.cos(a), cy + 1.5 * k + r * math.sin(a)) for a in (math.radians(-90), math.radians(30), math.radians(150))]
        p.m(*pts[0]).l(*pts[1]).l(*pts[2]).z()
        bw = s * 0.45 + 1.4
        rect(p, cx - bw / 2, cy - 7.5 * k, cx + bw / 2, cy + 6.0 * k, reverse=True)
        rect(p, cx - bw / 2, cy + 9.0 * k, cx + bw / 2, cy + 9.0 * k + bw, reverse=True)
    elif kind == "pause":                     # two bars: a tall, split outline
        bw = s + 2.5
        gap = 7.0 * k
        rect(p, cx - gap / 2 - bw, cy - 16.0 * k, cx - gap / 2, cy + 15.0 * k)
        rect(p, cx + gap / 2, cy - 16.0 * k, cx + gap / 2 + bw, cy + 15.0 * k)
    else:
        raise ValueError(kind)
    return str(p)


# name → (shackle state, body filled, badge)
SYMBOLS = {
    "lockplus.lock.open":           ("open", False, None),        # unprotected
    "lockplus.lock.closing":        ("closing", False, None),     # status-item connecting frame 2
    "lockplus.lock.closed.outline": ("closed", False, None),      # status-item connecting frame 3
    "lockplus.lock.closed":         ("closed", True, None),       # protected
    "lockplus.lock.connecting":     ("closed", False, "ellipsis"),
    "lockplus.lock.reasserting":    ("closed", False, "arrow"),
    "lockplus.lock.blocked":        ("closed", True, "blocked"),
    "lockplus.lock.attention":      ("closed", False, "exclamation"),
    "lockplus.lock.paused":         ("open", False, "pause"),
    "lockplus.lock.error":          ("open", False, "exclamation"),
}

LAYER = 'class="monochrome-{i} multicolor-{i}:tintColor hierarchical-{i}:primary SFSymbolsPreviewWireframe"'


def svg(name, spec, margins, group):
    guides = []
    for y, n in ((696, "S"), (1126, "M"), (1556, "L")):
        guides.append(f'  <line id="Baseline-{n}" style="fill:none;stroke:#27AAE1;opacity:1;stroke-width:0.5;" x1="263" x2="3036" y1="{y}" y2="{y}"/>')
        guides.append(f'  <line id="Capline-{n}" style="fill:none;stroke:#27AAE1;opacity:1;stroke-width:0.5;" x1="263" x2="3036" y1="{f(y - 70.459)}" y2="{f(y - 70.459)}"/>')
    for weight in ("Black", "Regular", "Ultralight"):
        x = COLUMNS[weight]
        for side, mx in (("left", margins[0]), ("right", margins[1])):
            guides.append(f'  <line id="{side}-margin-{weight}-S" style="fill:none;stroke:#00AEEF;stroke-width:0.5;opacity:1.0;" x1="{f(x + mx)}" x2="{f(x + mx)}" y1="600.785" y2="720.121"/>')
    groups = "\n".join(group(wt, spec) for wt in ("Black", "Regular", "Ultralight"))
    return f'''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN" "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd">
<!-- Generated by native/Tools/ui/gen_lock_symbols.py. Do not edit by hand. -->
<svg version="1.1" xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="3300" height="2200">
 <g id="Notes">
  <rect height="2200" id="artboard" style="fill:white;opacity:1" width="3300" x="0" y="0"/>
  <text style="stroke:none;fill:black;font-family:sans-serif;font-size:13;font-weight:bold;" transform="matrix(1 0 0 1 263 322)">{name}</text>
  <text id="template-version" style="stroke:none;fill:black;font-family:sans-serif;font-size:13;text-anchor:end;" transform="matrix(1 0 0 1 3036 1933)">Template v.3.0</text>
 </g>
 <g id="Guides">
{chr(10).join(guides)}
 </g>
 <g id="Symbols">
{groups}
 </g>
</svg>
'''


# --- lock geometry ----------------------------------------------------------------------------------------------

class Line:
    def __init__(self, p0, p1):
        self.p0, self.p1 = p0, p1

    def at(self, t):
        return (self.p0[0] + (self.p1[0] - self.p0[0]) * t, self.p0[1] + (self.p1[1] - self.p0[1]) * t)

    def part(self, t0, t1):
        return Line(self.at(t0), self.at(t1))

    def hits(self, cx, cy, r):
        dx, dy = self.p1[0] - self.p0[0], self.p1[1] - self.p0[1]
        fx, fy = self.p0[0] - cx, self.p0[1] - cy
        a, b, c = dx * dx + dy * dy, 2 * (fx * dx + fy * dy), fx * fx + fy * fy - r * r
        disc = b * b - 4 * a * c
        if a == 0 or disc < 0:
            return []
        return [t for t in ((-b - math.sqrt(disc)) / (2 * a), (-b + math.sqrt(disc)) / (2 * a)) if 0 <= t <= 1]

    def segs(self):
        return [("L", self.p0, self.p1)]


class Arc:
    """Circular arc, angles in radians (y-down, so increasing = clockwise on screen), drawn as `n` cubics."""

    def __init__(self, c, r, a0, a1, n=1):
        self.c, self.r, self.a0, self.a1, self.n = c, r, a0, a1, n

    def at(self, t):
        a = self.a0 + (self.a1 - self.a0) * t
        return (self.c[0] + self.r * math.cos(a), self.c[1] + self.r * math.sin(a))

    def part(self, t0, t1):
        return Arc(self.c, self.r, self.a0 + (self.a1 - self.a0) * t0, self.a0 + (self.a1 - self.a0) * t1, self.n)

    def hits(self, cx, cy, r):
        (x0, y0), r0 = self.c, self.r
        d = math.hypot(cx - x0, cy - y0)
        if d == 0 or d > r0 + r or d < abs(r0 - r):
            return []
        a = (r0 * r0 - r * r + d * d) / (2 * d)
        h = math.sqrt(max(r0 * r0 - a * a, 0))
        mx, my = x0 + a * (cx - x0) / d, y0 + a * (cy - y0) / d
        out = []
        for sx in (1, -1):
            px, py = mx + sx * h * (cy - y0) / d, my - sx * h * (cx - x0) / d
            phi = math.atan2(py - y0, px - x0)
            lo, hi = min(self.a0, self.a1), max(self.a0, self.a1)
            while phi < lo - 1e-9:
                phi += 2 * math.pi
            while phi > hi + 1e-9:
                phi -= 2 * math.pi
            if lo - 1e-9 <= phi <= hi + 1e-9:
                out.append((phi - self.a0) / (self.a1 - self.a0))
        return out

    def segs(self):
        out, da = [], (self.a1 - self.a0) / self.n
        k = 4.0 / 3.0 * math.tan(da / 4.0)
        cx, cy, r = self.c[0], self.c[1], self.r
        for i in range(self.n):
            s, e = self.a0 + da * i, self.a0 + da * (i + 1)
            p0 = (cx + r * math.cos(s), cy + r * math.sin(s))
            p3 = (cx + r * math.cos(e), cy + r * math.sin(e))
            p1 = (p0[0] - k * r * math.sin(s), p0[1] + k * r * math.cos(s))
            p2 = (p3[0] + k * r * math.sin(e), p3[1] - k * r * math.cos(e))
            out.append(("C", p0, p1, p2, p3))
        return out


def rrect_pieces(x0, y0, x1, y1, r):
    """Clockwise from the left end of the top edge (G1-continuous lines and quarter arcs)."""
    h = math.pi / 2
    return [Line((x0 + r, y0), (x1 - r, y0)), Arc((x1 - r, y0 + r), r, -h, 0),
            Line((x1, y0 + r), (x1, y1 - r)), Arc((x1 - r, y1 - r), r, 0, h),
            Line((x1 - r, y1), (x0 + r, y1)), Arc((x0 + r, y1 - r), r, h, 2 * h),
            Line((x0, y1 - r), (x0, y0 + r)), Arc((x0 + r, y0 + r), r, 2 * h, 3 * h)]


def inside(pieces, x, y):
    poly = [pc.at(i / 16) for pc in pieces for i in range(16)]
    hit = False
    for (ax, ay), (bx, by) in zip(poly, poly[1:] + poly[:1]):
        if (ay > y) != (by > y) and x < ax + (y - ay) * (bx - ax) / (by - ay):
            hit = not hit
    return hit


class Dot:
    """A zero-length stand-in for a piece the notch swallowed (keeps the command structure fixed across weights)."""

    def __init__(self, piece, p):
        self.piece, self.p = piece, p

    def at(self, t):
        return self.p

    def segs(self):
        return [("L", self.p, self.p)] if isinstance(self.piece, Line) else [("C", self.p, self.p, self.p, self.p)] * self.piece.n


def notched(pieces, cx, cy, nr, slot=4):
    """Replace the run of outline inside the circle (cx, cy, nr) with an arc of that circle (the badge clearance).
    The arc goes in before piece `slot` and swallowed pieces stay as zero-length stand-ins, so the path structure
    doesn't depend on where the circle happens to cross the outline (it does differ per weight)."""
    hits = sorted((i, t) for i, pc in enumerate(pieces) for t in pc.hits(cx, cy, nr))
    assert len(hits) == 2, f"notch must cross the outline twice, got {hits}"
    (i, ti), (j, tj) = hits
    pin, pout = pieces[i].at(ti), pieces[j].at(tj)
    a_in, a_out = math.atan2(pin[1] - cy, pin[0] - cx), math.atan2(pout[1] - cy, pout[0] - cx)
    for a1 in (a_out, a_out + 2 * math.pi, a_out - 2 * math.pi):        # the sweep whose middle lies in the body
        if abs(a1 - a_in) < 2 * math.pi:
            m = (a_in + a1) / 2
            if inside(pieces, cx + nr * math.cos(m), cy + nr * math.sin(m)):
                break
    else:
        raise AssertionError("no interior notch sweep")
    arc = Arc((cx, cy), nr, a_in, a1, 3)
    if i == j:
        return pieces[:i] + [pieces[i].part(0, ti), arc, pieces[i].part(tj, 1)] + pieces[i + 1:]
    assert i < slot <= j, f"notch crosses pieces {i}..{j}, outside slot {slot}"
    return (pieces[:i] + [pieces[i].part(0, ti)] + [Dot(pc, pin) for pc in pieces[i + 1:slot]] + [arc]
            + [Dot(pc, pout) for pc in pieces[slot:j]] + [pieces[j].part(tj, 1)] + pieces[j + 1:])


def emit(p, pieces, reverse=False):
    segs = [s for pc in pieces for s in pc.segs()]
    if reverse:
        segs = [("L", s[2], s[1]) if s[0] == "L" else ("C", s[4], s[3], s[2], s[1]) for s in reversed(segs)]
    p.m(*segs[0][1])
    for s in segs:
        if s[0] == "L":
            p.l(*s[2])
        else:
            p.c(*s[2], *s[3], *s[4])
    p.z()


# V2 "Sturdy" (owner pick, review S-12.02): heavy strokes, a big corner radius, a short shackle almost as wide as the
# body. Template units: 100 pt font, y grows downward, baseline y = 0.
V2 = dict(body=(0.0, -42.0, 68.0, 10.0, 17.0),            # x0, y0, x1, y1, corner radius
          cx=34.0, ro=26.0, cy=-52.0, depth=5.0, lift=10.0, free_open=6.0, free_closing=10.0,
          badge_c=(64.0, 3.0), badge_r=21.0,
          weights={"Ultralight": dict(t=5.4, b=4.6, gap=3.0, s=3.8, dot=5.0),
                   "Regular": dict(t=12.0, b=10.0, gap=4.5, s=7.2, dot=6.8),
                   "Black": dict(t=16.0, b=13.5, gap=5.0, s=9.4, dot=7.8)})

# The + (the app is LockPlus), centred in the body where a keyhole would be: a cut-out in filled bodies, a small filled +
# in the window of outline bodies. Per weight the + half length `s` and stroke `w`: `f` on filled bodies, `o` on outline
# bodies. It never touches the badge notch: `place_plus` moves it up and left, or shrinks it, until it clears.
PLUS = {"Ultralight": dict(f=(12.0, 3.8), o=(11.0, 3.2)),
        "Regular": dict(f=(12.0, 7.0), o=(10.0, 5.5)),
        "Black": dict(f=(12.0, 8.5), o=(8.5, 5.0))}


def outline_pieces(d):
    x0, y0, x1, y1, r = V2["body"]
    return rrect_pieces(x0 + d, y0 + d, x1 - d, y1 - d, max(r - d, 1.0))


def plus(p, x, y, s, w, reverse=False):
    """A + as one 12-point polygon, clockwise on screen (a filled +); reversed it is a hole."""
    h = w / 2
    pts = [(x - h, y - s), (x + h, y - s), (x + h, y - h), (x + s, y - h), (x + s, y + h), (x + h, y + h),
           (x + h, y + s), (x - h, y + s), (x - h, y + h), (x - s, y + h), (x - s, y - h), (x - h, y - h)]
    if reverse:
        pts = pts[:1] + pts[:0:-1]
    p.m(*pts[0])
    for q in pts[1:]:
        p.l(*q)
    p.z()


def plus_points(x, y, s, w):
    h = w / 2
    corners = [(x - h, y - s), (x + h, y - s), (x + h, y - h), (x + s, y - h), (x + s, y + h), (x + h, y + h),
               (x + h, y + s), (x - h, y + s), (x - h, y + h), (x - s, y + h), (x - s, y - h), (x - h, y - h)]
    pts = []
    for a, b in zip(corners, corners[1:] + corners[:1]):
        pts += [(a[0] + (b[0] - a[0]) * t / 4, a[1] + (b[1] - a[1]) * t / 4) for t in range(4)]
    return pts


def rrect_depth(px, py, x0, y0, x1, y1, r):
    """How far (px, py) lies inside the rounded rect (negative: outside). Signed distance, flipped."""
    cx, cy, hx, hy = (x0 + x1) / 2, (y0 + y1) / 2, (x1 - x0) / 2 - r, (y1 - y0) / 2 - r
    qx, qy = abs(px - cx) - hx, abs(py - cy) - hy
    outside = math.hypot(max(qx, 0), max(qy, 0)) + min(max(qx, qy), 0) - r
    return -outside


def body_plus_fits(x, y, s, w, wt, filled, badged):
    """The + keeps a margin to the body edge (cut-out) or to the window edge (outline), and to the badge notch."""
    d = 0.0 if filled else wt["b"]
    m = 0.6 * wt["b"] if filled else min(max(0.3 * wt["b"], 2.0), 3.5)
    x0, y0, x1, y1, r = V2["body"]
    bx, by = V2["badge_c"]
    nr = V2["badge_r"] + wt["gap"] + d
    for px, py in plus_points(x, y, s, w):
        if rrect_depth(px, py, x0 + d, y0 + d, x1 - d, y1 - d, max(r - d, 1.0)) < m:
            return False
        if badged and math.hypot(px - bx, py - by) < nr + m:
            return False
    return True


def place_plus(weight, filled, badged):
    """(x, y, s, w) of the body + for one symbol: centred if it fits; else the free spot nearest the centre (in the
    upper left, away from the badge); else smaller. The stroke stays, so the + keeps its weight."""
    wt = V2["weights"][weight]
    s, w = PLUS[weight]["f" if filled else "o"]
    x0, y0, x1, y1, _ = V2["body"]
    cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
    grid = sorted(((cx - i * 0.5, cy - j * 0.5) for i in range(0, 41) for j in range(-10, 31)),
                  key=lambda q: math.hypot(q[0] - cx, q[1] - cy))
    while s >= w * 0.9:
        for x, y in grid:
            if body_plus_fits(x, y, s, w, wt, filled, badged):
                return x, y, s, w
        s -= 0.5
    raise AssertionError(f"no room for the + ({weight}, filled={filled}, badged={badged})")


def v_body(weight, filled, badged):
    w = V2["weights"][weight]
    p = P()
    bx, by = V2["badge_c"]
    nr = V2["badge_r"] + w["gap"]
    outer = outline_pieces(0.0)
    emit(p, notched(outer, bx, by, nr) if badged else outer)
    if not filled:
        b = w["b"]
        inner = outline_pieces(b)
        emit(p, notched(inner, bx, by, nr + b) if badged else inner, reverse=True)
    x, y, s, pw = place_plus(weight, filled, badged)
    plus(p, x, y, s, pw, reverse=filled)          # a hole in a filled body, a filled + in an outline body's window
    return str(p)


def v_shackle(weight, lift, free_leg):
    w = V2["weights"][weight]
    t, ro, cx = w["t"], V2["ro"], V2["cx"]
    ri, cy = ro - t, V2["cy"] - lift
    into = V2["body"][1] + V2["depth"]           # legs end inside the body's top stroke
    left_bottom = into if free_leg is None else cy + free_leg
    p = P()
    p.m(cx - ro, left_bottom).l(cx - ro, cy)
    p.arc(cx, cy, ro, math.pi, 2 * math.pi, 2)
    p.l(cx + ro, into).l(cx + ri, into).l(cx + ri, cy)
    p.arc(cx, cy, ri, 2 * math.pi, math.pi, 2)
    p.l(cx - ri, left_bottom)
    p.z()
    return str(p)


def v_paths(weight, spec):
    sh, filled, bdg = spec
    if sh == "open":
        sp = v_shackle(weight, V2["lift"], V2["free_open"])
    elif sh == "closing":
        sp = v_shackle(weight, V2["lift"] / 2, V2["free_closing"])
    else:
        sp = v_shackle(weight, 0.0, None)
    paths = [v_body(weight, filled, bdg is not None), sp]
    if bdg:
        paths.append(badge(bdg, V2["weights"][weight], V2["badge_c"], V2["badge_r"]))
    return paths


def v_margins():
    return (-3.0, round(max(V2["body"][2], V2["badge_c"][0] + V2["badge_r"]) + 5.0, 1))


def v_group(weight, spec):
    inner = "\n".join(f'   <path {LAYER.format(i=i)} d="{d}"/>' for i, d in enumerate(v_paths(weight, spec)))
    return f'  <g id="{weight}-S" transform="matrix(1 0 0 1 {f(COLUMNS[weight])} 696)">\n{inner}\n  </g>'


def signature(d):
    return "".join(ch for ch in d if ch.isalpha())


def write_set(root, name, text):
    d = os.path.join(root, f"{name}.symbolset")
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, f"{name}.svg"), "w") as fh:
        fh.write(text)
    with open(os.path.join(d, "Contents.json"), "w") as fh:
        json.dump({"info": {"author": "xcode", "version": 1},
                   "symbols": [{"filename": f"{name}.svg", "idiom": "universal"}]}, fh, indent=2)


def write_contents(root, provides_namespace=False):
    os.makedirs(root, exist_ok=True)
    with open(os.path.join(root, "Contents.json"), "w") as fh:
        json.dump({"info": {"author": "xcode", "version": 1}, "properties": {"provides-namespace": provides_namespace}}, fh, indent=2)


def check_structure(label, spec):
    # every weight must have the same path structure, or the system can't interpolate the in-between weights
    sigs = {wt: [signature(d) for d in v_paths(wt, spec)] for wt in WEIGHTS}
    assert len({tuple(s) for s in sigs.values()}) == 1, f"{label}: weights differ in structure {sigs}"


def main():
    write_contents(ROOT)
    for name, spec in SYMBOLS.items():
        check_structure(name, spec)
        write_set(ROOT, name, svg(name, spec, v_margins(), v_group))
    print(f"wrote {len(SYMBOLS)} symbols to {ROOT}")


if __name__ == "__main__":
    main()
