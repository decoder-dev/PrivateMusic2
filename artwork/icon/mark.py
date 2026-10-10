"""PM monogram on a 1024 grid. One source of truth for every icon variant."""
S = 66                     # stroke / stem width
X0 = 318                   # centre of the shared stem
XR = 706                   # right edge (centreline) of bowl and M
TOP = 210                  # centreline of the P's top bar
BOWL_BOTTOM = 490          # centreline of the bowl's bottom bar
R = (BOWL_BOTTOM - TOP) / 2
M_TOP = 574                # flat top of the M's right stem
M_BOTTOM = 818
OPTICAL_SHIFT_Y = 14

x1, x2 = X0 - S / 2, X0 + S / 2
x4, x3 = XR + S / 2, XR - S / 2
XM = (x1 + x4) / 2
Y_VALLEY = M_TOP + 150
Y_APEX = Y_VALLEY + 84
SLOPE = (Y_VALLEY - M_TOP) / (XM - x2)
Y_LOWER = Y_APEX - SLOPE * (XM - x2)

def p_path(fill):
    bowl_x = XR - R
    # stem (down into the M) + closed half-round bowl, drawn as one outline
    outer = (f"M{x1} {M_BOTTOM} V{TOP - S/2} H{bowl_x} "
             f"A{R + S/2} {R + S/2} 0 0 1 {bowl_x} {BOWL_BOTTOM + S/2} H{x1} Z")
    inner = (f"M{x2} {TOP + S/2} H{bowl_x} "
             f"A{R - S/2} {R - S/2} 0 0 1 {bowl_x} {BOWL_BOTTOM - S/2} H{x2} Z")
    stem = (f'<rect x="{x1}" y="{BOWL_BOTTOM}" width="{S}" '
            f'height="{M_TOP - BOWL_BOTTOM + 2}" fill="{fill}"/>')
    return (f'<path fill="{fill}" fill-rule="evenodd" d="{outer} {inner}"/>\n'
            + stem)

def m_path(fill):
    pts = [(x2, M_BOTTOM), (x2, Y_LOWER), (XM, Y_APEX), (x3, Y_LOWER),
           (x3, M_BOTTOM), (x4, M_BOTTOM), (x4, M_TOP), (x3, M_TOP),
           (XM, Y_VALLEY), (x2, M_TOP), (x1, M_TOP), (x1, M_BOTTOM)]
    d = "M" + " L".join(f"{x:.2f} {y:.2f}" for x, y in pts) + " Z"
    return f'<path fill="{fill}" d="{d}"/>'

def bars(fill):
    cx = (x2 + (XR - R + R - S / 2)) / 2 - 6
    cy = (TOP + BOWL_BOTTOM) / 2
    heights = [60, 112, 164, 112, 60]
    out = []
    for i, h in enumerate(heights):
        x = cx + (i - 2) * 46
        out.append(f'<rect x="{x - 11:.2f}" y="{cy - h / 2:.2f}" width="22" height="{h}" rx="11" fill="{fill}"/>')
    return "\n".join(out)

def monogram(fill="#FFFFFF", bar_fill="#FFFFFF"):
    # Optical centring: the mark's bounding box sits a little high.
    body = "\n".join([p_path(fill), m_path(fill), bars(bar_fill)])
    return f'<g transform="translate(0 {OPTICAL_SHIFT_Y})">\n{body}\n</g>'
