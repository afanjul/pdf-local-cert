using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using System.Linq;
using PdfLocalCert.App.ViewModels;
using PdfLocalCert.Core;
using Windows.Foundation;
using Windows.Storage.Pickers;
using WinRT.Interop;

namespace PdfLocalCert.App;

public sealed partial class MainWindow : Window
{
    private readonly PdfRenderer _renderer = new();

    /// <summary>Single source of truth for shell state (mirrors macOS AppModel).</summary>
    public AppViewModel ViewModel { get; }

    // Signature-box drag state.
    private bool _drawing;
    private Point _drawStart;
    private Canvas? _activeCanvas;
    private RenderedPage? _activePage;
    private const double MinBoxPx = 24;

    public MainWindow()
    {
        ViewModel = new AppViewModel();   // must exist before x:Bind runs
        InitializeComponent();
        RootGrid.DataContext = ViewModel; // let in-page {Binding ElementName=RootGrid} reach the VM
        AppSettings.ApplyTheme(this);     // honour the persisted theme on launch
        VersionText.Text = $"v{AppVersion}";
        LoadIdentities();
    }

    /// <summary>Populate the certificate picker from the Windows store (mirrors the
    /// macOS AppModel.loadIdentities; window-coupled so it lives here, not the VM).</summary>
    private void LoadIdentities()
    {
        try
        {
            // Preserve the current pick across a refresh (e.g. a cert added while the
            // app is open) so re-enumerating doesn't reset the user's selection.
            var keep = ViewModel.SelectedCert?.Thumbprint;
            ViewModel.Identities.Clear();
            foreach (var c in IdentityStore.LoadSigningIdentities()) ViewModel.Identities.Add(c);
            var still = keep is null ? null
                : ViewModel.Identities.FirstOrDefault(c => c.Thumbprint == keep);
            if (still is not null) ViewModel.SelectedCert = still;
            else ViewModel.SelectDefaultIdentity();
        }
        catch (Exception ex)
        {
            ViewModel.StatusText = $"Could not read the certificate store: {ex.Message}";
        }
    }

    /// <summary>Re-enumerate the cert store each time the picker opens, so a certificate
    /// added while the app is running shows up without a restart.</summary>
    private void OnCertDropDownOpened(object sender, object e) => LoadIdentities();

    /// <summary>App version from the MSIX package identity (matches the installed build).</summary>
    private static string AppVersion
    {
        get
        {
            var v = Windows.ApplicationModel.Package.Current.Id.Version;
            return $"{v.Major}.{v.Minor}.{v.Build}.{v.Revision}";
        }
    }

    /// <summary>SelectorBar → view model section (Sign / Batch / Verify).</summary>
    private void OnSectionChanged(SelectorBar sender, SelectorBarSelectionChangedEventArgs e)
    {
        ViewModel.CurrentSection = sender.SelectedItem == BatchSectionItem ? AppSection.Batch
            : sender.SelectedItem == VerifySectionItem ? AppSection.Verify
            : AppSection.Sign;
    }

    /// <summary>Close the current document and return to the empty state.</summary>
    private void OnNewClicked(object sender, RoutedEventArgs e)
    {
        _renderer.Reset();
        PagesItems.ItemsSource = null;
        ViewModel.ClearDocument();
        ViewModel.VisibleSignature = false;
        NewButton.IsEnabled = false;
    }

    // ── Drag-and-drop a PDF onto the page area ───────────────────────────────

    private void OnViewerDragOver(object sender, DragEventArgs e)
    {
        if (e.DataView.Contains(Windows.ApplicationModel.DataTransfer.StandardDataFormats.StorageItems))
        {
            e.AcceptedOperation = Windows.ApplicationModel.DataTransfer.DataPackageOperation.Copy;
            e.DragUIOverride.Caption = "Open PDF";
        }
    }

    private async void OnViewerDrop(object sender, DragEventArgs e)
    {
        if (!e.DataView.Contains(Windows.ApplicationModel.DataTransfer.StandardDataFormats.StorageItems)) return;
        var items = await e.DataView.GetStorageItemsAsync();
        var pdf = items.OfType<Windows.Storage.StorageFile>()
                       .FirstOrDefault(f => f.FileType.Equals(".pdf", StringComparison.OrdinalIgnoreCase));
        if (pdf is not null) await LoadAsync(pdf.Path);
    }

