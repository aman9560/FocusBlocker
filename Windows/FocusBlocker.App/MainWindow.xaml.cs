using System.Diagnostics;
using System.IO;
using System.Text.Json;
using System.Windows;
using System.Windows.Threading;
using Microsoft.Win32;
using FocusBlocker.Core;

namespace FocusBlocker.App;

public partial class MainWindow : Window
{
    private const string ExtensionId = "mchnpkbnifalondddkmcbplnlebaebmd";
    private readonly StateStore _store = new();
    private readonly DispatcherTimer _timer = new() { Interval = TimeSpan.FromSeconds(1) };
    private readonly Dictionary<int, DateTime> _lastCloseRequest = [];
    private FocusState _state;

    public MainWindow()
    {
        InitializeComponent();
        _state = _store.Load();
        DomainsBox.Text = string.Join(Environment.NewLine, _state.Domains);
        ExceptionsBox.Text = string.Join(Environment.NewLine, _state.Exceptions);
        ProcessesBox.Text = string.Join(Environment.NewLine, _state.ProcessNames);
        _timer.Tick += (_, _) => RefreshSession();
        _timer.Start();
        RefreshSession();
    }

    private void Start_Click(object sender, RoutedEventArgs e)
    {
        if (!int.TryParse(DurationBox.Text, out var minutes) || minutes is < 1 or > 720)
        {
            MessageBox.Show("Choose a session length from 1 to 720 minutes.", "Focus Blocker", MessageBoxButton.OK, MessageBoxImage.Information);
            return;
        }

        var domains = StateStore.NormalizeMany(DomainsBox.Text.Split(new[] { '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries));
        var exceptions = StateStore.NormalizeMany(ExceptionsBox.Text.Split(new[] { '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries));
        var processes = NormalizeProcesses(ProcessesBox.Text);
        if (domains.Count == 0 && processes.Count == 0)
        {
            MessageBox.Show("Add at least one website or application to block.", "Focus Blocker", MessageBoxButton.OK, MessageBoxImage.Information);
            return;
        }

        _state = new FocusState
        {
            SessionActive = true,
            Strict = StrictBox.IsChecked == true,
            SessionEndsUtc = DateTimeOffset.UtcNow.AddMinutes(minutes),
            Domains = domains,
            Exceptions = exceptions,
            ProcessNames = processes
        };
        _store.Save(_state);
        RefreshSession();
    }

    private void Stop_Click(object sender, RoutedEventArgs e)
    {
        if (_state.Strict) return;
        _state.SessionActive = false;
        _state.SessionEndsUtc = null;
        _store.Save(_state);
        RefreshSession();
    }

    private void RefreshSession()
    {
        _state = _store.Load();
        var remaining = _state.SessionEndsUtc is { } end ? end - DateTimeOffset.UtcNow : TimeSpan.Zero;
        if (!_state.SessionActive || remaining <= TimeSpan.Zero)
        {
            if (_state.SessionActive)
            {
                _state.SessionActive = false;
                _state.Strict = false;
                _state.SessionEndsUtc = null;
                _store.Save(_state);
            }
            StatusText.Text = "No session active";
            CountdownText.Text = "";
            StartButton.IsEnabled = true;
            StopButton.IsEnabled = false;
            return;
        }

        StatusText.Text = _state.Strict ? "Strict session active" : "Session active";
        CountdownText.Text = $"{(int)remaining.TotalHours:00}:{remaining.Minutes:00}:{remaining.Seconds:00} remaining";
        StartButton.IsEnabled = false;
        StopButton.IsEnabled = !_state.Strict;
        CloseBlockedProcesses();
    }

    private void CloseBlockedProcesses()
    {
        foreach (var name in _state.ProcessNames)
        {
            foreach (var process in SafeProcesses(name))
            {
                try
                {
                    if (process.Id == Environment.ProcessId) continue;
                    if (_lastCloseRequest.TryGetValue(process.Id, out var last) && DateTime.UtcNow - last < TimeSpan.FromSeconds(10)) continue;
                    if (process.CloseMainWindow()) _lastCloseRequest[process.Id] = DateTime.UtcNow;
                }
                catch { }
                finally { process.Dispose(); }
            }
        }
    }

    private void InstallHost_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            var source = Path.Combine(AppContext.BaseDirectory, "host");
            var executable = Path.Combine(source, "FocusBlocker.NativeHost.exe");
            if (!File.Exists(executable)) throw new FileNotFoundException("The host folder is missing. Use the complete Windows release ZIP.", executable);
            var install = Path.Combine(StateStore.DirectoryPath, "native-host");
            Directory.CreateDirectory(install);
            foreach (var file in Directory.GetFiles(source)) File.Copy(file, Path.Combine(install, Path.GetFileName(file)), overwrite: true);

            var manifestPath = Path.Combine(StateStore.DirectoryPath, "native-host.json");
            var manifest = new
            {
                name = "com.focusblocker.nmh",
                description = "Focus Blocker Chrome native messaging host",
                path = Path.Combine(install, "FocusBlocker.NativeHost.exe"),
                type = "stdio",
                allowed_origins = new[] { $"chrome-extension://{ExtensionId}/" }
            };
            File.WriteAllText(manifestPath, JsonSerializer.Serialize(manifest, new JsonSerializerOptions { WriteIndented = true }));
            using var key = Registry.CurrentUser.CreateSubKey(@"Software\Google\Chrome\NativeMessagingHosts\com.focusblocker.nmh");
            key.SetValue(null, manifestPath, RegistryValueKind.String);
            MessageBox.Show("Chrome host installed for this Windows account. Next, load the included Extension folder as an unpacked extension in chrome://extensions.",
                "Focus Blocker", MessageBoxButton.OK, MessageBoxImage.Information);
        }
        catch (Exception error)
        {
            MessageBox.Show(error.Message, "Could not install Chrome host", MessageBoxButton.OK, MessageBoxImage.Error);
        }
    }

    private static List<string> NormalizeProcesses(string text) => text.Split(new[] { '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries)
        .Select(value => Path.GetFileNameWithoutExtension(value.Trim()))
        .Where(value => value.Length > 0)
        .Where(value => !new[] { "csrss", "dwm", "explorer", "lsass", "services", "smss", "wininit", "winlogon", "focusblocker" }.Contains(value, StringComparer.OrdinalIgnoreCase))
        .Distinct(StringComparer.OrdinalIgnoreCase)
        .ToList();

    private static Process[] SafeProcesses(string name)
    {
        try { return Process.GetProcessesByName(name); }
        catch { return []; }
    }
}
