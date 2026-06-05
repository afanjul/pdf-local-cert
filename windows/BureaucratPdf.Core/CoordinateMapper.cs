namespace BureaucratPdf.Core;

/// <summary>
/// Geometry bridge between the three coordinate spaces involved in placing a
/// visible signature. Ported verbatim from BureaucratPdfKit.CoordinateMapper
/// (apple/Sources/BureaucratPdfKit/CoordinateMapper.swift) — the math must stay
/// byte-identical so both shells place signatures in the same spot (anti-desync).
///
///   1. View space          — points over the rendered page, origin top-left, +y down.
///   2. Normalized displayed — fractions 0..1 of the *displayed* page box (after
///                             /Rotate), origin top-left. Zoom/resolution independent.
///   3. PDF user space       — the unrotated system /Rect lives in: origin bottom-left,
///                             +y up, points, offset by the cropBox origin.
/// </summary>
public readonly struct CoordinateMapper : IEquatable<CoordinateMapper>
{
    /// <summary>The page's cropBox in PDF user space (origin may be non-zero).</summary>
    public PdfRect CropBox { get; }

    /// <summary>/Rotate value, normalized to one of 0, 90, 180, 270.</summary>
    public int Rotation { get; }

    public CoordinateMapper(PdfRect cropBox, int rotation)
    {
        CropBox = cropBox;
        Rotation = ((rotation % 360) + 360) % 360;
    }

    /// <summary>Displayed (post-rotation) page size in points.</summary>
    public PdfSize DisplayedSize => Rotation switch
    {
        90 or 270 => new PdfSize(CropBox.Height, CropBox.Width),
        _ => new PdfSize(CropBox.Width, CropBox.Height),
    };

    // ── View ↔ normalized ────────────────────────────────────────────────────

    /// <summary>
    /// Convert a rect in view space (origin top-left) into a normalized rect,
    /// given the frame the page occupies in that same view space. Clamped to 0..1.
    /// </summary>
    public PdfRect Normalize(PdfRect viewRect, PdfRect pageFrame)
    {
        if (pageFrame.Width <= 0 || pageFrame.Height <= 0) return PdfRect.Zero;
        var nx = (viewRect.MinX - pageFrame.MinX) / pageFrame.Width;
        var ny = (viewRect.MinY - pageFrame.MinY) / pageFrame.Height;
        var nw = viewRect.Width / pageFrame.Width;
        var nh = viewRect.Height / pageFrame.Height;
        return Clamp01(new PdfRect(nx, ny, nw, nh));
    }

    /// <summary>Inverse of <see cref="Normalize"/> — place a normalized rect back into a view frame.</summary>
    public PdfRect ViewRect(PdfRect n, PdfRect pageFrame) => new(
        pageFrame.MinX + n.MinX * pageFrame.Width,
        pageFrame.MinY + n.MinY * pageFrame.Height,
        n.Width * pageFrame.Width,
        n.Height * pageFrame.Height);

    // ── Normalized ↔ PDF user space ──────────────────────────────────────────

    /// <summary>
    /// Map a normalized displayed rect (origin top-left) to a PDF user-space rect
    /// (origin bottom-left, unrotated, cropBox-offset) for /Rect.
    /// </summary>
    public PdfRect UserSpaceRect(PdfRect n)
    {
        var d = DisplayedSize;
        // Normalized (top-left) → displayed points (bottom-left origin).
        var dx = n.MinX * d.Width;
        var dw = n.Width * d.Width;
        var dh = n.Height * d.Height;
        var dy = d.Height - (n.MinY * d.Height) - dh; // flip y
        // The two opposite corners of the box in displayed space.
        var c0 = DisplayedToLocal(new PdfPoint(dx, dy));
        var c1 = DisplayedToLocal(new PdfPoint(dx + dw, dy + dh));
        var minX = Math.Min(c0.X, c1.X);
        var minY = Math.Min(c0.Y, c1.Y);
        var maxX = Math.Max(c0.X, c1.X);
        var maxY = Math.Max(c0.Y, c1.Y);
        return new PdfRect(
            CropBox.MinX + minX,
            CropBox.MinY + minY,
            maxX - minX,
            maxY - minY);
    }

    /// <summary>Inverse: PDF user-space rect → normalized displayed rect (top-left).</summary>
    public PdfRect NormalizedRect(PdfRect r)
    {
        var local0 = new PdfPoint(r.MinX - CropBox.MinX, r.MinY - CropBox.MinY);
        var local1 = new PdfPoint(r.MaxX - CropBox.MinX, r.MaxY - CropBox.MinY);
        var d0 = LocalToDisplayed(local0);
        var d1 = LocalToDisplayed(local1);
        var dminX = Math.Min(d0.X, d1.X);
        var dmaxX = Math.Max(d0.X, d1.X);
        var dminY = Math.Min(d0.Y, d1.Y);
        var dmaxY = Math.Max(d0.Y, d1.Y);
        var d = DisplayedSize;
        if (d.Width <= 0 || d.Height <= 0) return PdfRect.Zero;
        var nx = dminX / d.Width;
        var nw = (dmaxX - dminX) / d.Width;
        var nh = (dmaxY - dminY) / d.Height;
        // Flip y back to top-left origin.
        var ny = 1.0 - (dmaxY / d.Height);
        return new PdfRect(nx, ny, nw, nh);
    }

    // ── Rotation core (page-local, bottom-left origin) ───────────────────────

    /// <summary>Displayed-space point (bottom-left) → page-local point (unrotated, bottom-left).</summary>
    private PdfPoint DisplayedToLocal(PdfPoint p)
    {
        var w = CropBox.Width;
        var h = CropBox.Height;
        return Rotation switch
        {
            90 => new PdfPoint(w - p.Y, p.X),
            180 => new PdfPoint(w - p.X, h - p.Y),
            270 => new PdfPoint(p.Y, h - p.X),
            _ => p,
        };
    }

    /// <summary>Page-local point → displayed-space point (inverse of <see cref="DisplayedToLocal"/>).</summary>
    private PdfPoint LocalToDisplayed(PdfPoint p)
    {
        var w = CropBox.Width;
        var h = CropBox.Height;
        return Rotation switch
        {
            90 => new PdfPoint(p.Y, w - p.X),
            180 => new PdfPoint(w - p.X, h - p.Y),
            270 => new PdfPoint(h - p.Y, p.X),
            _ => p,
        };
    }

    private static PdfRect Clamp01(PdfRect r)
    {
        var x = Math.Max(0, Math.Min(1, r.MinX));
        var y = Math.Max(0, Math.Min(1, r.MinY));
        var w = Math.Max(0, Math.Min(1 - x, r.Width));
        var h = Math.Max(0, Math.Min(1 - y, r.Height));
        return new PdfRect(x, y, w, h);
    }

    public bool Equals(CoordinateMapper other) => CropBox.Equals(other.CropBox) && Rotation == other.Rotation;
    public override bool Equals(object? obj) => obj is CoordinateMapper m && Equals(m);
    public override int GetHashCode() => HashCode.Combine(CropBox, Rotation);
}
