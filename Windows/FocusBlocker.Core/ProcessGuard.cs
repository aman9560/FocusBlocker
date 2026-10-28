namespace FocusBlocker.Core;

public sealed record RunningProcess(int Id, string Name, DateTimeOffset? StartTime);

public sealed record CloseRequest(int Id, string Name, string Reason);

/// <summary>
/// Decides which running processes the active sessions require to be closed. Pure logic with no process access,
/// so the Windows app, the background agent and the tests all share one definition.
/// </summary>
public static class ProcessGuard
{
    /// <summary>Time a freshly started Chrome gets to start the extension before it counts as unresponsive.</summary>
    public static readonly TimeSpan ChromeStartupGrace = TimeSpan.FromSeconds(30);

    /// <summary>Extensions report every 15 seconds; this tolerates two missed reports.</summary>
    public static readonly TimeSpan HeartbeatStaleAfter = TimeSpan.FromSeconds(45);

    /// <summary>Browsers that can't run the Focus Chrome extension.</summary>
    public static readonly string[] OtherBrowsers =
        ["msedge", "firefox", "brave", "opera", "vivaldi", "arc", "zen", "librewolf", "waterfox", "chromium", "iexplore"];

    private static readonly string[] SystemProcesses = ["csrss", "dwm", "explorer", "lsass", "services", "smss", "wininit", "winlogon", "taskmgr"];

    /// <summary>Processes that are never closed and can't be added to a blocklist, so a session can't make the PC unusable.</summary>
    public static bool IsProtected(string name) =>
        name.StartsWith("focusblocker", StringComparison.OrdinalIgnoreCase)
        || SystemProcesses.Contains(name, StringComparer.OrdinalIgnoreCase);

    public static List<CloseRequest> Plan(FocusState state, DateTimeOffset now, IReadOnlyCollection<RunningProcess> running,
        bool chromeHostInstalled, int ownProcessId)
    {
        var requests = new List<CloseRequest>();
        var active = state.Sessions.Where(s => s.EndedUtc is null && s.EndsUtc > now).ToList();
        if (active.Count == 0) return requests;

        var ids = active.SelectMany(s => s.BlocklistIds).ToHashSet();
        var lists = state.Blocklists.Where(b => ids.Contains(b.Id)).ToList();
        var blocked = lists.SelectMany(b => b.ProcessNames).ToHashSet(StringComparer.OrdinalIgnoreCase);
        var strictWeb = lists.Any(b => b.Domains.Count > 0) && active.Any(s => s.Strict);
        var closeOthers = state.CloseOtherBrowsers && strictWeb;

        var candidates = running.Where(p => p.Id != ownProcessId && !IsProtected(p.Name)).ToList();
        foreach (var process in candidates)
        {
            if (blocked.Contains(process.Name))
                requests.Add(new CloseRequest(process.Id, process.Name, "blocked during this focus session"));
            else if (closeOthers && OtherBrowsers.Contains(process.Name, StringComparer.OrdinalIgnoreCase))
                requests.Add(new CloseRequest(process.Id, process.Name, "only Chrome with the Focus extension is allowed during strict sessions"));
        }

        // Chrome is judged as a group: helper processes start later than the browser itself, so only the oldest
        // process says when this Chrome started. Nothing happens before the host is installed or during start-up.
        var chrome = candidates.Where(p => p.Name.Equals("chrome", StringComparison.OrdinalIgnoreCase)
                                           && !requests.Any(r => r.Id == p.Id)).ToList();
        if (strictWeb && chromeHostInstalled && chrome.Count > 0)
        {
            var started = chrome.Where(p => p.StartTime is not null).Select(p => p.StartTime!.Value).DefaultIfEmpty().Min();
            var knownStart = chrome.Any(p => p.StartTime is not null);
            var pastGrace = !knownStart || now - started >= ChromeStartupGrace;
            var heartbeat = state.ExtensionHeartbeatUtc;
            // A heartbeat from before this Chrome started came from an earlier run and doesn't count.
            var fresh = heartbeat is { } beat && now - beat <= HeartbeatStaleAfter && (!knownStart || beat >= started);
            if (pastGrace && !fresh)
                requests.AddRange(chrome.Select(p => new CloseRequest(p.Id, p.Name, "the Focus extension isn't responding")));
        }
        return requests;
    }
}
