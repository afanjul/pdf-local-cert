using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using PdfLocalCert.Core;

namespace PdfLocalCert.App;

public sealed partial class SignDialog : ContentDialog
{
    private readonly List<CertificateInfo> _identities;

    public CertificateInfo? SelectedCert { get; private set; }
    public string? Reason => string.IsNullOrWhiteSpace(ReasonBox.Text) ? null : ReasonBox.Text.Trim();
    public string? Location => string.IsNullOrWhiteSpace(LocationBox.Text) ? null : LocationBox.Text.Trim();
    public string? TsaUrl => TimestampToggle.IsOn && !string.IsNullOrWhiteSpace(TsaBox.Text) ? TsaBox.Text.Trim() : null;

    public SignDialog(List<CertificateInfo> identities)
    {
        InitializeComponent();
        _identities = identities;

        foreach (var c in _identities)
        {
            CertCombo.Items.Add(new ComboBoxItem
            {
                Content = c.IsExpired ? $"{c.CommonName}  (expired)" : c.CommonName,
                Tag = c,
                IsEnabled = c.CanSign && !c.IsExpired,
            });
        }

        // Select the first usable identity by default.
        var firstUsable = _identities.FindIndex(c => c.CanSign && !c.IsExpired);
        CertCombo.SelectedIndex = firstUsable >= 0 ? firstUsable : (_identities.Count > 0 ? 0 : -1);
        IsPrimaryButtonEnabled = SelectedCert is { CanSign: true, IsExpired: false };
    }

    private void OnCertChanged(object sender, SelectionChangedEventArgs e)
    {
        SelectedCert = (CertCombo.SelectedItem as ComboBoxItem)?.Tag as CertificateInfo;
        if (SelectedCert is { } c)
        {
            var notes = new List<string> { $"Issuer: {c.Issuer}", c.KeyAlgorithm, $"expires {c.NotAfter:yyyy-MM-dd}" };
            if (c.IsExpired) notes.Add("EXPIRED");
            if (!c.CanSign) notes.Add("key usage does not allow signing");
            CertDetail.Text = string.Join("  ·  ", notes);
            IsPrimaryButtonEnabled = c.CanSign && !c.IsExpired;
        }
        else
        {
            CertDetail.Text = "";
            IsPrimaryButtonEnabled = false;
        }
    }

    private void OnTimestampToggled(object sender, RoutedEventArgs e)
        => TsaBox.IsEnabled = TimestampToggle.IsOn;
}
