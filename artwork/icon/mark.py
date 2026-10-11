"""Private Music's rounded PM ligature on a 1024-unit optical grid.

The shared stem ties Privacy and Music together. Three sound bars occupy
its P counter. All appearances and the launch screen use this geometry.
"""


def monogram(fill="#F4F7FC", bar_fill="#89B6FF"):
    return f'''<g fill="none" stroke="{fill}" stroke-width="76"
    stroke-linecap="round" stroke-linejoin="round">
  <path d="M324 744 V280 H564 C647 280 700 327 700 396
    C700 465 647 512 564 512 H324"/>
  <path d="M324 558 L512 710 L700 558 V744"/>
</g>
<g fill="{bar_fill}">
  <rect x="442" y="368" width="28" height="56" rx="14"/>
  <rect x="502" y="344" width="28" height="104" rx="14"/>
  <rect x="562" y="368" width="28" height="56" rx="14"/>
</g>'''
