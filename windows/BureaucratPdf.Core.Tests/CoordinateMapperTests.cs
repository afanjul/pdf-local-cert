using BureaucratPdf.Core;
using Xunit;

namespace BureaucratPdf.Core.Tests;

/// <summary>
/// Ported verbatim from CoordinateMapperTests.swift. Same A4 page, same cases,
/// same tolerances — proves the C# geometry matches the macOS implementation so
/// signatures land in identical spots on both shells.
/// </summary>
public class CoordinateMapperTests
{
    private static readonly PdfRect A4 = new(0, 0, 595, 842);

    private static void AssertRectClose(PdfRect a, PdfRect b, double tol = 0.01, string msg = "")
    {
        Assert.True(Math.Abs(a.MinX - b.MinX) <= tol, $"minX {msg}: {a.MinX} vs {b.MinX}");
        Assert.True(Math.Abs(a.MinY - b.MinY) <= tol, $"minY {msg}: {a.MinY} vs {b.MinY}");
        Assert.True(Math.Abs(a.Width - b.Width) <= tol, $"w {msg}: {a.Width} vs {b.Width}");
        Assert.True(Math.Abs(a.Height - b.Height) <= tol, $"h {msg}: {a.Height} vs {b.Height}");
    }

    [Fact]
    public void DisplayedSizeRotation()
    {
        Assert.Equal(new PdfSize(595, 842), new CoordinateMapper(A4, 0).DisplayedSize);
        Assert.Equal(new PdfSize(595, 842), new CoordinateMapper(A4, 180).DisplayedSize);
        Assert.Equal(new PdfSize(842, 595), new CoordinateMapper(A4, 90).DisplayedSize);
        Assert.Equal(new PdfSize(842, 595), new CoordinateMapper(A4, 270).DisplayedSize);
    }

    [Fact]
    public void RotationNormalization()
    {
        Assert.Equal(0, new CoordinateMapper(A4, 360).Rotation);
        Assert.Equal(270, new CoordinateMapper(A4, -90).Rotation);
        Assert.Equal(90, new CoordinateMapper(A4, 450).Rotation);
    }

    [Fact]
    public void UserSpaceRotation0()
    {
        var m = new CoordinateMapper(A4, 0);
        var n = new PdfRect(0.1, 0.1, 0.2, 0.1); // top-left 10%/10%, 20% wide, 10% tall
        var r = m.UserSpaceRect(n);
        AssertRectClose(r, new PdfRect(59.5, 673.6, 119, 84.2), 0.05);
    }

    [Fact]
    public void TopLeftCornerAllRotations()
    {
        var n = new PdfRect(0, 0, 0.1, 0.1);
        var r0 = new CoordinateMapper(A4, 0).UserSpaceRect(n);
        AssertRectClose(r0, new PdfRect(0, 842 - 84.2, 59.5, 84.2), 0.05, "rot0");
        var r180 = new CoordinateMapper(A4, 180).UserSpaceRect(n);
        AssertRectClose(r180, new PdfRect(595 - 59.5, 0, 59.5, 84.2), 0.05, "rot180");
    }

    [Fact]
    public void RoundTripNormalizedAllRotations()
    {
        var boxes = new[]
        {
            new PdfRect(0.0, 0.0, 0.3, 0.2),
            new PdfRect(0.5, 0.6, 0.4, 0.3),
            new PdfRect(0.12, 0.34, 0.2, 0.15),
        };
        foreach (var rot in new[] { 0, 90, 180, 270 })
        {
            var m = new CoordinateMapper(A4, rot);
            foreach (var n in boxes)
            {
                var user = m.UserSpaceRect(n);
                var back = m.NormalizedRect(user);
                AssertRectClose(back, n, 0.0001, $"rot {rot} box {n}");
            }
        }
    }

    [Fact]
    public void CropBoxOffset()
    {
        var cb = new PdfRect(10, 20, 595, 842);
        var m = new CoordinateMapper(cb, 0);
        var n = new PdfRect(0, 0, 0.1, 0.1); // top-left
        var r = m.UserSpaceRect(n);
        AssertRectClose(r, new PdfRect(10, 20 + 842 - 84.2, 59.5, 84.2), 0.05);
    }

    [Fact]
    public void ZoomIndependenceNormalize()
    {
        var m = new CoordinateMapper(A4, 0);
        foreach (var scale in new[] { 0.25, 0.5, 1.0, 2.0, 4.0 })
        {
            var pageFrame = new PdfRect(0, 0, 595 * scale, 842 * scale);
            var viewRect = new PdfRect(
                0.1 * pageFrame.Width, 0.1 * pageFrame.Height,
                0.2 * pageFrame.Width, 0.1 * pageFrame.Height);
            var n = m.Normalize(viewRect, pageFrame);
            AssertRectClose(n, new PdfRect(0.1, 0.1, 0.2, 0.1), 0.0001, $"scale {scale}");
        }
    }

    [Fact]
    public void ViewRectRoundTrip()
    {
        var m = new CoordinateMapper(A4, 0);
        var pageFrame = new PdfRect(30, 40, 595, 842);
        var viewRect = new PdfRect(100, 120, 200, 80);
        var n = m.Normalize(viewRect, pageFrame);
        var back = m.ViewRect(n, pageFrame);
        AssertRectClose(back, viewRect, 0.0001);
    }

    [Fact]
    public void FullPipelineAccuracy()
    {
        var m = new CoordinateMapper(A4, 90);
        var pageFrame = new PdfRect(0, 0, 842, 595); // displayed (rotated) at 100%
        var viewRect = new PdfRect(84.2, 59.5, 168.4, 59.5);
        var n = m.Normalize(viewRect, pageFrame);
        var user = m.UserSpaceRect(n);
        var back = m.ViewRect(m.NormalizedRect(user), pageFrame);
        AssertRectClose(back, viewRect, 2.0);
    }

    [Fact]
    public void ClampingOutOfBounds()
    {
        var m = new CoordinateMapper(A4, 0);
        var pageFrame = new PdfRect(0, 0, 595, 842);
        var viewRect = new PdfRect(-50, -50, 700, 1000);
        var n = m.Normalize(viewRect, pageFrame);
        Assert.True(n.MinX >= 0);
        Assert.True(n.MinY >= 0);
        Assert.True(n.MaxX <= 1.0001);
        Assert.True(n.MaxY <= 1.0001);
    }
}
