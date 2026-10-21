"""SVG icon and figure helpers. Every function returns an SVG fragment string.

Coordinates are in the slide's viewBox (1280 x 600 for vslide main slides).
Icons draw in their FINAL state; animation classes only move them from a start offset.
"""
import math
from kit import esc

NAVY, CYAN, ORANGE, GREY, LGREY, LCYAN, WHITE = "#003c68", "#0099cc", "#ea6b13", "#545e69", "#9aa5b1", "#4dc9f6", "#ffffff"


def T(x, y, s, size=20, color=NAVY, anchor="middle", weight=700, cls="", extra=""):
    c = f' class="{cls}"' if cls else ""
    return (f'<text x="{x}" y="{y}" font-size="{size}" fill="{color}" text-anchor="{anchor}" '
            f'font-weight="{weight}"{c} {extra}>{esc(s)}</text>')


def A(content, cls="a-up", d=0.0, extra=""):
    """Animated group: cls is the animation, d the delay in seconds."""
    return f'<g class="{cls}" style="--d:{d}s" {extra}>{content}</g>'


def person(cx, cy, s=1.0, color=NAVY, fill="none"):
    return (f'<g transform="translate({cx},{cy}) scale({s})">'
            f'<circle cx="0" cy="-22" r="13" fill="{fill}" stroke="{color}" stroke-width="3.5"/>'
            f'<path d="M-24 26 C-24 0 24 0 24 26" fill="{fill}" stroke="{color}" stroke-width="3.5" stroke-linecap="round"/></g>')


def cloud(cx, cy, s=1.0, color=NAVY, fill="#fff", label=None):
    out = (f'<g transform="translate({cx},{cy}) scale({s})">'
           f'<path d="M-46 22 H48 A24 24 0 0 0 44 -24 A34 34 0 0 0 -20 -30 A26 26 0 0 0 -46 22 Z" '
           f'fill="{fill}" stroke="{color}" stroke-width="3.5" stroke-linejoin="round"/></g>')
    if label:
        out += T(cx, cy + 10 * s, label, 18 * s, color)
    return out


def doc(cx, cy, s=1.0, color=NAVY, fill="#fff", lines=3):
    w, h = 54, 68
    out = [f'<g transform="translate({cx},{cy}) scale({s})">',
           f'<path d="M{-w/2} {-h/2} H{w/2-14} L{w/2} {-h/2+14} V{h/2} H{-w/2} Z" fill="{fill}" stroke="{color}" stroke-width="3" stroke-linejoin="round"/>',
           f'<path d="M{w/2-14} {-h/2} V{-h/2+14} H{w/2}" fill="none" stroke="{color}" stroke-width="3" stroke-linejoin="round"/>']
    for k in range(lines):
        y = -h / 2 + 26 + k * 12
        out.append(f'<line x1="{-w/2+10}" y1="{y}" x2="{w/2-10 - (12 if k == lines-1 else 0)}" y2="{y}" stroke="{color}" stroke-width="3" stroke-linecap="round" opacity=".55"/>')
    out.append("</g>")
    return "".join(out)


def magnifier(cx, cy, s=1.0, color=NAVY):
    return (f'<g transform="translate({cx},{cy}) scale({s})"><circle cx="-6" cy="-6" r="20" fill="#fff" stroke="{color}" stroke-width="4"/>'
            f'<line x1="9" y1="9" x2="26" y2="26" stroke="{color}" stroke-width="7" stroke-linecap="round"/></g>')


def gear(cx, cy, r=34, color=NAVY, fill="#fff", teeth=9, cls="", d=0):
    pts = []
    for k in range(teeth * 2):
        a = math.pi * k / teeth
        rr = r if k % 2 == 0 else r * 0.78
        a1, a2 = a - math.pi / teeth * 0.42, a + math.pi / teeth * 0.42
        pts.append(f"{cx + rr * math.cos(a1):.1f},{cy + rr * math.sin(a1):.1f}")
        pts.append(f"{cx + rr * math.cos(a2):.1f},{cy + rr * math.sin(a2):.1f}")
    c = f' class="{cls}" style="--d:{d}s"' if cls else ""
    return (f'<g{c}><polygon points="{" ".join(pts)}" fill="{fill}" stroke="{color}" stroke-width="3" stroke-linejoin="round"/>'
            f'<circle cx="{cx}" cy="{cy}" r="{r*0.3:.1f}" fill="#fff" stroke="{color}" stroke-width="3"/></g>')


def clock(cx, cy, r=40, color=GREY):
    return (f'<circle cx="{cx}" cy="{cy}" r="{r}" fill="#fff" stroke="{color}" stroke-width="4"/>'
            f'<line x1="{cx}" y1="{cy}" x2="{cx}" y2="{cy - r*0.62}" stroke="{color}" stroke-width="4" stroke-linecap="round"/>'
            f'<g class="a-spin-slow" style="transform-origin:{cx}px {cy}px"><line x1="{cx}" y1="{cy}" x2="{cx + r*0.5}" y2="{cy + r*0.3}" stroke="{ORANGE}" stroke-width="4" stroke-linecap="round"/></g>'
            f'<circle cx="{cx}" cy="{cy}" r="4" fill="{color}"/>')


