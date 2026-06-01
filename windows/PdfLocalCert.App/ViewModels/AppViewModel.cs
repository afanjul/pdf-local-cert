using System.Collections.ObjectModel;
using CommunityToolkit.Mvvm.ComponentModel;
using Microsoft.UI.Xaml;
using PdfLocalCert.Core;

namespace PdfLocalCert.App.ViewModels;

/// <summary>The three top-level sections, mirroring the macOS segmented nav.</summary>
public enum AppSection { Sign, Batch, Verify }

/// <summary>
/// Single source of truth for the WinUI shell, mirroring the macOS <c>AppModel</c>.
/// All views x:Bind to one instance so shell state stays consistent and the two
/// platforms cannot drift apart (the drift that hid the earlier placement bug).
///
/// Window-coupled IO (file pickers, ContentDialogs, signing) stays in code-behind
/// where the HWND / XamlRoot live; this type owns the observable *state* they read
/// and write. Subsequent parity phases (7.1+) progressively move flows onto it.
/// </summary>
public sealed partial class AppViewModel : ObservableObject
{
    public AppViewModel()
    {
        License = new LicenseManager();
    }

    // ── Section navigation ───────────────────────────────────────────────────

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(SignVisibility))]
    [NotifyPropertyChangedFor(nameof(BatchVisibility))]
    [NotifyPropertyChangedFor(nameof(VerifyVisibility))]
    private AppSection _currentSection = AppSection.Sign;

    public Visibility SignVisibility => Vis(AppSection.Sign);
    public Visibility BatchVisibility => Vis(AppSection.Batch);
    public Visibility VerifyVisibility => Vis(AppSection.Verify);
    private Visibility Vis(AppSection s) => CurrentSection == s ? Visibility.Visible : Visibility.Collapsed;

    // ── Document ─────────────────────────────────────────────────────────────

    /// <summary>Rendered pages of the open document (drives the page viewer).</summary>
    public ObservableCollection<RenderedPage> Pages { get; } = new();

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(HasDocument))]
    [NotifyPropertyChangedFor(nameof(DropZoneVisibility))]
    [NotifyPropertyChangedFor(nameof(PageViewerVisibility))]
    private string? _filePath;

    public bool HasDocument => !string.IsNullOrEmpty(FilePath);
    public Visibility DropZoneVisibility => HasDocument ? Visibility.Collapsed : Visibility.Visible;
    public Visibility PageViewerVisibility => HasDocument ? Visibility.Visible : Visibility.Collapsed;

    // ── Certificates ─────────────────────────────────────────────────────────

    public ObservableCollection<CertificateInfo> Identities { get; } = new();

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(CertDetailText))]
    [NotifyPropertyChangedFor(nameof(CanSign))]
    private CertificateInfo? _selectedCert;

    public string CertDetailText
    {
        get
        {
            if (SelectedCert is not { } c) return "No certificate selected.";
            var notes = new List<string> { $"Issuer: {c.Issuer}", c.KeyAlgorithm, $"expires {c.NotAfter:yyyy-MM-dd}" };
            if (c.IsExpired) notes.Add("EXPIRED");
            if (!c.CanSign) notes.Add("key usage does not allow signing");
            return string.Join("  ·  ", notes);
        }
    }

    /// <summary>True when a usable identity and a document are both present.</summary>
    public bool CanSign => HasDocument && SelectedCert is { CanSign: true, IsExpired: false } && !IsSigning;

    // ── Signing options ──────────────────────────────────────────────────────

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(SignAllVisibility))]
    private bool _visibleSignature;

    [ObservableProperty] private bool _signAllPages;

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(TsaVisibility))]
    private bool _useTimestamp;

    [ObservableProperty] private string _reason = "";
    [ObservableProperty] private string _location = "";

    /// <summary>"Sign all pages" only applies to a visible (placed) signature.</summary>
    public Visibility SignAllVisibility => VisibleSignature ? Visibility.Visible : Visibility.Collapsed;
    public Visibility TsaVisibility => UseTimestamp ? Visibility.Visible : Visibility.Collapsed;

    /// <summary>
    /// Qualified Spanish/EU TSA (ACCV, on the EU Trusted List) so timestamped
    /// signatures validate in VALIDe — matches the macOS default. DigiCert's TSA
    /// is not a qualified EU TSA.
    /// </summary>
    [ObservableProperty] private string _tsaUrl = "http://tss.accv.es:8318/tsa";

    // ── Status ───────────────────────────────────────────────────────────────

    [ObservableProperty] private string _statusText = "Open a PDF to begin.";

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(CanSign))]
    private bool _isSigning;

    // ── Licensing ────────────────────────────────────────────────────────────

    public LicenseManager License { get; }

    [ObservableProperty] private bool _showPaywall;

    // ── Helpers ──────────────────────────────────────────────────────────────

    /// <summary>Pick a sensible default identity (first valid, else first).</summary>
    public void SelectDefaultIdentity()
    {
        SelectedCert = Identities.FirstOrDefault(c => !c.IsExpired && c.CanSign)
                       ?? Identities.FirstOrDefault();
    }

    /// <summary>Clear the open document and return to the drop zone (keeps options).</summary>
    public void ClearDocument()
    {
        Pages.Clear();
        FilePath = null;
        StatusText = "Open a PDF to begin.";
    }
}
