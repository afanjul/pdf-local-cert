using Microsoft.UI.Xaml;
using PdfLocalCert.Core;

namespace PdfLocalCert.App;

public sealed partial class MainWindow : Window
{
    public MainWindow() => InitializeComponent();

    private void OnPingClicked(object sender, RoutedEventArgs e)
    {
        try
        {
            var client = new CoreClient();
            var ok = client.Ping();
            StatusText.Text = ok
                ? $"core OK — {CoreClient.ResolveExePath()}"
                : "core responded but ping failed";
        }
        catch (Exception ex)
        {
            StatusText.Text = $"core error: {ex.Message}";
        }
    }
}
