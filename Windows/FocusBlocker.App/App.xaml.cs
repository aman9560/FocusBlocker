using System.Diagnostics;
using System.IO;
using System.Windows;
using System.Windows.Threading;
using FocusBlocker.Core;

namespace FocusBlocker.App;

public partial class App : Application
{
    private Mutex? _agentMutex;
    private DispatcherTimer? _agentTimer;
    private readonly Enforcer _enforcer = new();

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
        if (e.Args.Contains("--install-host", StringComparer.OrdinalIgnoreCase))
        {
            // Used by install-windows.ps1: no window, and the exit code says whether it worked.
            ShutdownMode = ShutdownMode.OnExplicitShutdown;
            try { ChromeHostInstaller.Install(); Shutdown(0); }
            catch (Exception error)
            {
                // A windowless app has nowhere to show this, so keep it where the installer's warning can point to.
                try { Directory.CreateDirectory(StateStore.DirectoryPath); File.WriteAllText(Path.Combine(StateStore.DirectoryPath, "install-host-error.txt"), error.ToString()); } catch { }
                Shutdown(1);
            }
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
            _enforcer.Run(store, state);
        }
        catch { /* Continue periodic enforcement after transient state or process errors. */ }
    }

    protected override void OnExit(ExitEventArgs e)
    {
        _agentTimer?.Stop(); _agentMutex?.Dispose(); base.OnExit(e);
    }
}
