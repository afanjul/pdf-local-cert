using System.Collections.ObjectModel;
using CommunityToolkit.Mvvm.ComponentModel;
using Microsoft.UI.Xaml;
using BureaucratPdf.Core;

namespace BureaucratPdf.App.ViewModels;

public enum VerifyState { Verifying, Done, Failed }

/// <summary>One file in the multi-file verify queue (mirrors macOS VerifyItemB).</summary>
public sealed partial class VerifyItem : ObservableObject
{
    public VerifyItem(string path) => Path = path;

    public string Path { get; }
    public string FileName => System.IO.Path.GetFileName(Path);

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(Glyph))]
    [NotifyPropertyChangedFor(nameof(GlyphBrush))]
    [NotifyPropertyChangedFor(nameof(LevelText))]
    [NotifyPropertyChangedFor(nameof(IsInvalid))]
    [NotifyPropertyChangedFor(nameof(Verifying))]
    private VerifyState _state = VerifyState.Verifying;

    [ObservableProperty] private string _error = "";

    public ObservableCollection<VerificationResult> Results { get; } = new();

    public bool Verifying => State == VerifyState.Verifying;

    public bool IsInvalid => State switch
    {
        VerifyState.Failed => true,
        VerifyState.Done => Results.Any(r => !r.Valid),
        _ => false,
    };

    public string LevelText => State switch
    {
        VerifyState.Verifying => "…",
        VerifyState.Failed => "—",
        _ => Results.Count > 0 ? Results[0].Level : "—",
    };

    /// <summary>checkmark-seal (valid), cancel-seal (invalid/failed), sync (verifying).</summary>
    public string Glyph => char.ConvertFromUtf32(State switch
    {
        VerifyState.Verifying => 0xE895,
        VerifyState.Done when !IsInvalid => 0xE73E,
        _ => 0xE711,
    });

    public Microsoft.UI.Xaml.Media.Brush GlyphBrush => new Microsoft.UI.Xaml.Media.SolidColorBrush(
        State switch
        {
            VerifyState.Done when !IsInvalid => Microsoft.UI.Colors.SeaGreen,
            VerifyState.Verifying => Microsoft.UI.Colors.Gray,
            _ => Microsoft.UI.Colors.IndianRed,
        });

    public Visibility ErrorVisibility => State == VerifyState.Failed ? Visibility.Visible : Visibility.Collapsed;
}
