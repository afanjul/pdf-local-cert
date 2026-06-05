using CommunityToolkit.Mvvm.ComponentModel;

namespace PdfLocalCert.App.ViewModels;

public enum BatchStatus { Pending, Signing, Done, Failed }

/// <summary>One queued file in the batch signer (mirrors the macOS BatchItem).</summary>
public sealed partial class BatchItem : ObservableObject
{
    public BatchItem(string path) => Path = path;

    public string Path { get; }
    public string FileName => System.IO.Path.GetFileName(Path);

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(Glyph))]
    [NotifyPropertyChangedFor(nameof(GlyphBrush))]
    private BatchStatus _status = BatchStatus.Pending;

    [ObservableProperty] private string _message = "";

    /// <summary>Segoe Fluent icon glyph for the current status (by code point).</summary>
    public string Glyph => char.ConvertFromUtf32(Status switch
    {
        BatchStatus.Signing => 0xE895, // sync
        BatchStatus.Done => 0xE73E,    // checkmark
        BatchStatus.Failed => 0xE711,  // cancel
        _ => 0xECCB,                   // pending (ring)
    });

    public Microsoft.UI.Xaml.Media.Brush GlyphBrush => new Microsoft.UI.Xaml.Media.SolidColorBrush(
        Status switch
        {
            BatchStatus.Done => Microsoft.UI.Colors.SeaGreen,
            BatchStatus.Failed => Microsoft.UI.Colors.IndianRed,
            _ => Microsoft.UI.Colors.Gray,
        });
}