def lock(cx, cy, s=1.0, color=NAVY):
    return (f'<g transform="translate({cx},{cy}) scale({s})"><path d="M-10 -4 V-14 A10 10 0 0 1 10 -14 V-4" fill="none" stroke="{color}" stroke-width="3.5"/>'
            f'<rect x="-15" y="-4" width="30" height="24" rx="4" fill="{color}"/></g>')


def coin(cx, cy, r=22, color=ORANGE):
    return (f'<circle cx="{cx}" cy="{cy}" r="{r}" fill="#fdf0e6" stroke="{color}" stroke-width="3.5"/>'
            f'<circle cx="{cx}" cy="{cy}" r="{r*0.62:.1f}" fill="none" stroke="{color}" stroke-width="2.5"/>')


def shield(cx, cy, s=1.0, color=NAVY, fill="#e6f4fa"):
    return (f'<g transform="translate({cx},{cy}) scale({s})"><path d="M0 -30 L26 -20 V2 C26 18 14 28 0 34 C-14 28 -26 18 -26 2 V-20 Z" '
            f'fill="{fill}" stroke="{color}" stroke-width="3.5" stroke-linejoin="round"/></g>')


def robot(cx, cy, s=1.0, color=NAVY):
    return (f'<g transform="translate({cx},{cy}) scale({s})"><line x1="0" y1="-34" x2="0" y2="-24" stroke="{color}" stroke-width="3.5"/>'
            f'<circle cx="0" cy="-37" r="4" fill="{ORANGE}"/>'
            f'<rect x="-26" y="-24" width="52" height="40" rx="10" fill="#fff" stroke="{color}" stroke-width="3.5"/>'
            f'<circle cx="-10" cy="-5" r="5" fill="{color}"/><circle cx="10" cy="-5" r="5" fill="{color}"/>'
            f'<line x1="-9" y1="8" x2="9" y2="8" stroke="{color}" stroke-width="3" stroke-linecap="round"/>'
            f'<rect x="-18" y="18" width="36" height="16" rx="5" fill="#fff" stroke="{color}" stroke-width="3"/></g>')


def chainlink(cx, cy, s=1.0, color=NAVY):
    return (f'<g transform="translate({cx},{cy}) scale({s}) rotate(-35)">'
            f'<rect x="-30" y="-10" width="36" height="20" rx="10" fill="none" stroke="{color}" stroke-width="4"/>'
            f'<rect x="-6" y="-10" width="36" height="20" rx="10" fill="none" stroke="{color}" stroke-width="4"/></g>')


def stamp(cx, cy, s=1.0, color=ORANGE):
    return (f'<g transform="translate({cx},{cy}) scale({s})"><rect x="-8" y="-38" width="16" height="22" rx="4" fill="{color}"/>'
            f'<path d="M-22 -16 H22 L26 0 H-26 Z" fill="{color}"/><rect x="-28" y="0" width="56" height="8" rx="2" fill="{color}"/></g>')


def server(cx, cy, s=1.0, color=NAVY, fill="#fff"):
    out = [f'<g transform="translate({cx},{cy}) scale({s})">']
    for k in range(3):
        y = -36 + k * 25
        out.append(f'<rect x="-34" y="{y}" width="68" height="21" rx="4" fill="{fill}" stroke="{color}" stroke-width="3"/>')
        out.append(f'<circle cx="-22" cy="{y+10.5}" r="3.5" fill="{ORANGE if k == 0 else color}"/>')
        out.append(f'<line x1="-8" y1="{y+10.5}" x2="22" y2="{y+10.5}" stroke="{color}" stroke-width="3" stroke-linecap="round" opacity=".5"/>')
    out.append("</g>")
    return "".join(out)


def laptop(cx, cy, s=1.0, color=NAVY):
    return (f'<g transform="translate({cx},{cy}) scale({s})"><rect x="-38" y="-30" width="76" height="48" rx="5" fill="#fff" stroke="{color}" stroke-width="3.5"/>'
            f'<path d="M-50 22 H50 L44 32 H-44 Z" fill="{color}"/></g>')


def hourglass(cx, cy, s=1.0, color=ORANGE):
    return (f'<g transform="translate({cx},{cy}) scale({s})"><path d="M-16 -24 H16 M-16 24 H16" stroke="{color}" stroke-width="4" stroke-linecap="round"/>'
            f'<path d="M-12 -24 C-12 -6 12 -6 12 0 C12 6 -12 6 -12 24 M12 -24 C12 -6 -12 -6 -12 0 C-12 6 12 6 12 24" fill="none" stroke="{color}" stroke-width="3"/>'
            f'<path d="M-7 18 H7 L0 8 Z" fill="{color}"/></g>')