    // ── Zoom (1–4×) ──────────────────────────────────────────────────────────

    private void OnZoomIn(object sender, RoutedEventArgs e) => Zoom(0.25f);
    private void OnZoomOut(object sender, RoutedEventArgs e) => Zoom(-0.25f);
    private void OnZoomReset(object sender, RoutedEventArgs e)
        => PageScroller.ChangeView(null, null, 1f);

    private void Zoom(float delta)
    {
        var z = Math.Clamp(PageScroller.ZoomFactor + delta, PageScroller.MinZoomFactor, PageScroller.MaxZoomFactor);
        PageScroller.ChangeView(null, null, z);
    }

    // ── Appearance presets ───────────────────────────────────────────────────

    private async void OnSavePreset(object sender, RoutedEventArgs e)
    {
        var input = new TextBox { PlaceholderText = "Preset name", Text = ViewModel.SelectedPreset?.Name ?? "" };
        var dlg = new ContentDialog
        {
            Title = "Save appearance preset",
            Content = input,
            PrimaryButtonText = "Save",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary,
            XamlRoot = Content.XamlRoot,
        };
        if (await dlg.ShowAsync() == ContentDialogResult.Primary && !string.IsNullOrWhiteSpace(input.Text))
            ViewModel.SavePreset(input.Text);
    }

    private void OnDeletePreset(object sender, RoutedEventArgs e) => ViewModel.DeleteSelectedPreset();

    // ── Logo (parity phase 7.7) ──────────────────────────────────────────────

    private async void OnChooseLogo(object sender, RoutedEventArgs e)
    {
        var picker = new FileOpenPicker { SuggestedStartLocation = PickerLocationId.PicturesLibrary };
        foreach (var ext in new[] { ".png", ".jpg", ".jpeg", ".bmp", ".gif" }) picker.FileTypeFilter.Add(ext);
        InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(this));
        var file = await picker.PickSingleFileAsync();
        if (file is null) return;
        ViewModel.LogoPath = file.Path;

