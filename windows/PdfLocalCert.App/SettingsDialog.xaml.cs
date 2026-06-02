using Microsoft.UI.Xaml.Controls;
using Windows.Storage;

namespace PdfLocalCert.App;

/// <summary>
/// Settings + license/paywall surface. Shows the current tier, activates/deactivates
/// a Pro license (via DPAPI-backed LicenseManager), edits the signed-file suffix
/// (ApplicationData.LocalSettings), and an About blurb. When opened as a paywall
/// (paywallReason set) it leads with a warning banner.
/// </summary>
public sealed partial class SettingsDialog : ContentDialog
{
    private readonly LicenseManager _license;

    public const string SuffixSetting = "settings.signedSuffix";
    public const string DefaultSuffix = "-firmado";

    /// <summary>Effective suffix for callers without a dialog instance.</summary>
    public static string CurrentSuffix =>
        ApplicationData.Current.LocalSettings.Values[SuffixSetting] as string ?? DefaultSuffix;

    public SettingsDialog(LicenseManager license, string? paywallReason = null)
    {
        _license = license;
        InitializeComponent();
        Closed += OnClosed;

        if (paywallReason is not null)
        {
            PaywallBar.IsOpen = true;
            PaywallBar.Title = "Upgrade to Pro";
            PaywallBar.Message = $"{paywallReason} Enter a license key below to unlock unlimited signatures.";
        }

        ThemeBox.SelectedIndex = (int)AppSettings.Theme;
        LanguageBox.SelectedIndex = (int)AppSettings.Language;
        _ready = true;   // ignore the SelectionChanged fired while populating above

        SuffixBox.Text = CurrentSuffix;
        AboutText.Text = "Local PDF signing. Your private key never leaves the Windows certificate store.";
        RefreshTier();
    }

    /// <summary>Guards the SelectionChanged handlers against the initial population.</summary>
    private bool _ready;

    private void OnThemeChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!_ready) return;
        AppSettings.Theme = (AppTheme)ThemeBox.SelectedIndex;
        // Apply live to the window root behind the dialog.
        if (XamlRoot?.Content is Microsoft.UI.Xaml.FrameworkElement root)
            root.RequestedTheme = AppSettings.ElementTheme;
    }

    private void OnLanguageChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!_ready) return;
        AppSettings.Language = (AppLanguage)LanguageBox.SelectedIndex;
        AppSettings.ApplyLanguage();   // full effect next launch
    }

    private void RefreshTier()
    {
        if (_license.IsPro)
        {
            TierText.Text = "Pro — unlimited signatures.";
            ActivatePanel.Visibility = Microsoft.UI.Xaml.Visibility.Collapsed;
            DeactivateButton.Visibility = Microsoft.UI.Xaml.Visibility.Visible;
        }
        else
        {
            TierText.Text = $"Free — {_license.RemainingFreeSigns} of {LicenseManager.FreeMonthlyLimit} signatures left this month.";
            ActivatePanel.Visibility = Microsoft.UI.Xaml.Visibility.Visible;
            DeactivateButton.Visibility = Microsoft.UI.Xaml.Visibility.Collapsed;
        }
    }

    private void OnActivate(object sender, Microsoft.UI.Xaml.RoutedEventArgs e)
    {
        var key = LicenseBox.Text.Trim();
        if (_license.Activate(key))
        {
            ActivateError.Visibility = Microsoft.UI.Xaml.Visibility.Collapsed;
            PaywallBar.IsOpen = false;
            RefreshTier();
        }
        else
        {
            ActivateError.Text = "Invalid key";
            ActivateError.Visibility = Microsoft.UI.Xaml.Visibility.Visible;
        }
    }

    private void OnDeactivate(object sender, Microsoft.UI.Xaml.RoutedEventArgs e)
    {
        _license.Deactivate();
        RefreshTier();
    }

    private void OnClosed(ContentDialog sender, ContentDialogClosedEventArgs args)
    {
        // Persist the suffix on close (empty falls back to default at read time).
        ApplicationData.Current.LocalSettings.Values[SuffixSetting] = SuffixBox.Text.Trim();
    }
}
