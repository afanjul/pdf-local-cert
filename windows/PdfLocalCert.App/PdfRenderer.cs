using Microsoft.UI.Xaml.Media.Imaging;
using Windows.Data.Pdf;
using Windows.Storage;
using Windows.Storage.Streams;

namespace PdfLocalCert.App;

/// <summary>
/// Renders PDF pages to bitmaps via Windows.Data.Pdf — the Windows equivalent of
/// PDFKit's PDFView. One rendered page = one <see cref="RenderedPage"/> (image +
/// the page's true point size, needed by the placement overlay → CoordinateMapper).
/// </summary>
public sealed class PdfRenderer
{
    public PdfDocument? Document { get; private set; }
    public string? FilePath { get; private set; }

    /// <summary>A rendered page: the bitmap to show plus the page's intrinsic
    /// size in PDF points (Size.Width/Height) and /Rotate, for coordinate mapping.</summary>
    public sealed record RenderedPage(BitmapImage Image, uint Index, double PointWidth, double PointHeight, int Rotation);

    public async Task<bool> LoadAsync(string path)
    {
        var file = await StorageFile.GetFileFromPathAsync(path);
        Document = await PdfDocument.LoadFromFileAsync(file);
        FilePath = path;
        return Document.PageCount > 0;
    }

    /// <summary>Render one page at <paramref name="scale"/>× its native size.</summary>
    public async Task<RenderedPage> RenderPageAsync(uint index, double scale = 1.5)
    {
        if (Document is null) throw new InvalidOperationException("no document loaded");
        using var page = Document.GetPage(index);
        var size = page.Size; // points (1/72")

        using var stream = new InMemoryRandomAccessStream();
        var options = new PdfPageRenderOptions
        {
            DestinationWidth = (uint)Math.Round(size.Width * scale),
            DestinationHeight = (uint)Math.Round(size.Height * scale),
        };
        await page.RenderToStreamAsync(stream, options);
        stream.Seek(0);

        var bmp = new BitmapImage();
        await bmp.SetSourceAsync(stream);

        // Windows.Data.Pdf already applies /Rotate when rendering, so the bitmap is
        // upright; Size is the displayed size. Rotation is reported as 0 to the
        // mapper because the rendered bitmap is post-rotation (displayed) space.
        return new RenderedPage(bmp, index, size.Width, size.Height, 0);
    }

    public async Task<List<RenderedPage>> RenderAllAsync(double scale = 1.5)
    {
        if (Document is null) return new();
        var pages = new List<RenderedPage>();
        for (uint i = 0; i < Document.PageCount; i++)
            pages.Add(await RenderPageAsync(i, scale));
        return pages;
    }
}
