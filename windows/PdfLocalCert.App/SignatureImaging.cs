using QRCoder;
using Windows.Graphics.Imaging;
using Windows.Storage;
using Windows.Storage.Streams;

namespace PdfLocalCert.App;

/// <summary>A decoded RGBA8 bitmap (straight alpha, rows top-to-bottom) ready to
/// hand to the core as a placed appearance image.</summary>
public readonly record struct Rgba8(byte[] Bytes, int Width, int Height)
{
    public double Aspect => Height > 0 ? (double)Width / Height : 1;
}

/// <summary>Box-local sub-rectangle in PDF points (origin bottom-left).</summary>
public readonly record struct BoxRect(double X, double Y, double W, double H);

/// <summary>Where the text, logo and QR badge sit inside a signature box. Mirrors the
/// macOS SignatureComposer layout: logo flush-left, QR flush-right, text between.</summary>
public readonly record struct SigLayout(double TextX, double TextW, BoxRect? Logo, BoxRect? Qr);

/// <summary>
/// Logo decoding and QR generation for the visible-signature appearance (parity
/// phase 7.7). Produces straight-alpha RGBA8 the Rust core composites over white,
/// matching the macOS AppearanceRenderer output.
/// </summary>
public static class SignatureImaging
{
    /// <summary>Decode an image file to RGBA8, capping the longest side at <paramref name="maxPx"/>.</summary>
    public static async Task<Rgba8?> LoadLogoAsync(string path, int maxPx = 300)
    {
        try
        {
            var file = await StorageFile.GetFileFromPathAsync(path);
            using var stream = await file.OpenAsync(FileAccessMode.Read);
            var decoder = await BitmapDecoder.CreateAsync(stream);

            uint w = decoder.PixelWidth, h = decoder.PixelHeight;
            var transform = new BitmapTransform();
            double longest = Math.Max(w, h);
            if (longest > maxPx)
            {
                double s = maxPx / longest;
                transform.ScaledWidth = (uint)Math.Max(1, Math.Round(w * s));
                transform.ScaledHeight = (uint)Math.Max(1, Math.Round(h * s));
            }

            var pixels = await decoder.GetPixelDataAsync(
                BitmapPixelFormat.Rgba8, BitmapAlphaMode.Straight, transform,
                ExifOrientationMode.RespectExifOrientation, ColorManagementMode.DoNotColorManage);

            int rw = (int)(transform.ScaledWidth != 0 ? transform.ScaledWidth : w);
            int rh = (int)(transform.ScaledHeight != 0 ? transform.ScaledHeight : h);
            return new Rgba8(pixels.DetachPixelData(), rw, rh);
        }
        catch
        {
            return null; // unreadable/unsupported image -> skip the logo silently
        }
    }

    /// <summary>Render a QR code for <paramref name="payload"/> as opaque RGBA8 with a
    /// 4-module quiet zone. <paramref name="modulePx"/> pixels per module.</summary>
    public static Rgba8 Qr(string payload, int modulePx = 4)
    {
        using var generator = new QRCodeGenerator();
        using var data = generator.CreateQrCode(payload, QRCodeGenerator.ECCLevel.M);
        var matrix = data.ModuleMatrix;           // square; does NOT include a quiet zone
        const int quiet = 4;
        int modules = matrix.Count + quiet * 2;
        int side = modules * Math.Max(1, modulePx);

        var bytes = new byte[side * side * 4];
        for (int py = 0; py < side; py++)
        {
            int my = py / modulePx - quiet;        // matrix row (top-to-bottom)
            for (int px = 0; px < side; px++)
            {
                int mx = px / modulePx - quiet;
                bool dark = my >= 0 && my < matrix.Count && mx >= 0 && mx < matrix.Count && matrix[my][mx];
                int i = (py * side + px) * 4;
                byte v = dark ? (byte)0 : (byte)255;
                bytes[i] = v; bytes[i + 1] = v; bytes[i + 2] = v; bytes[i + 3] = 255;
            }
        }
        return new Rgba8(bytes, side, side);
    }

    /// <summary>Lay out text/logo/QR inside a box of <paramref name="w"/>×<paramref name="h"/> points.</summary>
    public static SigLayout Layout(double w, double h, double? logoAspect, bool hasQr)
    {
        const double inset = 2, gap = 4;
        double side = Math.Max(1, h - 2 * inset);
        double left = inset, right = w - inset;
        BoxRect? logo = null, qr = null;

        if (logoAspect is double a && a > 0)
        {
            // Fit the logo inside a `side`-tall, `w*0.4`-wide slot while preserving its
            // aspect ratio, then centre it vertically in the box (don't stretch to fill).
            double lh = side, lw = side * a;
            double maxW = w * 0.4;
            if (lw > maxW) { lw = maxW; lh = lw / a; }
            double ly = inset + (side - lh) / 2;
            logo = new BoxRect(left, ly, lw, lh);
            left += lw + gap;
        }
        if (hasQr)
        {
            qr = new BoxRect(right - side, inset, side, side);
            right -= side + gap;
        }
        double textX = left;
        double textW = Math.Max(0, right - left);
        return new SigLayout(textX, textW, logo, qr);
    }
}
