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
    [NotifyPropertyChangedFor(nameof(CanSign))]
    private string? _filePath;

    public bool HasDocument => !string.IsNullOrEmpty(FilePath);
    public Visibility DropZoneVisibility => HasDocument ? Visibility.Collapsed : Visibility.Visible;
    public Visibility PageViewerVisibility => HasDocument ? Visibility.Visible : Visibility.Collapsed;

    // ── Certificates ─────────────────────────────────────────────────────────

    public ObservableCollection<CertificateInfo> Identities { get; } = new();

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(CertDetailText))]
    [NotifyPropertyChangedFor(nameof(CanSign))]
    [NotifyPropertyChangedFor(nameof(PreviewLines))]
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
    [NotifyPropertyChangedFor(nameof(AppearanceVisibility))]
    private bool _visibleSignature;

    [ObservableProperty] private bool _signAllPages;

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(TsaVisibility))]
    private bool _useTimestamp;

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(PreviewLines))]
    private string _reason = "";

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(PreviewLines))]
    private string _location = "";

    /// <summary>"Sign all pages" + the appearance editor only apply to a visible signature.</summary>
    public Visibility SignAllVisibility => VisibleSignature ? Visibility.Visible : Visibility.Collapsed;
    public Visibility AppearanceVisibility => VisibleSignature ? Visibility.Visible : Visibility.Collapsed;
    public Visibility TsaVisibility => UseTimestamp ? Visibility.Visible : Visibility.Collapsed;

    // ── Visible-signature appearance (mirrors macOS AppearanceConfig) ─────────

    [ObservableProperty][NotifyPropertyChangedFor(nameof(PreviewLines))][NotifyPropertyChangedFor(nameof(LabelToggleVisibility))][NotifyPropertyChangedFor(nameof(CustomLabelVisibility))] private bool _showName = true;
    [ObservableProperty][NotifyPropertyChangedFor(nameof(PreviewLines))][NotifyPropertyChangedFor(nameof(CustomLabelVisibility))] private bool _showLabel;
    [ObservableProperty][NotifyPropertyChangedFor(nameof(PreviewLines))] private string _customLabel = "Firmado por:";
    [ObservableProperty][NotifyPropertyChangedFor(nameof(PreviewLines))] private bool _showDate = true;
    [ObservableProperty][NotifyPropertyChangedFor(nameof(PreviewLines))][NotifyPropertyChangedFor(nameof(ReasonFieldVisibility))] private bool _showReason;
    [ObservableProperty][NotifyPropertyChangedFor(nameof(PreviewLines))][NotifyPropertyChangedFor(nameof(LocationFieldVisibility))] private bool _showLocation;
    [ObservableProperty] private bool _showBorder;
    [ObservableProperty][NotifyPropertyChangedFor(nameof(PreviewBackgroundBrush))] private bool _transparentBackground;
    [ObservableProperty] private bool _wrapText;
    [ObservableProperty][NotifyPropertyChangedFor(nameof(PreviewFontSize))] private double _fontSize = 9;

    public Visibility LabelToggleVisibility => ShowName ? Visibility.Visible : Visibility.Collapsed;
    public Visibility CustomLabelVisibility => ShowName && ShowLabel ? Visibility.Visible : Visibility.Collapsed;
    public Visibility ReasonFieldVisibility => ShowReason ? Visibility.Visible : Visibility.Collapsed;
    public Visibility LocationFieldVisibility => ShowLocation ? Visibility.Visible : Visibility.Collapsed;

    // Live preview (XAML approximation of the embedded output; true bitmap parity
    // arrives with the shared SignatureComposer port in 7.7).
    public double PreviewFontSize => FontSize;
    public Microsoft.UI.Xaml.Media.Brush PreviewBackgroundBrush => TransparentBackground
        ? new Microsoft.UI.Xaml.Media.SolidColorBrush(Microsoft.UI.Colors.Transparent)
        : new Microsoft.UI.Xaml.Media.SolidColorBrush(Microsoft.UI.Colors.White);

    /// <summary>The text lines for the signature box, built from the appearance + data.</summary>
    public List<string> BuildLines(string signerName)
    {
        var lines = new List<string>();
        if (ShowName)
            lines.Add((ShowLabel && !string.IsNullOrWhiteSpace(CustomLabel) ? CustomLabel + " " : "") + signerName);
        if (ShowReason && !string.IsNullOrWhiteSpace(Reason)) lines.Add(Reason.Trim());
        if (ShowLocation && !string.IsNullOrWhiteSpace(Location)) lines.Add(Location.Trim());
        if (ShowDate) lines.Add(DateTime.Now.ToString("dd/MM/yyyy HH:mm"));
        return lines;
    }

    /// <summary>Preview lines using the selected signer (or a placeholder name).</summary>
    public List<string> PreviewLines => BuildLines(SelectedCert?.CommonName ?? "Nombre Apellidos");

    // ── Appearance presets (mirrors macOS PresetStore) ───────────────────────

    public ObservableCollection<AppearancePreset> Presets { get; } = new(PresetStore.Load());

    [ObservableProperty] private AppearancePreset? _selectedPreset;

    partial void OnSelectedPresetChanged(AppearancePreset? value)
    {
        if (value is not null) ApplyConfig(value.Config);
    }

    /// <summary>Snapshot the current appearance into a serializable config.</summary>
    public AppearanceConfig CaptureConfig() => new()
    {
        ShowName = ShowName, ShowLabel = ShowLabel, CustomLabel = CustomLabel,
        ShowDate = ShowDate, ShowReason = ShowReason, ShowLocation = ShowLocation,
        ShowBorder = ShowBorder, TransparentBackground = TransparentBackground,
        WrapText = WrapText, FontSize = FontSize,
    };

    /// <summary>Apply a saved config back onto the live editor.</summary>
    public void ApplyConfig(AppearanceConfig c)
    {
        ShowName = c.ShowName; ShowLabel = c.ShowLabel; CustomLabel = c.CustomLabel;
        ShowDate = c.ShowDate; ShowReason = c.ShowReason; ShowLocation = c.ShowLocation;
        ShowBorder = c.ShowBorder; TransparentBackground = c.TransparentBackground;
        WrapText = c.WrapText; FontSize = c.FontSize;
    }

    public void SavePreset(string name)
    {
        var trimmed = name.Trim();
        if (trimmed.Length == 0) return;
        var existing = Presets.FirstOrDefault(p => p.Name == trimmed);
        var cfg = CaptureConfig();
        if (existing is not null) existing.Config = cfg;
        else Presets.Add(new AppearancePreset { Name = trimmed, Config = cfg });
        PresetStore.Save(Presets);
    }

    public void DeleteSelectedPreset()
    {
        if (SelectedPreset is not { } p) return;
        Presets.Remove(p);
        SelectedPreset = null;
        PresetStore.Save(Presets);
    }

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

    public Visibility ProLockVisibility => License.IsPro ? Visibility.Collapsed : Visibility.Visible;

    // ── Batch (mirrors macOS Batch) ──────────────────────────────────────────

    public ObservableCollection<BatchItem> BatchItems { get; } = new();

    [ObservableProperty] private bool _batchRunning;

    public Visibility BatchEmptyVisibility => BatchItems.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
    public Visibility BatchListVisibility => BatchItems.Count == 0 ? Visibility.Collapsed : Visibility.Visible;

    public string BatchSummary
    {
        get
        {
            int done = BatchItems.Count(i => i.Status == BatchStatus.Done);
            int failed = BatchItems.Count(i => i.Status == BatchStatus.Failed);
            return $"{done} done · {failed} failed · {BatchItems.Count} total";
        }
    }

    /// <summary>Add PDF paths to the queue, de-duplicating by path.</summary>
    public void AddBatchFiles(IEnumerable<string> paths)
    {
        var existing = BatchItems.Select(i => i.Path).ToHashSet(StringComparer.OrdinalIgnoreCase);
        foreach (var p in paths)
        {
            if (p.EndsWith(".pdf", StringComparison.OrdinalIgnoreCase) && existing.Add(p))
                BatchItems.Add(new BatchItem(p));
        }
        RaiseBatchState();
    }

    public void ClearBatch()
    {
        BatchItems.Clear();
        RaiseBatchState();
    }

    /// <summary>Re-raise the batch-derived properties (call after items/status change).</summary>
    public void RaiseBatchState()
    {
        OnPropertyChanged(nameof(BatchSummary));
        OnPropertyChanged(nameof(BatchEmptyVisibility));
        OnPropertyChanged(nameof(BatchListVisibility));
    }

    // ── Verify queue (mirrors macOS VerifierViewB) ───────────────────────────

    public ObservableCollection<VerifyItem> VerifyItems { get; } = new();

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(VisibleVerifyItems))]
    [NotifyPropertyChangedFor(nameof(VerifySummary))]
    private bool _onlyInvalid;

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(VisibleVerifyItems))]
    private bool _newestFirst = true;

    public Visibility VerifyEmptyVisibility => VerifyItems.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
    public Visibility VerifyListVisibility => VerifyItems.Count == 0 ? Visibility.Collapsed : Visibility.Visible;

    /// <summary>Items after the only-invalid filter and newest-first ordering.</summary>
    public IEnumerable<VerifyItem> VisibleVerifyItems
    {
        get
        {
            IEnumerable<VerifyItem> f = OnlyInvalid ? VerifyItems.Where(i => i.IsInvalid) : VerifyItems;
            return NewestFirst ? f.Reverse() : f;
        }
    }

    public string VerifySummary
    {
        get
        {
            int pending = VerifyItems.Count(i => i.Verifying);
            if (pending > 0) return $"Verifying {VerifyItems.Count - pending} of {VerifyItems.Count}…";
            int invalid = VerifyItems.Count(i => i.IsInvalid);
            return invalid == 0 ? $"{VerifyItems.Count} verified" : $"{VerifyItems.Count} verified · {invalid} invalid";
        }
    }

    /// <summary>Add files to the verify queue (re-verifying any already present).</summary>
    public void AddVerifyFiles(IEnumerable<string> paths)
    {
        foreach (var p in paths.Where(p => p.EndsWith(".pdf", StringComparison.OrdinalIgnoreCase)))
        {
            var existing = VerifyItems.FirstOrDefault(i => string.Equals(i.Path, p, StringComparison.OrdinalIgnoreCase));
            var item = existing ?? new VerifyItem(p);
            if (existing is null) VerifyItems.Add(item);
            _ = VerifyOneAsync(item);
        }
        RaiseVerifyState();
    }

    public void ReverifyAll()
    {
        foreach (var item in VerifyItems) _ = VerifyOneAsync(item);
    }

    public void ClearVerify()
    {
        VerifyItems.Clear();
        RaiseVerifyState();
    }

    public void RemoveVerify(VerifyItem item)
    {
        VerifyItems.Remove(item);
        RaiseVerifyState();
    }

    private async Task VerifyOneAsync(VerifyItem item)
    {
        item.State = VerifyState.Verifying;
        item.Results.Clear();
        item.Error = "";
        RaiseVerifyState();
        try
        {
            var results = await Task.Run(() => new SigningService().Verify(item.Path));
            if (results.Count == 0)
            {
                item.State = VerifyState.Failed;
                item.Error = "No signatures.";
            }
            else
            {
                foreach (var r in results) item.Results.Add(r);
                item.State = VerifyState.Done;
            }
        }
        catch (SigningException ex) when (ex.Code == "NO_SIGNATURE")
        {
            item.State = VerifyState.Failed;
            item.Error = "No signatures.";
        }
        catch (Exception ex)
        {
            item.State = VerifyState.Failed;
            item.Error = ex.Message;
        }
        RaiseVerifyState();
    }

    public void RaiseVerifyState()
    {
        OnPropertyChanged(nameof(VerifySummary));
        OnPropertyChanged(nameof(VerifyEmptyVisibility));
        OnPropertyChanged(nameof(VerifyListVisibility));
        OnPropertyChanged(nameof(VisibleVerifyItems));
    }

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
