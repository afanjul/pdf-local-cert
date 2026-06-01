using System.ComponentModel;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media.Imaging;
using PdfLocalCert.Core;
using Windows.Data.Pdf;
using Windows.Storage;
using Windows.Storage.Streams;

namespace PdfLocalCert.App;

/// <summary>
/// Renders PDF pages to bitmaps via Windows.Data.Pdf -- the Windows equivalent of
/// PDFKit's PDFView. One rendered page = one RenderedPage (image + the page's true
/// point size, needed by the placement overlay via CoordinateMapper).
/// </summary>
public sealed class PdfRenderer
{
    public PdfDocument? Document { get; private set; }
    public string? FilePath { get; private set; }

    /// <summary>Bitmap pixels per PDF point.</summary>
    public const double RenderScale = 1.5;

    public async Task<bool> LoadAsync(string path)
    {
        var file = await StorageFile.GetFileFromPathAsync(path);
        Document = await PdfDocument.LoadFromFileAsync(file);
        FilePath = path;
        return Document.PageCount > 0;
    }

    /// <summary>Drop the current document (return to the empty state).</summary>
    public void Reset()
    {
        Document = null;
        FilePath = null;
    }

    /// <summary>Render one page at RenderScale times its native size.</summary>
    public async Task<RenderedPage> RenderPageAsync(uint index, double scale = RenderScale)
    {
        if (Document is null) throw new InvalidOperationException("no document loaded");
        using var page = Document.GetPage(index);
        // Windows.Data.Pdf reports Size in DIPs (1/96"), NOT PDF points (1/72").
        // The PAdES /Rect lives in PDF user-space points, and CoordinateMapper works
        // in points, so convert DIPs -> points (×72/96) for the page's intrinsic size.
        // Skipping this scaled every placement by 96/72 (≈1.333) — boxes landed too big.
        var size = page.Size; // DIPs (1/96 inch)
        const double DipToPoint = 72.0 / 96.0;
        var pointW = size.Width * DipToPoint;
        var pointH = size.Height * DipToPoint;

        using var stream = new InMemoryRandomAccessStream();
        var pxW = (uint)Math.Round(size.Width * scale);
        var pxH = (uint)Math.Round(size.Height * scale);
        var options = new PdfPageRenderOptions { DestinationWidth = pxW, DestinationHeight = pxH };
        await page.RenderToStreamAsync(stream, options);
        stream.Seek(0);

        var bmp = new BitmapImage();
        await bmp.SetSourceAsync(stream);

        // Windows.Data.Pdf bakes /Rotate into the rendered bitmap, so the image is
        // upright and Size is the displayed size. The mapper therefore uses
        // rotation 0 against a cropBox of the displayed point size.
        return new RenderedPage(bmp, index, pointW, pointH, pxW, pxH);
    }

    public async Task<List<RenderedPage>> RenderAllAsync(double scale = RenderScale)
    {
        if (Document is null) return new();
        var pages = new List<RenderedPage>();
        for (uint i = 0; i < Document.PageCount; i++)
            pages.Add(await RenderPageAsync(i, scale));
        return pages;
    }
}

/// <summary>
/// A rendered page bound to the viewer. Holds the bitmap, the page's intrinsic size
/// in PDF points (for coordinate mapping), the rendered pixel size (the draw surface
/// size), and the user-drawn signature box in display pixels (if any).
/// </summary>
public sealed class RenderedPage : INotifyPropertyChanged
{
    public RenderedPage(BitmapImage image, uint index, double pointWidth, double pointHeight, uint pixelWidth, uint pixelHeight)
    {
        Image = image;
        Index = index;
        PointWidth = pointWidth;
        PointHeight = pointHeight;
        PixelWidth = pixelWidth;
        PixelHeight = pixelHeight;
    }

    public BitmapImage Image { get; }
    public uint Index { get; }
    public double PointWidth { get; }
    public double PointHeight { get; }
    public uint PixelWidth { get; }
    public uint PixelHeight { get; }

    // Fit-to-width display size (DIPs). The bitmap is rendered larger; the Image
    // scales uniformly to this size, and the draw surface adopts it too.
    private double _displayWidth, _displayHeight;
    public double DisplayWidth
    {
        get => _displayWidth;
        private set { _displayWidth = value; Raise(nameof(DisplayWidth)); RaiseBox(); }
    }
    public double DisplayHeight
    {
        get => _displayHeight;
        private set { _displayHeight = value; Raise(nameof(DisplayHeight)); RaiseBox(); }
    }

    /// <summary>Size the page to fill the given width, preserving aspect ratio.</summary>
    public void FitToWidth(double availableWidth)
    {
        if (availableWidth <= 0 || PointWidth <= 0) return;
        DisplayWidth = availableWidth;
        DisplayHeight = availableWidth * PointHeight / PointWidth;
    }

    // Drawn box stored as normalized fractions (0..1) of the displayed page, so it
    // sticks to the paper and rescales with the page when the window resizes (the
    // macOS shell gets this for free from PDFView; here we keep the page-relative
    // model explicitly). The on-screen BoxX/Y/W/H are derived from these fractions
    // against the current display size, so what's drawn always equals what's signed.
    private double _nx, _ny, _nw, _nh;
    private bool _hasBox;

    public bool HasBox
    {
        get => _hasBox;
        private set { _hasBox = value; Raise(nameof(HasBox)); Raise(nameof(BoxVisibility)); }
    }

    /// <summary>For XAML binding: Visible when a box exists, else Collapsed.</summary>
    public Visibility BoxVisibility => _hasBox ? Visibility.Visible : Visibility.Collapsed;

    // Display-space box (DIPs), derived from the normalized fractions on the fly.
    public double BoxX => _nx * _displayWidth;
    public double BoxY => _ny * _displayHeight;
    public double BoxW => _nw * _displayWidth;
    public double BoxH => _nh * _displayHeight;

    private void RaiseBox()
    {
        Raise(nameof(BoxX)); Raise(nameof(BoxY)); Raise(nameof(BoxW)); Raise(nameof(BoxH));
    }

    /// <summary>Set the drawn box from a rect in the draw surface's coordinate space,
    /// converting to page-relative fractions (0..1) immediately.</summary>
    public void SetBox(double x, double y, double w, double h, double surfaceW, double surfaceH)
    {
        if (surfaceW <= 0 || surfaceH <= 0) return;
        _nx = x / surfaceW; _ny = y / surfaceH;
        _nw = w / surfaceW; _nh = h / surfaceH;
        HasBox = true;
        RaiseBox();
    }

    public void ClearBox() => HasBox = false;

    /// <summary>
    /// Convert the drawn box into a PDF user-space placement via the shared
    /// CoordinateMapper -- the same tested math the macOS shell uses. The box is
    /// already normalized (0..1 of the displayed page), which is exactly the
    /// normalized space CoordinateMapper.UserSpaceRect consumes. Returns null if
    /// no box is drawn.
    /// </summary>
    public PlacementSpec? ToPlacement(IReadOnlyList<string> lines)
    {
        if (!_hasBox) return null;

        // Upright render => rotation 0, cropBox is the displayed point size.
        var mapper = new CoordinateMapper(new PdfRect(0, 0, PointWidth, PointHeight), 0);
        var user = mapper.UserSpaceRect(new PdfRect(_nx, _ny, _nw, _nh));

        return new PlacementSpec
        {
            Page = (int)Index,
            X = user.X, Y = user.Y, W = user.Width, H = user.Height,
            Lines = lines,
            Border = true,
            Background = true,
        };
    }

    public event PropertyChangedEventHandler? PropertyChanged;
    private void Raise(string n) => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(n));
}
