#!/usr/bin/env python3
"""Generate samples/grid-a4.pdf: an A4 calibration grid for signature-placement tests.

Coordinates are PDF user-space points with origin at the BOTTOM-LEFT — the same space
the core writes to /Rect. Major gridlines every 50 pt are labelled with their x/y value;
minor lines every 10 pt are faint. Corners and centre are marked so a placed signature
box can be read off the page directly (e.g. "box landed at x≈100, y≈700, ~140pt wide").

No third-party deps — emits the PDF by hand (Helvetica is a standard-14 font).
"""
from pathlib import Path

W, H = 595.276, 841.890  # A4, matches samples/contract-sample.pdf MediaBox

def main() -> None:
    g = []  # content-stream pieces
    g.append("q")

    # minor grid (every 10 pt), faint
    g.append("0.88 0.88 0.88 RG 0.3 w")
    x = 0.0
    while x <= W:
        g.append(f"{x:.2f} 0 m {x:.2f} {H:.2f} l S")
        x += 10
    y = 0.0
    while y <= H:
        g.append(f"0 {y:.2f} m {W:.2f} {y:.2f} l S")
        y += 10

    # major grid (every 50 pt), darker
    g.append("0.55 0.55 0.55 RG 0.6 w")
    x = 0.0
    while x <= W:
        g.append(f"{x:.2f} 0 m {x:.2f} {H:.2f} l S")
        x += 50
    y = 0.0
    while y <= H:
        g.append(f"0 {y:.2f} m {W:.2f} {y:.2f} l S")
        y += 50

    # border
    g.append("0 0 0 RG 1 w")
    g.append(f"0 0 {W:.2f} {H:.2f} re S")

    # labels at every 50 pt: x along bottom, y along left
    g.append("0 0 0.8 rg BT /F1 6 Tf")
    x = 50.0
    while x < W:
        g.append(f"1 0 0 1 {x+1:.2f} 3 Tm ({int(x)}) Tj")
        x += 50
    y = 50.0
    while y < H:
        g.append(f"1 0 0 1 2 {y+1:.2f} Tm ({int(y)}) Tj")
        y += 50
    g.append("ET")

    # corner + centre markers with origin note
    g.append("1 0 0 rg BT /F1 9 Tf")
    g.append(f"1 0 0 1 6 {H-14:.2f} Tm (TOP-LEFT  \\(x=0, y={H:.0f}\\)) Tj")
    g.append(f"1 0 0 1 6 6 Tm (BOTTOM-LEFT origin \\(0,0\\)) Tj")
    g.append(f"1 0 0 1 {W/2-30:.2f} {H/2:.2f} Tm (centre {W/2:.0f},{H/2:.0f}) Tj")
    g.append("ET")
    g.append("Q")

    content = "\n".join(g).encode("latin-1")

    objs = [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        f"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {W} {H}] "
        f"/Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>".encode("latin-1"),
        b"<< /Length " + str(len(content)).encode() + b" >>\nstream\n" + content + b"\nendstream",
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
    ]

    out = bytearray(b"%PDF-1.4\n")
    offsets = []
    for i, body in enumerate(objs, start=1):
        offsets.append(len(out))
        out += f"{i} 0 obj\n".encode() + body + b"\nendobj\n"
    xref = len(out)
    out += f"xref\n0 {len(objs)+1}\n".encode()
    out += b"0000000000 65535 f \n"
    for off in offsets:
        out += f"{off:010d} 00000 n \n".encode()
    out += (f"trailer\n<< /Size {len(objs)+1} /Root 1 0 R >>\n"
            f"startxref\n{xref}\n%%EOF\n").encode()

    dest = Path(__file__).with_name("grid-a4.pdf")
    dest.write_bytes(out)
    print(f"wrote {dest} ({len(out):,} bytes, {W}x{H} pt)")

if __name__ == "__main__":
    main()
