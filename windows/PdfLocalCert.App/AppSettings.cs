using Microsoft.UI.Xaml;
using Windows.Globalization;
using Windows.Storage;

namespace PdfLocalCert.App;

/// <summary>App-wide theme preference (mirrors macOS AppTheme).</summary>
public enum AppTheme { System, Light, Dark }

/// <summary>App language preference; <see cref="System"/> follows the OS (mirrors macOS AppLanguage).</summary>
public enum AppLanguage { System, Es, En }

/// <summary>
/// Persisted user preferences (theme, language) backed by ApplicationData.LocalSettings,
/// porting the macOS AppSettings. Theme applies live to the window root; a language
/// change sets PrimaryLanguageOverride and takes full effect on next launch (matching
/// the macOS "restart to apply" behaviour).
/// </summary>
public static class AppSettings
{
    private const string ThemeKey = "settings.theme";
    private const string LanguageKey = "settings.language";

    private static ApplicationDataContainer Local => ApplicationData.Current.LocalSettings;

    public static AppTheme Theme
    {
        get => Local.Values[ThemeKey] is string s && Enum.TryParse<AppTheme>(s, out var t) ? t : AppTheme.System;
        set => Local.Values[ThemeKey] = value.ToString();
    }

    public static AppLanguage Language
    {
        get => Local.Values[LanguageKey] is string s && Enum.TryParse<AppLanguage>(s, out var l) ? l : AppLanguage.System;
        set => Local.Values[LanguageKey] = value.ToString();
    }

    /// <summary>Map the theme preference to the WinUI element theme.</summary>
    public static ElementTheme ElementTheme => Theme switch
    {
        AppTheme.Light => Microsoft.UI.Xaml.ElementTheme.Light,
        AppTheme.Dark => Microsoft.UI.Xaml.ElementTheme.Dark,
        _ => Microsoft.UI.Xaml.ElementTheme.Default,
    };

    /// <summary>BCP-47 override for the language, or null to follow the OS.</summary>
    public static string? LanguageOverride => Language switch
    {
        AppLanguage.Es => "es",
        AppLanguage.En => "en",
        _ => null,
    };

    /// <summary>Apply the chosen theme to a window's root element (live).</summary>
    public static void ApplyTheme(Window window)
    {
        if (window.Content is FrameworkElement root) root.RequestedTheme = ElementTheme;
    }

    /// <summary>Push the language into PrimaryLanguageOverride (full effect next launch).</summary>
    public static void ApplyLanguage() =>
        ApplicationLanguages.PrimaryLanguageOverride = LanguageOverride ?? string.Empty;
}
