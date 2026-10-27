using System.Diagnostics;
using System.IO;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
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
    private FocusState _state = new();
    private bool _loading;

    public MainWindow()
    {
        InitializeComponent();
        _timer.Tick += (_, _) => RefreshSession();
        RefreshAll();
        _timer.Start();
    }

    private void RefreshAll()
    {
        _loading = true;
        _state = _store.Load();
        BlocklistBox.ItemsSource = null; BlocklistBox.ItemsSource = _state.Blocklists;
        SessionLists.ItemsSource = null; SessionLists.ItemsSource = _state.Blocklists;
        ScheduleLists.ItemsSource = null; ScheduleLists.ItemsSource = _state.Blocklists;
        ScheduleBox.ItemsSource = null; ScheduleBox.ItemsSource = _state.Schedules;
        AgentBox.IsChecked = _state.AgentEnabled; OtherBrowsersBox.IsChecked = _state.CloseOtherBrowsers;
        PasswordStatusText.Text = _state.AccountabilityPassword is null ? "No password set." : "An accountability password is set.";
        ActivityList.ItemsSource = _store.ReadActivity();
        _loading = false;
        if (_state.Blocklists.Count > 0) BlocklistBox.SelectedIndex = 0;
        RefreshSession();
    }

    private void RefreshSession()
    {
        _store.Tick(); _state = _store.Load();
        var active = _state.Sessions.Where(s => s.IsActive).ToList();
        if (active.Count == 0)
        {
            StatusText.Text = "No session active"; CountdownText.Text = "";
            StartButton.IsEnabled = true; StopButton.IsEnabled = false; FailsafeButton.IsEnabled = false; return;
        }
        var remaining = active.Min(s => s.EndsUtc) - DateTimeOffset.UtcNow;
        StatusText.Text = active.Any(s => s.Strict) ? $"Strict session active · {active.Count} blocklist session(s)" : $"Session active · {active.Count} session(s)";
        CountdownText.Text = $"{(int)remaining.TotalHours:00}:{remaining.Minutes:00}:{remaining.Seconds:00} remaining";
        StartButton.IsEnabled = false;
        StopButton.IsEnabled = active.All(s => s.Lock != SessionLock.Timer.ToString());
        FailsafeButton.IsEnabled = true;
        CloseBlockedProcesses();
    }

    private void Start_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            if (!int.TryParse(DurationBox.Text, out var minutes)) throw new InvalidOperationException("Choose a valid session length.");
            var selected = SessionLists.SelectedItems.Cast<Blocklist>().Select(b => b.Id).ToList();
            var lockName = ((ComboBoxItem)SessionLockBox.SelectedItem).Content.ToString()!;
            _store.StartSession(selected, minutes, Enum.Parse<SessionLock>(lockName), StrictBox.IsChecked == true);
            RefreshAll();
        }
        catch (Exception error) { ShowError(error); }
    }

    private void Stop_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            var state = _store.Load();
            var needsPassword = state.Sessions.Any(s => s.IsActive && s.Lock == "Password");
            var password = needsPassword ? PromptPassword("Enter the accountability password to end the session.") : null;
            if (needsPassword && password is null) return;
            _store.StopSessions(password); RefreshAll();
        }
        catch (Exception error) { ShowError(error); }
    }

    private void Failsafe_Click(object sender, RoutedEventArgs e)
    {
        var confirm = MessageBox.Show(this,
            "End all active blocks now, including timer- and password-locked sessions? Your blocklists, schedules, passwords and settings will be kept. This action will be recorded.",
            "Emergency failsafe", MessageBoxButton.YesNo, MessageBoxImage.Warning, MessageBoxResult.No);
        if (confirm != MessageBoxResult.Yes) return;
        var ended = _store.EndSessionsWithFailsafe();
        MessageBox.Show(this, ended == 0 ? "No active blocks." : $"Ended {ended} active block(s). Your settings were preserved.",
            "FocusBlocker", MessageBoxButton.OK, MessageBoxImage.Information);
        RefreshAll();
    }

    private void Blocklist_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_loading || BlocklistBox.SelectedItem is not Blocklist list) return;
        ListNameBox.Text = list.Name; DomainsBox.Text = string.Join(Environment.NewLine, list.Domains);
        ExceptionsBox.Text = string.Join(Environment.NewLine, list.Exceptions); ProcessesBox.Text = string.Join(Environment.NewLine, list.ProcessNames);
    }

    private void NewBlocklist_Click(object sender, RoutedEventArgs e)
    {
        _loading = true; BlocklistBox.SelectedItem = null; ListNameBox.Text = ""; DomainsBox.Text = ""; ExceptionsBox.Text = ""; ProcessesBox.Text = ""; _loading = false; ListNameBox.Focus();
    }

    private void SaveBlocklist_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            var selected = BlocklistBox.SelectedItem as Blocklist;
            var edited = new Blocklist { Id = selected?.Id ?? Guid.NewGuid(), Name = ListNameBox.Text,
                Domains = Lines(DomainsBox.Text), Exceptions = Lines(ExceptionsBox.Text), ProcessNames = Lines(ProcessesBox.Text) };
            if (selected is null) _store.CreateBlocklist(edited.Name, edited.Domains, edited.Exceptions, edited.ProcessNames);
            else _store.UpdateBlocklist(edited);
            RefreshAll();
            if (selected is not null) BlocklistBox.SelectedItem = _state.Blocklists.FirstOrDefault(b => b.Id == selected.Id);
        }
        catch (Exception error) { ShowError(error); }
    }

    private void DeleteBlocklist_Click(object sender, RoutedEventArgs e)
    {
        if (BlocklistBox.SelectedItem is not Blocklist list) return;
        try { _store.DeleteBlocklist(list.Id); RefreshAll(); }
        catch (Exception error) { ShowError(error); }
    }

    private void Import_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new OpenFileDialog { Title = "Import websites", Filter = "Text and JSON files|*.txt;*.json|All files|*.*", Multiselect = false };
        if (dialog.ShowDialog(this) != true) return;
        try { _store.ImportBlocklists(ParseImport(File.ReadAllText(dialog.FileName), Path.GetFileNameWithoutExtension(dialog.FileName))); RefreshAll(); }
        catch (Exception error) { ShowError(new InvalidOperationException("Could not import this file. Choose a plain-text domain list or a JSON export with website/domain fields. " + error.Message)); }
    }

    private void SaveSchedule_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            if (!TimeSpan.TryParse(ScheduleStartBox.Text, out var start) || !TimeSpan.TryParse(ScheduleEndBox.Text, out var end)
                || start < TimeSpan.Zero || start >= TimeSpan.FromDays(1) || end < TimeSpan.Zero || end >= TimeSpan.FromDays(1)
                || start.Seconds != 0 || end.Seconds != 0) throw new InvalidOperationException("Enter schedule times as HH:mm.");
            var days = DaysPanel.Children.OfType<CheckBox>().Where(c => c.IsChecked == true).Select(c => int.Parse(c.Tag.ToString()!)).ToList();
            var lockName = ((ComboBoxItem)ScheduleLockBox.SelectedItem).Content.ToString()!;
            var rule = new ScheduleRule { Name = ScheduleNameBox.Text, BlocklistIds = ScheduleLists.SelectedItems.Cast<Blocklist>().Select(b => b.Id).ToList(), Weekdays = days,
                StartMinute = start.Hours * 60 + start.Minutes, EndMinute = end.Hours * 60 + end.Minutes, TimeZoneId = TimeZoneInfo.Local.Id, Lock = lockName, Strict = ScheduleStrictBox.IsChecked == true, Enabled = true };
            _store.UpsertSchedule(rule); RefreshAll(); ScheduleNameBox.Text = "";
        }
        catch (Exception error) { ShowError(error); }
    }

    private void DeleteSchedule_Click(object sender, RoutedEventArgs e)
    {
        if (ScheduleBox.SelectedItem is not ScheduleRule rule) return;
        try { _store.DeleteSchedule(rule.Id); RefreshAll(); }
        catch (Exception error) { ShowError(error); }
    }

    private void SaveProtection_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            var enabled = AgentBox.IsChecked == true;
            _store.Update(state => { state.AgentEnabled = enabled; state.CloseOtherBrowsers = OtherBrowsersBox.IsChecked == true; });
            ConfigureAutoStart(enabled); EnsureAgent(); RefreshAll();
        }
        catch (Exception error) { ShowError(error); }
    }

    public void StartAgentIfEnabled() { if (_store.Load().AgentEnabled) EnsureAgent(); }

    private void SetPassword_Click(object sender, RoutedEventArgs e)
    {
        try { _store.SetPassword(NewPasswordBox.Password, string.IsNullOrEmpty(CurrentPasswordBox.Password) ? null : CurrentPasswordBox.Password); NewPasswordBox.Clear(); CurrentPasswordBox.Clear(); RefreshAll(); }
        catch (Exception error) { ShowError(error); }
    }

    private void InstallHost_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            var source = Path.Combine(AppContext.BaseDirectory, "host");
            var executable = Path.Combine(source, "FocusBlocker.NativeHost.exe");
            if (!File.Exists(executable)) throw new FileNotFoundException("The host folder is missing. Use the complete Windows release ZIP.", executable);
            var install = Path.Combine(StateStore.DirectoryPath, "native-host"); Directory.CreateDirectory(install);
            foreach (var file in Directory.GetFiles(source)) File.Copy(file, Path.Combine(install, Path.GetFileName(file)), overwrite: true);
            var manifestPath = Path.Combine(StateStore.DirectoryPath, "native-host.json");
            var manifest = new { name = "com.focusblocker.nmh", description = "FocusBlocker Chrome native messaging host", path = Path.Combine(install, "FocusBlocker.NativeHost.exe"), type = "stdio", allowed_origins = new[] { $"chrome-extension://{ExtensionId}/" } };
            File.WriteAllText(manifestPath, JsonSerializer.Serialize(manifest, new JsonSerializerOptions { WriteIndented = true }));
            using var key = Registry.CurrentUser.CreateSubKey(@"Software\Google\Chrome\NativeMessagingHosts\com.focusblocker.nmh"); key.SetValue(null, manifestPath, RegistryValueKind.String);
            MessageBox.Show("Chrome host installed for this Windows account. Then load the included Extension folder as an unpacked extension in chrome://extensions.", "FocusBlocker", MessageBoxButton.OK, MessageBoxImage.Information);
        }
        catch (Exception error) { ShowError(error); }
    }

    private void CloseBlockedProcesses()
    {
        var activeIds = _state.Sessions.Where(s => s.IsActive).SelectMany(s => s.BlocklistIds).ToHashSet();
        var lists = _state.Blocklists.Where(b => activeIds.Contains(b.Id)).ToList();
        var names = lists.SelectMany(b => b.ProcessNames).Distinct(StringComparer.OrdinalIgnoreCase).ToHashSet(StringComparer.OrdinalIgnoreCase);
        var hasWebsiteRules = lists.Any(b => b.Domains.Count > 0);
        if (_state.CloseOtherBrowsers && hasWebsiteRules && _state.Sessions.Any(s => s.IsActive && s.Strict))
            foreach (var browser in new[] { "msedge", "firefox", "brave", "opera", "vivaldi", "arc" }) names.Add(browser);
        var strictChrome = hasWebsiteRules && _state.Sessions.Any(s => s.IsActive && s.Strict)
            && (_state.ExtensionHeartbeatUtc is null || DateTimeOffset.UtcNow - _state.ExtensionHeartbeatUtc > TimeSpan.FromSeconds(45));
        if (strictChrome) names.Add("chrome");
        foreach (var name in names)
        {
            Process[] processes; try { processes = Process.GetProcessesByName(name); } catch { continue; }
            foreach (var process in processes)
            {
                try { if (process.Id != Environment.ProcessId && (!_lastCloseRequest.TryGetValue(process.Id, out var last) || DateTime.UtcNow - last >= TimeSpan.FromSeconds(10)) && process.CloseMainWindow()) _lastCloseRequest[process.Id] = DateTime.UtcNow; }
                catch { } finally { process.Dispose(); }
            }
        }
    }

    private static void ConfigureAutoStart(bool enabled)
    {
        using var key = Registry.CurrentUser.CreateSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run");
        const string name = "FocusBlockerAgent";
        if (enabled) key.SetValue(name, $"\"{Environment.ProcessPath}\" --agent", RegistryValueKind.String); else key.DeleteValue(name, false);
    }

    private static void EnsureAgent()
    {
        var exe = Environment.ProcessPath;
        if (exe is not null) Process.Start(new ProcessStartInfo(exe, "--agent") { UseShellExecute = false, CreateNoWindow = true, WindowStyle = ProcessWindowStyle.Hidden });
    }

    private static List<string> Lines(string value) => value.Split(new[] { '\r', '\n', ',', ';' }, StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries).ToList();

    private static IEnumerable<(string Name, IEnumerable<string> Domains, IEnumerable<string> Exceptions)> ParseImport(string contents, string fallbackName)
    {
        if (contents.TrimStart().StartsWith("CTB", StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("This encoded Cold Turkey export is not readable here. Export a JSON file using Cold Turkey’s own export option, or copy websites into a text file, one per line.");
        if (!contents.TrimStart().StartsWith('{') && !contents.TrimStart().StartsWith('['))
            return [(fallbackName, contents.Split('\n').Select(line => line.Trim()).Where(line => line.Length > 0 && !line.StartsWith('#')).SelectMany(line => line.Split(new[] { ' ', '\t', ',', ';' }, StringSplitOptions.RemoveEmptyEntries)), Array.Empty<string>())];
        using var document = JsonDocument.Parse(contents);
        var results = new List<(string Name, IEnumerable<string> Domains, IEnumerable<string> Exceptions)>();
        var root = document.RootElement;
        if (root.ValueKind == JsonValueKind.Object && root.TryGetProperty("blocks", out var blocks) && blocks.ValueKind == JsonValueKind.Object)
        {
            foreach (var block in blocks.EnumerateObject())
            {
                var (domains, exceptions) = Extract(block.Value);
                if (domains.Count > 0 || exceptions.Count > 0) results.Add((block.Name, domains, exceptions));
            }
        }
        else { var (domains, exceptions) = Extract(root); if (domains.Count > 0 || exceptions.Count > 0) results.Add((fallbackName, domains, exceptions)); }
        if (results.Count == 0) throw new InvalidDataException("No website rules were found.");
        return results;

        static (List<string> Domains, List<string> Exceptions) Extract(JsonElement node)
        {
            var domains = new List<string>(); var exceptions = new List<string>();
            void Walk(JsonElement value)
            {
                if (value.ValueKind == JsonValueKind.Object)
                {
                    foreach (var property in value.EnumerateObject())
                    {
                        var key = property.Name.ToLowerInvariant();
                        if (key is "web" or "websites" or "blocklist" or "domains" or "sites") CollectStrings(property.Value, domains);
                        else if (key is "exceptions" or "exceptionlist" or "allow" or "allowlist") CollectStrings(property.Value, exceptions);
                        else Walk(property.Value);
                    }
                }
                else if (value.ValueKind == JsonValueKind.Array) foreach (var item in value.EnumerateArray()) Walk(item);
            }
            Walk(node); return (domains, exceptions);
        }
        static void CollectStrings(JsonElement node, List<string> output)
        {
            if (node.ValueKind == JsonValueKind.String) output.Add(node.GetString() ?? "");
            else if (node.ValueKind == JsonValueKind.Array) foreach (var item in node.EnumerateArray()) CollectStrings(item, output);
            else if (node.ValueKind == JsonValueKind.Object) foreach (var property in node.EnumerateObject()) CollectStrings(property.Value, output);
        }
    }

    private static string? PromptPassword(string prompt)
    {
        var dialog = new PasswordDialog(prompt) { Owner = Application.Current.MainWindow };
        return dialog.ShowDialog() == true ? dialog.PasswordValue : null;
    }

    private static void ShowError(Exception error) => MessageBox.Show(error.Message, "FocusBlocker", MessageBoxButton.OK, MessageBoxImage.Information);
}
