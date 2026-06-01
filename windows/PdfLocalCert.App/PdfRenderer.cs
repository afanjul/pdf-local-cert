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

    /// <summary>Render one page at RenderScale times its native size.</summary>
    public async Task<RenderedPage> RenderPageAsync(uint index, double scale = RenderScale)
    {
        if (Document is null) throw new InvalidOperationException("no document loaded");
        using var page = Document.GetPage(index);
        var size = page.Size; // points (1/72 inch)

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
        return new RenderedPage(bmp, index, size.Width, size.Height, pxW, pxH);
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
    public double DisplayWidth { get => _displayWidth; private set { _displayWidth = value; Raise(nameof(DisplayWidth)); } }
    public double DisplayHeight { get => _displayHeight; private set { _displayHeight = value; Raise(nameof(DisplayHeight)); } }

    /// <summary>Size the page to fill the given width, preserving aspect ratio.</summary>
    public void FitToWidth(double availableWidth)
    {
        if (availableWidth <= 0 || PointWidth <= 0) return;
        DisplayWidth = availableWidth;
        DisplayHeight = availableWidth * PointHeight / PointWidth;
    }

    // Drawn box in display pixels (same space as the rendered bitmap).
    private double _boxX, _boxY, _boxW, _boxH;
    private double _surfaceW, _surfaceH;
    private bool _hasBox;

    public bool HasBox
    {
        get => _hasBox;
        private set { _hasBox = value; Raise(nameof(HasBox)); Raise(nameof(BoxVisibility)); }
    }

    /// <summary>For XAML binding: Visible when a box exists, else Collapsed.</summary>
    public Visibility BoxVisibility => _hasBox ? Visibility.Visible : Visibility.Collapsed;

    public double BoxX { get => _boxX; private set { _boxX = value; Raise(nameof(BoxX)); } }
    public double BoxY { get => _boxY; private set { _boxY = value; Raise(nameof(BoxY)); } }
    public double BoxW { get => _boxW; private set { _boxW = value; Raise(nameof(BoxW)); } }
    public double BoxH { get => _boxH; private set { _boxH = value; Raise(nameof(BoxH)); } }

    // Draw-surface size the box was captured against (TEMP, for placement diagnostics).
    public double SurfaceW => _surfaceW;
    public double SurfaceH => _surfaceH;

    /// <summary>Set the drawn box and the size of the draw surface it was drawn on
    /// (both in the same on-screen coordinate space).</summary>
    public void SetBox(double x, double y, double w, double h, double surfaceW, double surfaceH)
    {
        BoxX = x; BoxY = y; BoxW = w; BoxH = h;
        _surfaceW = surfaceW; _surfaceH = surfaceH;
        HasBox = true;
    }

    public void ClearBox() => HasBox = false;

    /// <summary>
    /// Convert the drawn box into a PDF user-space placement via the shared
    /// CoordinateMapper -- the same tested math the macOS shell uses. Returns null
    /// if no box is drawn.
    /// </summary>
    public PlacementSpec? ToPlacement(IReadOnlyList<string> lines)
    {
        if (!_hasBox || _surfaceW <= 0 || _surfaceH <= 0) return null;

        // Upright render => rotation 0, cropBox is the displayed point size.
        var mapper = new CoordinateMapper(new PdfRect(0, 0, PointWidth, PointHeight), 0);
        var surface = new PdfRect(0, 0, _surfaceW, _surfaceH);
        var viewRect = new PdfRect(_boxX, _boxY, _boxW, _boxH);
        var normalized = mapper.Normalize(viewRect, surface);
        var user = mapper.UserSpaceRect(normalized);

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
