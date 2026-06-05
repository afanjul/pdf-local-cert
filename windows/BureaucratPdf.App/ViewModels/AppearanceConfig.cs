using System.Text.Json;
using Windows.Storage;

namespace BureaucratPdf.App.ViewModels;

/// <summary>
/// Serializable snapshot of the visible-signature appearance, mirroring the macOS
/// <c>AppearanceConfig</c>. The live editor lives as observable properties on
/// <see cref="AppViewModel"/>; this DTO is what presets capture and restore.
/// </summary>
public sealed class AppearanceConfig
{
    public bool ShowName { get; set; } = true;
    public bool ShowLabel { get; set; }
    public string CustomLabel { get; set; } = "Firmado por:";
    public bool ShowDate { get; set; } = true;
    public bool ShowReason { get; set; }
    public bool ShowLocation { get; set; }
    public bool ShowBorder { get; set; }
    /// <summary>Transparent box (let the page show) vs. opaque white card.</summary>
    public bool TransparentBackground { get; set; }
    public bool WrapText { get; set; }
    public double FontSize { get; set; } = 9;
    /// <summary>Path to a logo/handwriting image placed left of the text, or null.</summary>
    public string? LogoPath { get; set; }
    /// <summary>Show a QR verification badge on the right of the box.</summary>
    public bool ShowQr { get; set; }
}

/// <summary>A named, saved appearance (mirrors macOS AppearancePreset).</summary>
public sealed class AppearancePreset
{
    public string Name { get; set; } = "";
    public AppearanceConfig Config { get; set; } = new();

    public override string ToString() => Name; // ComboBox display
}

/// <summary>Persists appearance presets to ApplicationData.LocalSettings as JSON
/// (mirrors macOS PresetStore, which uses UserDefaults).</summary>
public static class PresetStore
{
    private const string Key = "appearance.presets";

    public static List<AppearancePreset> Load()
    {
        if (ApplicationData.Current.LocalSettings.Values[Key] is not string json) return new();
        try { return JsonSerializer.Deserialize<List<AppearancePreset>>(json) ?? new(); }
        catch { return new(); }
    }

    public static void Save(IEnumerable<AppearancePreset> presets)
    {
        ApplicationData.Current.LocalSettings.Values[Key] = JsonSerializer.Serialize(presets);
    }
}
