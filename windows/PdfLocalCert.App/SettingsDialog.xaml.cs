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

        SuffixBox.Text = CurrentSuffix;
        AboutText.Text = "Local PDF signing. Your private key never leaves the Windows certificate store.";
        RefreshTier();
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
