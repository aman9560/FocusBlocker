using System.Diagnostics;
using System.IO;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Threading;
using Microsoft.Win32;
using FocusBlocker.Core;

namespace FocusBlocker.App;

public partial class MainWindow : Window
{
    private readonly StateStore _store = new();
    private readonly DispatcherTimer _timer = new() { Interval = TimeSpan.FromSeconds(1) };
    private readonly Enforcer _enforcer = new();
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
        NoListsHint.Visibility = _state.Blocklists.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        NoSchedulesHint.Visibility = _state.Schedules.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        _loading = false;
        if (_state.Blocklists.Count > 0) BlocklistBox.SelectedIndex = 0;
        RefreshSession();
    }

    private void Nav_Checked(object sender, RoutedEventArgs e)
    {
        if (PageActivity is null) return;  // Checked fires while the window is still being built.
        var pages = new (RadioButton Nav, UIElement Page)[]
        {
            (NavFocus, PageFocus), (NavBlocklists, PageBlocklists), (NavSchedules, PageSchedules), (NavProtection, PageProtection), (NavActivity, PageActivity)
        };
        foreach (var (nav, page) in pages) page.Visibility = ReferenceEquals(nav, sender) ? Visibility.Visible : Visibility.Collapsed;
        if (ReferenceEquals(sender, NavActivity)) ActivityList.ItemsSource = _store.ReadActivity();
    }

    private void Preset_Click(object sender, RoutedEventArgs e) => DurationBox.Text = (string)((Button)sender).Tag;

    private void RefreshSession()
    {
        try { _store.Tick(); _state = _store.Load(); }
        catch (Exception) { return; }  // A busy or briefly unreadable state file must not crash the timer; try again next second.
        var active = _state.Sessions.Where(s => s.IsActive).ToList();
        if (active.Count == 0)
        {
            StatusText.Text = "No session active"; CountdownText.Text = "Ready";
            StatusDot.Fill = (Brush)FindResource("MutedBrush");
            StartButton.IsEnabled = true; StopButton.IsEnabled = false; FailsafeButton.IsEnabled = false; return;
        }
        var remaining = active.Min(s => s.EndsUtc) - DateTimeOffset.UtcNow;
        StatusText.Text = active.Any(s => s.Strict) ? $"Strict session active · {active.Count} blocklist session(s)" : $"Session active · {active.Count} session(s)";
        CountdownText.Text = $"{(int)remaining.TotalHours:00}:{remaining.Minutes:00}:{remaining.Seconds:00}";
        StatusDot.Fill = (Brush)FindResource("AccentBrush");
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
        try { _store.ImportBlocklists(BlocklistImporter.Parse(File.ReadAllText(dialog.FileName), Path.GetFileNameWithoutExtension(dialog.FileName))); RefreshAll(); }
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
            ChromeHostInstaller.Install();
            MessageBox.Show("Chrome host installed for this Windows account. Then load the included extension folder as an unpacked extension in chrome://extensions.", "FocusBlocker", MessageBoxButton.OK, MessageBoxImage.Information);
        }
        catch (Exception error) { ShowError(error); }
    }

    private void CloseBlockedProcesses() => _enforcer.Run(_store, _state);

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

    private static string? PromptPassword(string prompt)
    {
        var dialog = new PasswordDialog(prompt) { Owner = Application.Current.MainWindow };
        return dialog.ShowDialog() == true ? dialog.PasswordValue : null;
    }

    private static void ShowError(Exception error) => MessageBox.Show(error.Message, "FocusBlocker", MessageBoxButton.OK, MessageBoxImage.Information);
}
