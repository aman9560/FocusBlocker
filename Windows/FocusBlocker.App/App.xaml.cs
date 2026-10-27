using System.Diagnostics;
using System.Windows;
using System.Windows.Threading;
using FocusBlocker.Core;

namespace FocusBlocker.App;

public partial class App : Application
{
    private Mutex? _agentMutex;
    private DispatcherTimer? _agentTimer;
    private readonly Dictionary<int, DateTime> _lastCloseRequest = [];

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        if (e.Args.Contains("--agent", StringComparer.OrdinalIgnoreCase))
        {
            ShutdownMode = ShutdownMode.OnExplicitShutdown;
            _agentMutex = new Mutex(true, "Local\\FocusBlockerBackgroundAgent", out var created);
            if (!created) { Shutdown(); return; }
            _agentTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(5) };
            _agentTimer.Tick += (_, _) => Enforce(); _agentTimer.Start(); Enforce();
            return;
        }
        if (e.Args.Contains("--failsafe-end", StringComparer.OrdinalIgnoreCase))
        {
            ShutdownMode = ShutdownMode.OnExplicitShutdown;
            var confirm = MessageBox.Show(
                "End all active FocusBlocker sessions now, including timer- and password-locked sessions? Your blocklists, schedules, passwords and settings will be kept, and the action will be recorded.",
                "FocusBlocker emergency failsafe", MessageBoxButton.YesNo, MessageBoxImage.Warning, MessageBoxResult.No);
            if (confirm == MessageBoxResult.Yes)
            {
                try
                {
                    var ended = new StateStore().EndSessionsWithFailsafe();
                    MessageBox.Show(ended == 0 ? "No active blocks." : $"Ended {ended} active block(s). Your settings were preserved.",
                        "FocusBlocker", MessageBoxButton.OK, MessageBoxImage.Information);
                }
                catch (Exception error)
                {
                    MessageBox.Show(error.Message, "FocusBlocker failsafe failed", MessageBoxButton.OK, MessageBoxImage.Error);
                }
            }
            Shutdown();
            return;
        }
        var main = new MainWindow(); MainWindow = main; main.Show();
        if (new StateStore().Load().AgentEnabled) main.StartAgentIfEnabled();
    }

    private void Enforce()
    {
        try
        {
            var store = new StateStore(); store.Tick(); var state = store.Load();
            if (!state.AgentEnabled) { Shutdown(); return; }
            var active = state.Sessions.Where(s => s.IsActive).ToList();
            if (active.Count == 0) return;
            var ids = active.SelectMany(s => s.BlocklistIds).ToHashSet();
            var lists = state.Blocklists.Where(b => ids.Contains(b.Id)).ToList();
            var blocked = lists.SelectMany(b => b.ProcessNames).Distinct(StringComparer.OrdinalIgnoreCase).ToHashSet(StringComparer.OrdinalIgnoreCase);
            var websiteRules = lists.Any(b => b.Domains.Count > 0);
            var strictWeb = websiteRules && active.Any(s => s.Strict);
            if (state.CloseOtherBrowsers && strictWeb)
                foreach (var name in new[] { "msedge", "firefox", "brave", "opera", "vivaldi", "arc" }) blocked.Add(name);
            if (strictWeb && (state.ExtensionHeartbeatUtc is null || DateTimeOffset.UtcNow - state.ExtensionHeartbeatUtc > TimeSpan.FromSeconds(45))) blocked.Add("chrome");
            foreach (var name in blocked)
            {
                Process[] processes; try { processes = Process.GetProcessesByName(name); } catch { continue; }
                foreach (var process in processes)
                {
                    try { if (process.Id != Environment.ProcessId && (!_lastCloseRequest.TryGetValue(process.Id, out var last) || DateTime.UtcNow - last >= TimeSpan.FromSeconds(10)) && process.CloseMainWindow()) _lastCloseRequest[process.Id] = DateTime.UtcNow; }
                    catch { } finally { process.Dispose(); }
                }
            }
        }
        catch { /* Continue periodic enforcement after transient state or process errors. */ }
    }

    protected override void OnExit(ExitEventArgs e)
    {
        _agentTimer?.Stop(); _agentMutex?.Dispose(); base.OnExit(e);
    }
}