def check(cx, cy, s=1.0, color=NAVY, w=7):
    return f'<path d="M{cx-16*s} {cy} l{11*s} {12*s} l{22*s} {-26*s}" fill="none" stroke="{color}" stroke-width="{w}" stroke-linecap="round" stroke-linejoin="round"/>'


def cross(cx, cy, s=1.0, color=ORANGE, w=7):
    return (f'<path d="M{cx-12*s} {cy-12*s} L{cx+12*s} {cy+12*s} M{cx+12*s} {cy-12*s} L{cx-12*s} {cy+12*s}" '
            f'stroke="{color}" stroke-width="{w}" stroke-linecap="round"/>')


def badge(cx, cy, r, kind):
    """Round result badge: kind in ok / bad / neutral."""
    if kind == "ok":
        return f'<circle cx="{cx}" cy="{cy}" r="{r}" fill="{NAVY}"/>' + check(cx, cy + 2, r / 26, WHITE, 5)
    if kind == "bad":
        return f'<circle cx="{cx}" cy="{cy}" r="{r}" fill="{ORANGE}"/>' + cross(cx, cy, r / 26, WHITE, 5)
    return f'<circle cx="{cx}" cy="{cy}" r="{r}" fill="#fff" stroke="{LGREY}" stroke-width="2.5"/>' + f'<line x1="{cx-r*0.4}" y1="{cy}" x2="{cx+r*0.4}" y2="{cy}" stroke="{LGREY}" stroke-width="4" stroke-linecap="round"/>'


def fingerprint(cx, cy, s=1.0, color=NAVY):
    out = [f'<g transform="translate({cx},{cy}) scale({s})" fill="none" stroke="{color}" stroke-width="2.6" stroke-linecap="round">']
    for k, r in enumerate((6, 12, 18, 24)):
        out.append(f'<path d="M{-r} {r*0.35} A{r} {r*1.15} 0 0 1 {r} {r*0.35}"/>')
        out.append(f'<path d="M{-r} {r*0.35} V{r*0.35 + 6 + k*2}"/>')
    out.append("</g>")
    return "".join(out)


def block(x, y, w=74, h=50, label="", color=NAVY, fill="#fff", tcolor=None, cls="", d=0):
    c = f' class="{cls}" style="--d:{d}s"' if cls else ""
    return (f'<g{c}><rect x="{x}" y="{y}" width="{w}" height="{h}" rx="7" fill="{fill}" stroke="{color}" stroke-width="2.5"/>'
            + (T(x + w / 2, y + h / 2 + 6, label, 16, tcolor or color) if label else "") + "</g>")


def chain(x, y, n, w=74, h=50, gap=18, color=NAVY, labels=None, fill="#fff", cls="a-pop", d0=0.0, step=0.12):
    out = []
    for k in range(n):
        bx = x + k * (w + gap)
        if k:
            out.append(f'<line x1="{bx-gap}" y1="{y+h/2}" x2="{bx}" y2="{y+h/2}" stroke="{color}" stroke-width="3"/>')
        out.append(block(bx, y, w, h, (labels[k] if labels else f"#{k+1}"), color, fill, cls=cls, d=d0 + step * k))
    return "".join(out)


def flow(path_d, color=ORANGE, n=3, dur=2.4, r=6, d=0.0):
    """Dots travelling along a path, looping (hidden in still/print mode)."""
    out = []
    for k in range(n):
        begin = d + k * dur / n
        out.append(f'<circle r="{r}" fill="{color}" class="flowdot" style="--d:{d}s"><animateMotion dur="{dur}s" begin="{begin:.2f}s" repeatCount="indefinite" path="{path_d}"/></circle>')
    return "".join(out)


def arrow_path(d, color=NAVY, w=3.5, dash=None, cls="", delay=0, head=True):
    da = f' stroke-dasharray="{dash}"' if dash else ""
    c = f' class="{cls}" style="--d:{delay}s"' if cls else ""
    mid = f' marker-end="url(#ah-{color.strip("#")})"' if head else ""
    return f'<path d="{d}" fill="none" stroke="{color}" stroke-width="{w}" stroke-linecap="round"{da}{c}{mid} pathLength="1"/>'


def defs():
    out = ['<defs>']
    for col in (NAVY, CYAN, ORANGE, GREY, LGREY, LCYAN, WHITE):
        out.append(f'<marker id="ah-{col.strip("#")}" viewBox="0 0 10 10" refX="7" refY="5" markerWidth="4.5" markerHeight="4.5" orient="auto-start-reverse">'
                   f'<path d="M0 0 L10 5 L0 10 Z" fill="{col}"/></marker>')
    out.append('</defs>')
    return "".join(out)


def pill(cx, cy, w, h, text, fill=NAVY, color=WHITE, size=17, stroke=None):
    st = f' stroke="{stroke}" stroke-width="2"' if stroke else ""
    return (f'<rect x="{cx-w/2}" y="{cy-h/2}" width="{w}" height="{h}" rx="{h/2}" fill="{fill}"{st}/>'
            + T(cx, cy + size * 0.36, text, size, color))
