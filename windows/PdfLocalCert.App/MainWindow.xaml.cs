using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using PdfLocalCert.Core;
using Windows.Storage.Pickers;
using WinRT.Interop;

namespace PdfLocalCert.App;

public sealed partial class MainWindow : Window
{
    private readonly PdfRenderer _renderer = new();

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
            PagesItems.ItemsSource = pages;
            VerifyButton.IsEnabled = true;
            StatusText.Text = $"{System.IO.Path.GetFileName(path)} — {pages.Count} page(s)";
        }
        catch (Exception ex)
        {
            StatusText.Text = $"Failed to open: {ex.Message}";
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