        // Decode for the sidebar preview off the picker-granted StorageFile stream.
        try
        {
            var bmp = new Microsoft.UI.Xaml.Media.Imaging.BitmapImage();
            using var stream = await file.OpenAsync(Windows.Storage.FileAccessMode.Read);
            await bmp.SetSourceAsync(stream);
            ViewModel.LogoImageSource = bmp;
        }
        catch { ViewModel.LogoImageSource = null; }
    }

    private void OnClearLogo(object sender, RoutedEventArgs e)
    {
        ViewModel.LogoPath = null;
        ViewModel.LogoImageSource = null;
    }

    // ── Batch ────────────────────────────────────────────────────────────────

    private async void OnBatchAdd(object sender, RoutedEventArgs e)
    {
        var picker = new FileOpenPicker { SuggestedStartLocation = PickerLocationId.DocumentsLibrary };
        picker.FileTypeFilter.Add(".pdf");
        InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(this));
        var files = await picker.PickMultipleFilesAsync();
        if (files is { Count: > 0 }) ViewModel.AddBatchFiles(files.Select(f => f.Path));
    }

    private void OnBatchClear(object sender, RoutedEventArgs e) => ViewModel.ClearBatch();

    private async void OnBatchDrop(object sender, DragEventArgs e)
    {
        if (!e.DataView.Contains(Windows.ApplicationModel.DataTransfer.StandardDataFormats.StorageItems)) return;
        var items = await e.DataView.GetStorageItemsAsync();
        ViewModel.AddBatchFiles(items.OfType<Windows.Storage.StorageFile>().Select(f => f.Path));
    }

    private async void OnBatchSignAll(object sender, RoutedEventArgs e)
    {
        if (ViewModel.BatchRunning) return;
        if (ViewModel.SelectedCert is not { CanSign: true, IsExpired: false } cert)
        {
            await ShowDialog("Batch", "Select a valid signing certificate in the Sign tab first.");
            return;
        }
        // Batch is a Pro feature (mirrors macOS).
        if (!ViewModel.License.IsPro)
        {
            await ShowPaywall("Batch signing is a Pro feature.");
            return;
        }

        ViewModel.BatchRunning = true;
        try
        {
            foreach (var item in ViewModel.BatchItems)
            {
                if (item.Status != BatchStatus.Pending) continue;
                item.Status = BatchStatus.Signing;
                ViewModel.RaiseBatchState();
                try
                {
                    var placements = new List<PlacementSpec>();
                    if (ViewModel.VisibleSignature)
                    {
                        var p = await DefaultPlacementAsync(item.Path, cert.CommonName);
                        if (p is not null) placements.Add(p);
                    }
                    var req = new SignRequest
                    {
                        PdfPath = item.Path,
                        Cert = cert,
                        Placements = placements,
                        Reason = string.IsNullOrWhiteSpace(ViewModel.Reason) ? null : ViewModel.Reason,
                        Location = string.IsNullOrWhiteSpace(ViewModel.Location) ? null : ViewModel.Location,
                        TsaUrl = ViewModel.UseTimestamp && !string.IsNullOrWhiteSpace(ViewModel.TsaUrl) ? ViewModel.TsaUrl : null,
                    };
                    var result = await Task.Run(() => new SigningService().Sign(req));
                    var dest = BatchDestination(item.Path);
                    File.Copy(result.OutputPath, dest, overwrite: false);
                    ViewModel.License.RecordSign();
                    item.Status = BatchStatus.Done;
                    item.Message = $"{result.PadesLevel} · {System.IO.Path.GetFileName(dest)}";
                }
                catch (SigningException ex)
                {
                    item.Status = BatchStatus.Failed;
                    item.Message = $"{ex.Message} ({ex.Code})";
                }
                catch (Exception ex)
                {
                    item.Status = BatchStatus.Failed;
                    item.Message = ex.Message;
                }
                ViewModel.RaiseBatchState();
            }
        }
        finally
        {
            ViewModel.BatchRunning = false;
            ViewModel.RaiseBatchState();
        }
    }

    /// <summary>Default bottom-right box on page 1, in PDF points (mirrors macOS).</summary>
    private static async Task<PlacementSpec?> DefaultPlacementAsync(string path, string signerName)
    {
        var file = await Windows.Storage.StorageFile.GetFileFromPathAsync(path);
        var doc = await Windows.Data.Pdf.PdfDocument.LoadFromFileAsync(file);
        if (doc.PageCount == 0) return null;
        using var page = doc.GetPage(0);
        const double DipToPoint = 72.0 / 96.0;
        double pw = page.Size.Width * DipToPoint;
        double w = 200, h = 60, m = 36;
        return new PlacementSpec
        {
            Page = 1, X = pw - w - m, Y = m, W = w, H = h,
            Lines = new List<string> { $"Firmado por: {signerName}", DateTime.Now.ToString("dd/MM/yyyy HH:mm") },
            Border = true, Background = true,
        };
    }

    /// <summary>Collision-safe "&lt;name&gt;&lt;suffix&gt;.pdf" beside the source.</summary>
    private static string BatchDestination(string sourcePath)
    {
        var dir = System.IO.Path.GetDirectoryName(sourcePath)!;
        var stem = System.IO.Path.GetFileNameWithoutExtension(sourcePath);
        var suffix = SettingsDialog.CurrentSuffix;
        var dest = System.IO.Path.Combine(dir, $"{stem}{suffix}.pdf");
        int n = 2;
        while (File.Exists(dest))
            dest = System.IO.Path.Combine(dir, $"{stem}{suffix} ({n++}).pdf");
        return dest;
    }

    private async void OnOpenClicked(object sender, RoutedEventArgs e)
    {
        // Unpackaged WinUI: pickers must be associated with the window's HWND.
        var picker = new FileOpenPicker { SuggestedStartLocation = PickerLocationId.DocumentsLibrary };
        picker.FileTypeFilter.Add(".pdf");
        InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(this));

        var file = await picker.PickSingleFileAsync();
        if (file is null) return;

        await LoadAsync(file.Path);
    }

    private async Task LoadAsync(string path)
    {
        try
        {
            ViewModel.StatusText = "Rendering…";
            var ok = await _renderer.LoadAsync(path);
            if (!ok) { ViewModel.StatusText = "Empty or unreadable PDF."; return; }

            var pages = await _renderer.RenderAllAsync();
            FitPagesToWidth(pages);
            PagesItems.ItemsSource = pages;
            ViewModel.FilePath = path;
            NewButton.IsEnabled = true;
            ViewModel.StatusText = $"{System.IO.Path.GetFileName(path)} — {pages.Count} page(s)";
        }
        catch (Exception ex)
        {
            ViewModel.StatusText = $"Failed to open: {ex.Message}";
        }
    }

    private void FitPagesToWidth(IEnumerable<RenderedPage> pages)
    {
        // ScrollViewer viewport minus its 16px padding each side and the 1px page
        // border. Fall back to ActualWidth before the first layout pass.
        var avail = PageScroller.ViewportWidth > 0 ? PageScroller.ViewportWidth : PageScroller.ActualWidth;
        avail = avail - 32 - 2;
        if (avail <= 0) return;
        foreach (var p in pages) p.FitToWidth(avail);
    }

    private void OnViewerSizeChanged(object sender, SizeChangedEventArgs e)
    {
        if (PagesItems.ItemsSource is IEnumerable<RenderedPage> pages)
            FitPagesToWidth(pages);
    }

    private async void OnSignClicked(object sender, RoutedEventArgs e)
    {
        if (_renderer.FilePath is null) return;

        // Certificate is chosen in the sidebar (mirrors macOS — no separate dialog).
        if (ViewModel.SelectedCert is not { CanSign: true, IsExpired: false } cert)
        {
            await ShowDialog("Sign", "Select a valid signing certificate in the sidebar first.");
            return;
        }

        // Free-tier gate: block when the monthly quota is exhausted (Pro is unlimited).
        if (!ViewModel.License.IsPro && ViewModel.License.RemainingFreeSigns <= 0)
        {
            await ShowPaywall($"You have used all {LicenseManager.FreeMonthlyLimit} free signatures this month.");
            return;
        }

        // Collect placement(s) for a visible signature; empty => invisible signature.
        var placements = new List<PlacementSpec>();
        if (ViewModel.VisibleSignature && PagesItems.ItemsSource is IReadOnlyList<RenderedPage> pages)
        {
            var lines = ViewModel.BuildLines(cert.CommonName);

            // Rasterize the logo + QR badge once and reuse the bytes across pages
            // (parity phase 7.7). QR payload carries a per-signature verify token.
            Rgba8? logo = ViewModel.HasLogo
                ? await SignatureImaging.LoadLogoAsync(ViewModel.LogoPath!)
                : null;
            Rgba8? qr = ViewModel.ShowQr
                ? SignatureImaging.Qr($"https://verify.pdflocalcert.app/v/{Guid.NewGuid():N}")
                : null;

            // "Sign all pages": replicate the single drawn box's page-relative
            // fractions onto every page before building the specs.
            if (ViewModel.SignAllPages &&
                pages.FirstOrDefault(p => p.NormalizedBox is not null)?.NormalizedBox is { } n)
            {
                foreach (var p in pages) p.SetNormalizedBox(n.X, n.Y, n.W, n.H);
            }

            foreach (var p in pages)
            {
                var spec = p.ToPlacement(lines, ViewModel.FontSize, ViewModel.WrapText,
                                         ViewModel.ShowBorder, !ViewModel.TransparentBackground,
                                         logo, qr);
                if (spec is not null) placements.Add(spec);
            }
            if (placements.Count == 0)
            {
                await ShowDialog("Sign", "Visible signature is on but no box was drawn. Drag a box on a page, or turn off visible signature.");
                return;
            }
        }

        ViewModel.IsSigning = true;
        ViewModel.StatusText = "Signing…";
        try
        {
            var req = new SignRequest
            {
                PdfPath = _renderer.FilePath,
                Cert = cert,
                Placements = placements,
                Reason = string.IsNullOrWhiteSpace(ViewModel.Reason) ? null : ViewModel.Reason,
                Location = string.IsNullOrWhiteSpace(ViewModel.Location) ? null : ViewModel.Location,
                TsaUrl = ViewModel.UseTimestamp && !string.IsNullOrWhiteSpace(ViewModel.TsaUrl) ? ViewModel.TsaUrl : null,
            };
            var result = await Task.Run(() => new SigningService().Sign(req));
            ViewModel.License.RecordSign(); // count against the free monthly quota (no-op for Pro)
            ViewModel.StatusText = $"Signed ({result.PadesLevel}). Choose where to save…";

            // Let the user save the signed PDF wherever they want.
            var suggested = System.IO.Path.GetFileNameWithoutExtension(_renderer.FilePath) + "-firmado";
            var savePicker = new FileSavePicker
            {
                SuggestedStartLocation = PickerLocationId.DocumentsLibrary,
                SuggestedFileName = suggested,
            };
            savePicker.FileTypeChoices.Add("PDF document", new List<string> { ".pdf" });
            InitializeWithWindow.Initialize(savePicker, WindowNative.GetWindowHandle(this));

            var dest = await savePicker.PickSaveFileAsync();
            string finalPath;
            if (dest is not null)
            {
                File.Copy(result.OutputPath, dest.Path, overwrite: true);
                finalPath = dest.Path;
            }
            else
            {
                finalPath = result.OutputPath; // user cancelled save; keep the temp copy
            }

            ViewModel.StatusText = $"Signed ({result.PadesLevel}) — {finalPath}";
            await ShowDialog("Signed",
                $"Signature created.\n\nSigner: {result.SignerCommonName}\nLevel: {result.PadesLevel}\n\nSaved to:\n{finalPath}");

            // Show the result in the default PDF viewer (separate window) when enabled.
            // The app keeps the *original* loaded and never opens the output itself, so
            // the user can sign again elsewhere and overwrite the output without locks.
            if (SettingsDialog.OpenAfterSign)
            {
                try
                {
                    var signedFile = await Windows.Storage.StorageFile.GetFileFromPathAsync(finalPath);
                    await Windows.System.Launcher.LaunchFileAsync(signedFile);
                }
                catch { /* no default viewer / launch refused — leave the file on disk */ }
            }
        }
        catch (SigningException ex)
        {
            ViewModel.StatusText = $"Sign failed [{ex.Code}]";
            await ShowDialog("Sign failed", $"{ex.Message}\n\n(code: {ex.Code})");
        }
        catch (Exception ex)
        {
            ViewModel.StatusText = "Sign failed";
            await ShowDialog("Sign failed", ex.Message);
        }
        finally
        {
            ViewModel.IsSigning = false;
        }
    }

    // ── Verify queue ─────────────────────────────────────────────────────────

    /// <summary>Toolbar "Verify": add the open document to the verify queue and
    /// switch to the Verify section.</summary>
    private void OnVerifyClicked(object sender, RoutedEventArgs e)
    {
        if (_renderer.FilePath is null) return;
        ViewModel.AddVerifyFiles(new[] { _renderer.FilePath });
        VerifySectionItem.IsSelected = true; // SelectorBar → OnSectionChanged sets the VM
    }

    private async void OnVerifyAdd(object sender, RoutedEventArgs e)
    {
        var picker = new FileOpenPicker { SuggestedStartLocation = PickerLocationId.DocumentsLibrary };
        picker.FileTypeFilter.Add(".pdf");
        InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(this));
        var files = await picker.PickMultipleFilesAsync();
        if (files is { Count: > 0 }) ViewModel.AddVerifyFiles(files.Select(f => f.Path));
    }

    private void OnVerifyReverify(object sender, RoutedEventArgs e) => ViewModel.ReverifyAll();
    private void OnVerifyClear(object sender, RoutedEventArgs e) => ViewModel.ClearVerify();

    private void OnVerifyRemove(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { Tag: VerifyItem item }) ViewModel.RemoveVerify(item);
    }

    private async void OnVerifyDrop(object sender, DragEventArgs e)
    {
        if (!e.DataView.Contains(Windows.ApplicationModel.DataTransfer.StandardDataFormats.StorageItems)) return;
        var items = await e.DataView.GetStorageItemsAsync();
        ViewModel.AddVerifyFiles(items.OfType<Windows.Storage.StorageFile>().Select(f => f.Path));
    }

    // Visible-signature placement (drag a box on a page).

    private void OnVisibleToggled(object sender, RoutedEventArgs e)
    {
        var on = VisibleSigToggle.IsOn;
        ViewModel.StatusText = on
            ? "Visible signature: drag a box on the page where the signature should appear."
            : "Visible signature off (an invisible, whole-document signature will be used).";
        if (!on && PagesItems.ItemsSource is IEnumerable<RenderedPage> pages)
            foreach (var p in pages) p.ClearBox();
        DrawBoxTip.IsOpen = on;
    }

    private void OnPagePointerPressed(object sender, PointerRoutedEventArgs e)
    {
        if (!VisibleSigToggle.IsOn) return;
        if (sender is not Canvas canvas || canvas.Tag is not RenderedPage page) return;
        DrawBoxTip.IsOpen = false;

        // Only one box across the document: clear any previous placement.
        if (PagesItems.ItemsSource is IEnumerable<RenderedPage> all)
            foreach (var p in all) if (!ReferenceEquals(p, page)) p.ClearBox();

        _drawing = true;
        _activeCanvas = canvas;
        _activePage = page;
        _drawStart = e.GetCurrentPoint(canvas).Position;
        canvas.CapturePointer(e.Pointer);
        page.SetBox(_drawStart.X, _drawStart.Y, 0, 0, canvas.ActualWidth, canvas.ActualHeight);
    }

    private void OnPagePointerMoved(object sender, PointerRoutedEventArgs e)
    {
        if (!_drawing || _activeCanvas is null || _activePage is null) return;
        var p = e.GetCurrentPoint(_activeCanvas).Position;
        var x = Math.Max(0, Math.Min(_drawStart.X, p.X));
        var y = Math.Max(0, Math.Min(_drawStart.Y, p.Y));
        var w = Math.Min(_activeCanvas.ActualWidth, Math.Abs(p.X - _drawStart.X));
        var h = Math.Min(_activeCanvas.ActualHeight, Math.Abs(p.Y - _drawStart.Y));
        _activePage.SetBox(x, y, w, h, _activeCanvas.ActualWidth, _activeCanvas.ActualHeight);
    }

    private void OnPagePointerReleased(object sender, PointerRoutedEventArgs e)
    {
        if (!_drawing || _activeCanvas is null || _activePage is null) return;
        _activeCanvas.ReleasePointerCapture(e.Pointer);
        _drawing = false;

        // Discard an accidental tiny box.
        if (_activePage.BoxW < MinBoxPx || _activePage.BoxH < MinBoxPx)
        {
            _activePage.ClearBox();
            ViewModel.StatusText = "Box too small - drag a larger area for the signature.";
        }
        else
        {
            ViewModel.StatusText = $"Signature box placed on page {_activePage.Index + 1}. Click Sign to apply.";
        }
        _activeCanvas = null;
        _activePage = null;
    }

    private async void OnSettingsClicked(object sender, RoutedEventArgs e)
    {
        var dialog = new SettingsDialog(ViewModel.License) { XamlRoot = Content.XamlRoot };
        await dialog.ShowAsync();
    }

    private async Task ShowPaywall(string reason)
    {
        var dialog = new SettingsDialog(ViewModel.License, paywallReason: reason) { XamlRoot = Content.XamlRoot };
        await dialog.ShowAsync();
    }

    private void OnPingClicked(object sender, RoutedEventArgs e)
    {
        try
        {
            var ok = new CoreClient().Ping();
            ViewModel.StatusText = ok ? $"core OK — {CoreClient.ResolveExePath()}" : "core ping failed";
        }
        catch (Exception ex)
        {
            ViewModel.StatusText = $"core error: {ex.Message}";
        }
    }

    private Task ShowDialog(string title, string message)
        => ShowContent(title, new TextBlock { Text = message, TextWrapping = TextWrapping.Wrap });

    private async Task ShowContent(string title, object content)
    {
        var dialog = new ContentDialog
        {
            Title = title,
            Content = content,
            CloseButtonText = "Close",
            XamlRoot = Content.XamlRoot,
        };
        await dialog.ShowAsync();
    }
}
