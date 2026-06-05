using Microsoft.UI.Xaml;

namespace BureaucratPdf.App;

public partial class App : Application
{
    private Window? _window;

    public App() => InitializeComponent();

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        AppSettings.ApplyLanguage();   // set the locale override before any UI loads
        _window = new MainWindow();
        _window.Activate();
    }
}
