namespace PdfLocalCert.Core;

/// <summary>A point. Mirrors CoreGraphics.CGPoint (origin semantics depend on the space).</summary>
public readonly record struct PdfPoint(double X, double Y);

/// <summary>A size in points. Mirrors CoreGraphics.CGSize.</summary>
public readonly record struct PdfSize(double Width, double Height);

/// <summary>
/// A rect, defined by its origin (min-x, min-y) and size. Mirrors CoreGraphics.CGRect.
/// Note the macOS original uses bottom-left origin in PDF user space and top-left in
/// view/normalized space — the mapper documents which is which per method.
/// </summary>
public readonly record struct PdfRect(double X, double Y, double Width, double Height)
{
    public double MinX => X;
    public double MinY => Y;
    public double MaxX => X + Width;
    public double MaxY => Y + Height;

    public static readonly PdfRect Zero = new(0, 0, 0, 0);
}
