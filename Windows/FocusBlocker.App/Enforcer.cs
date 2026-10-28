using System.Diagnostics;
using FocusBlocker.Core;
using Microsoft.Win32;

namespace FocusBlocker.App;

/// <summary>
/// Applies <see cref="ProcessGuard"/>'s plan: asks processes to close the way the user would (the window's close
/// button) and never force-kills, so unsaved work can't be lost. Shared by the main window and the background agent.
/// </summary>
public sealed class Enforcer
{
    private static readonly TimeSpan RetryAfter = TimeSpan.FromSeconds(10);
    private readonly Dictionary<int, DateTime> _lastRequest = [];

    public static bool ChromeHostInstalled()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(@"Software\Google\Chrome\NativeMessagingHosts\com.focusblocker.nmh");
            return key is not null;
        }
        catch { return false; }
    }

    public void Run(StateStore store, FocusState state)
    {
        if (!state.Sessions.Any(s => s.IsActive)) { _lastRequest.Clear(); return; }
        var processes = Process.GetProcesses();
        try
        {
            var running = new List<RunningProcess>();
            foreach (var process in processes)
            {
                try
                {
                    // Start time is only needed to give a freshly launched Chrome time to start the extension.
                    DateTimeOffset? started = null;
                    if (process.ProcessName.Equals("chrome", StringComparison.OrdinalIgnoreCase))
                        try { started = new DateTimeOffset(process.StartTime); } catch { /* access denied: treated as unknown */ }
                    running.Add(new RunningProcess(process.Id, process.ProcessName, started));
                }
                catch { /* the process exited while listing */ }
            }

            var live = running.Select(r => r.Id).ToHashSet();
            foreach (var id in _lastRequest.Keys.Where(id => !live.Contains(id)).ToList()) _lastRequest.Remove(id);

            foreach (var request in ProcessGuard.Plan(state, DateTimeOffset.UtcNow, running, ChromeHostInstalled(), Environment.ProcessId))
            {
                var process = processes.FirstOrDefault(p => p.Id == request.Id);
                if (process is null) continue;
                var firstRequest = !_lastRequest.TryGetValue(request.Id, out var last);
                if (!firstRequest && DateTime.UtcNow - last < RetryAfter) continue;
                try
                {
                    // False means the process has no window to close (for example a helper process), which is fine.
                    if (!process.CloseMainWindow()) continue;
                    _lastRequest[request.Id] = DateTime.UtcNow;
                    if (firstRequest) store.RecordActivity("app.closed", $"{request.Name}: {request.Reason}");
                }
                catch { /* access denied or already exiting */ }
            }
        }
        finally
        {
            foreach (var process in processes) process.Dispose();
        }
    }
}
