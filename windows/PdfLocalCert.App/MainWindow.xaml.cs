using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using PdfLocalCert.Core;
using Windows.Foundation;
using Windows.Storage.Pickers;
using WinRT.Interop;

namespace PdfLocalCert.App;

public sealed partial class MainWindow : Window
{
    private readonly PdfRenderer _renderer = new();

    // Signature-box drag state.
    private bool _drawing;
    private Point _drawStart;
    private Canvas? _activeCanvas;
    private RenderedPage? _activePage;
    private const double MinBoxPx = 24;

    public MainWindow() => InitializeComponent();

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
            StatusText.Text = "Rendering…";
            var ok = await _renderer.LoadAsync(path);
            if (!ok) { StatusText.Text = "Empty or unreadable PDF."; return; }

            var pages = await _renderer.RenderAllAsync();
            FitPagesToWidth(pages);
            PagesItems.ItemsSource = pages;
            VerifyButton.IsEnabled = true;
            SignButton.IsEnabled = true;
            VisibleSigToggle.IsEnabled = true;
            StatusText.Text = $"{System.IO.Path.GetFileName(path)} — {pages.Count} page(s)";
        }
        catch (Exception ex)
        {
            StatusText.Text = $"Failed to open: {ex.Message}";
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

        List<CertificateInfo> identities;
        try
        {
            identities = IdentityStore.LoadSigningIdentities();
        }
        catch (Exception ex)
        {
            await ShowDialog("Sign", $"Could not read the certificate store: {ex.Message}");
            return;
        }
        if (identities.Count == 0)
        {
            await ShowDialog("Sign", "No signing certificates found in your personal store (Certificates - Current User \\ Personal). Import your certificate and try again.");
            return;
        }

        var dialog = new SignDialog(identities) { XamlRoot = Content.XamlRoot };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
        if (dialog.SelectedCert is not { } cert) return;

        // Collect the drawn placement(s). Visible signature on + a box drawn =>
        // visible placement; otherwise an invisible whole-document signature.
        var placements = new List<PlacementSpec>();
        if (VisibleSigToggle.IsChecked == true && PagesItems.ItemsSource is IEnumerable<RenderedPage> pages)
        {
            var lines = new List<string> { $"Firmado por: {cert.CommonName}" };
            if (!string.IsNullOrWhiteSpace(dialog.Reason)) lines.Add(dialog.Reason!);
            foreach (var p in pages)
            {
                var spec = p.ToPlacement(lines);
                if (spec is not null) placements.Add(spec);
            }
            if (placements.Count == 0)
            {
                await ShowDialog("Sign", "Visible signature is on but no box was drawn. Drag a box on a page, or turn off visible signature.");
                return;
            }
        }

        StatusText.Text = "Signing…";
        try
        {
            var req = new SignRequest
            {
                PdfPath = _renderer.FilePath,
                Cert = cert,
                Placements = placements,
                Reason = dialog.Reason,
                Location = dialog.Location,
                TsaUrl = dialog.TsaUrl,
            };
            var result = await Task.Run(() => new SigningService().Sign(req));
            StatusText.Text = $"Signed ({result.PadesLevel}). Choose where to save…";

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

            StatusText.Text = $"Signed ({result.PadesLevel}) — {finalPath}";
            await ShowDialog("Signed",
                $"Signature created.\n\nSigner: {result.SignerCommonName}\nLevel: {result.PadesLevel}\n\nSaved to:\n{finalPath}");

            // Reload the signed output so Verify reflects it immediately.
            await LoadAsync(finalPath);
        }
        catch (SigningException ex)
        {
            StatusText.Text = $"Sign failed [{ex.Code}]";
            await ShowDialog("Sign failed", $"{ex.Message}\n\n(code: {ex.Code})");
        }
        catch (Exception ex)
        {
            StatusText.Text = "Sign failed";
            await ShowDialog("Sign failed", ex.Message);
        }
    }

    private async void OnVerifyClicked(object sender, RoutedEventArgs e)
    {
        if (_renderer.FilePath is null) return;
        try
        {
            var results = new SigningService().Verify(_renderer.FilePath);
            await ShowVerifyDialog(results);
        }
        catch (SigningException ex) when (ex.Code == "NO_SIGNATURE")
        {
            await ShowDialog("Verify", "This document has no signatures.");
        }
        catch (Exception ex)
        {
            await ShowDialog("Verify failed", ex.Message);
        }
    }

    private async Task ShowVerifyDialog(List<VerificationResult> results)
    {
        var panel = new StackPanel { Spacing = 12 };
        foreach (var r in results)
        {
            panel.Children.Add(new TextBlock
            {
                Text = $"{(r.Valid ? "✓ Valid" : "✗ Invalid")}\n" +
                       $"Signer: {r.Signer}\nIssuer: {r.Issuer}\n" +
                       $"Level: {r.Level}   Timestamp: {(r.HasTimestamp ? "yes" : "no")}",
                TextWrapping = TextWrapping.Wrap,
            });
        }
        await ShowContent($"{results.Count} signature(s)", panel);
    }

    // Visible-signature placement (drag a box on a page).

    private void OnVisibleToggled(object sender, RoutedEventArgs e)
    {
        var on = VisibleSigToggle.IsChecked == true;
        StatusText.Text = on
            ? "Visible signature: drag a box on the page where the signature should appear."
            : "Visible signature off (an invisible, whole-document signature will be used).";
        if (!on && PagesItems.ItemsSource is IEnumerable<RenderedPage> pages)
            foreach (var p in pages) p.ClearBox();
    }

    private void OnPagePointerPressed(object sender, PointerRoutedEventArgs e)
    {
        if (VisibleSigToggle.IsChecked != true) return;
        if (sender is not Canvas canvas || canvas.Tag is not RenderedPage page) return;

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
            StatusText.Text = "Box too small - drag a larger area for the signature.";
        }
        else
        {
            StatusText.Text = $"Signature box placed on page {_activePage.Index + 1}. Click Sign to apply.";
        }
        _activeCanvas = null;
        _activePage = null;
    }

    private void OnPingClicked(object sender, RoutedEventArgs e)
    {
        try
        {
            var ok = new CoreClient().Ping();
            StatusText.Text = ok ? $"core OK — {CoreClient.ResolveExePath()}" : "core ping failed";
        }
        catch (Exception ex)
        {
            StatusText.Text = $"core error: {ex.Message}";
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
