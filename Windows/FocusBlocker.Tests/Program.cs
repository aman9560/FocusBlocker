using System.Collections.Concurrent;
using System.Diagnostics;
using System.Text.Json;
using FocusBlocker.Core;

// A small dependency-free runner (no NuGet packages), so the tests run anywhere .NET runs, including CI and macOS.
//   dotnet run --project Windows/FocusBlocker.Tests
var tests = new List<(string Name, Action Body)>();
void Test(string name, Action body) => tests.Add((name, body));
void Expect(bool condition, string message = "") { if (!condition) throw new Exception("expectation failed " + message); }
void ExpectEqual<T>(T expected, T actual, string message = "")
{
    if (!EqualityComparer<T>.Default.Equals(expected, actual)) throw new Exception($"expected [{expected}] but got [{actual}] {message}");
}
void ExpectThrows(Action body, string contains)
{
    try { body(); }
    catch (InvalidOperationException e) when (e.Message.Contains(contains, StringComparison.OrdinalIgnoreCase)) { return; }
    catch (Exception e) { throw new Exception($"threw [{e.Message}], expected one containing [{contains}]"); }
    throw new Exception($"did not throw, expected one containing [{contains}]");
}

Test("domain rules normalize loose input", () =>
{
    ExpectEqual("reddit.com/r/all", DomainRule.Parse("https://www.Reddit.com/r/all/?x=1#top")!.Text);
    ExpectEqual("example.org", DomainRule.Parse("*.example.org")!.Text);
    ExpectEqual("news.ycombinator.com", DomainRule.Parse("news.ycombinator.com:443/")?.Text ?? "", "port");
    ExpectEqual("youtube.com/shorts", DomainRule.Parse("YouTube.com/Shorts")!.Text);
    foreach (var bad in new[] { "", "exa mple.com", "..com", "a.com/x*y", "file://*.*", "file:///c:/x", "ftp://x.com" })
        Expect(DomainRule.Parse(bad) is null, $"[{bad}] should be rejected");
});

Test("the all-websites rule is understood in every spelling Cold Turkey and users use", () =>
{
    foreach (var raw in new[] { "*", "*.*", "*/", "*.*/", "  *.*  " })
        Expect(DomainRule.Parse(raw)?.IsAll == true, $"[{raw}] should mean all websites");
});

Test("a wildcard-free site never turns into all-websites", () =>
{
    Expect(DomainRule.Parse("x.com/*")?.Text == "x.com", "trailing /* means the whole site");
    Expect(DomainRule.Parse("x.com")?.IsAll == false);
});

Test("rules cover subdomains and path segments only", () =>
{
    var host = DomainRule.Parse("reddit.com")!;
    Expect(host.Covers(DomainRule.Parse("old.reddit.com")!));
    Expect(!host.Covers(DomainRule.Parse("notreddit.com")!));
    var path = DomainRule.Parse("youtube.com/shorts")!;
    Expect(path.Covers(DomainRule.Parse("m.youtube.com/shorts/abc")!));
    Expect(!path.Covers(DomainRule.Parse("youtube.com/shortstack")!));
    Expect(!path.Covers(DomainRule.Parse("youtube.com")!));
    Expect(DomainRule.Parse("*")!.Covers(DomainRule.Parse("anything.com")!));
});

Test("normalizing rule lists dedupes, sorts and drops non-websites", () =>
{
    var rules = StateStore.NormalizeRules(["https://www.x.com/", "x.com", "file://*.*", "B.com", "a.com"]);
    ExpectEqual("a.com,b.com,x.com", string.Join(",", rules));
});

Test("app names are normalized and system processes can't be blocked", () =>
{
    var apps = StateStore.NormalizeApps(["C:\\Program Files\\Slack\\slack.exe", "Discord.exe", "explorer", "winlogon.exe", "FocusBlocker.App", "focusblocker", "slack"]);
    ExpectEqual("Discord,slack", string.Join(",", apps));
});

Test("passwords are salted and verified", () =>
{
    var a = StateStore.MakePassword("correct horse");
    var b = StateStore.MakePassword("correct horse");
    Expect(a.Salt != b.Salt && a.Hash != b.Hash);
    Expect(StateStore.VerifyPassword("correct horse", a));
    Expect(!StateStore.VerifyPassword("correct horsE", a));
});


// ---- state engine --------------------------------------------------------------------------------------------

StateStore Fresh()
{
    var dir = Path.Combine(Path.GetTempPath(), "focusblocker-tests-" + Guid.NewGuid().ToString("N"));
    Environment.SetEnvironmentVariable("FOCUSBLOCKER_STATE_DIR", dir);
    return new StateStore();
}

Test("an all-websites list becomes an allowlist and compiles to Chrome rules", () =>
{
    var store = Fresh();
    var list = store.CreateBlocklist("Distractions", ["*.*", "google.com", "youtube.com", "file://*.*"],
        ["docs.google.com", "mail.google.com", "chat.openai.com", "file://*"], []);
    ExpectEqual("*,google.com,youtube.com", string.Join(",", list.Domains));
    ExpectEqual("chat.openai.com,docs.google.com,mail.google.com", string.Join(",", list.Exceptions));
    store.StartSession([list.Id], 30, SessionLock.None, true);
    var policy = store.CreatePolicy();
    Expect((bool)policy["active"]! && (bool)policy["strict"]!);
    ExpectEqual("*", ((List<string>)policy["domains"]!)[0]);
    var rules = (List<Dictionary<string, object?>>)policy["rules"]!;
    ExpectEqual(12, rules.Count, "2 per site rule (3) + allow and allowAllRequests per exception (3)");
    ExpectEqual(3, rules.Count(r => (string)((Dictionary<string, object?>)r["action"]!)["type"]! == "allowAllRequests"));
    var first = (Dictionary<string, object?>)rules[0]["condition"]!;
    ExpectEqual("|http", (string)first["urlFilter"]!);
});

Test("timer-locked sessions can't be stopped, but the failsafe ends them and keeps everything", () =>
{
    var store = Fresh();
    var list = store.CreateBlocklist("Web", ["x.com"], ["x.com/ok"], ["slack"]);
    store.SetPassword("partner-secret", null);
    store.StartSession([list.Id], 60, SessionLock.Timer, true);
    ExpectThrows(() => store.StopSessions("partner-secret"), "timer-locked");
    ExpectEqual(1, store.Load().Sessions.Count(s => s.IsActive));

    ExpectEqual(1, store.EndSessionsWithFailsafe());
    var state = store.Load();
    Expect(!state.Sessions.Any(s => s.IsActive) && state.Sessions[0].EndReason == "failsafe");
    ExpectEqual(1, state.Blocklists.Count);
    Expect(state.AccountabilityPassword is not null, "password kept");
    Expect(state.Activity.Any(a => a.Event == "session.failsafe_ended"));
    ExpectEqual(0, store.EndSessionsWithFailsafe(), "nothing left to end");
});

Test("password locks need the password and lock out after three wrong attempts", () =>
{
    var store = Fresh();
    var list = store.CreateBlocklist("Web", ["x.com"], [], []);
    ExpectThrows(() => store.StartSession([list.Id], 30, SessionLock.Password, true), "set an accountability password");
    store.SetPassword("partner-secret", null);
    store.StartSession([list.Id], 30, SessionLock.Password, true);
    for (var i = 0; i < 3; i++) ExpectThrows(() => store.StopSessions("guess"), "incorrect");
    ExpectThrows(() => store.StopSessions("partner-secret"), "locked for another");
    Expect(store.Load().PasswordLockedUntilUtc is not null, "lockout survives a reload");
    ExpectThrows(() => store.SetPassword("new-secret-1", "partner-secret"), "strict session");
});

Test("strict sessions only allow edits that block more", () =>
{
    var store = Fresh();
    var list = store.CreateBlocklist("Social", ["reddit.com", "x.com"], ["reddit.com/r/swift"], []);
    store.StartSession([list.Id], 30, SessionLock.Timer, true);
    var edit = (Blocklist l) => new Blocklist { Id = l.Id, Name = l.Name, Domains = [..l.Domains], Exceptions = [..l.Exceptions], ProcessNames = [..l.ProcessNames] };

    var more = edit(list); more.Domains.Add("youtube.com");
    store.UpdateBlocklist(more);
    var fewer = edit(more); fewer.Domains.Remove("x.com");
    ExpectThrows(() => store.UpdateBlocklist(fewer), "cannot remove");
    var exception = edit(more); exception.Exceptions.Add("reddit.com/r/macos");
    ExpectThrows(() => store.UpdateBlocklist(exception), "cannot add exceptions");
    ExpectThrows(() => store.DeleteBlocklist(list.Id), "active session");
    ExpectThrows(() => store.ImportBlocklists([("Other", ["a.com"], Array.Empty<string>())]), "strict session");
});

Test("a schedule starts a session once per occurrence", () =>
{
    var store = Fresh();
    var list = store.CreateBlocklist("Work", ["news.com"], [], []);
    // Start and end both at midnight UTC mean a full 24-hour window every day, so one is open right now.
    store.UpsertSchedule(new ScheduleRule { Name = "always", BlocklistIds = [list.Id], Weekdays = [0, 1, 2, 3, 4, 5, 6],
        StartMinute = 0, EndMinute = 0, TimeZoneId = "UTC", Lock = "Timer", Strict = true });
    ExpectEqual(1, store.Load().Sessions.Count(s => s.IsActive && s.ScheduleId is not null));
    store.EndSessionsWithFailsafe();
    store.Tick();
    ExpectEqual(0, store.Load().Sessions.Count(s => s.IsActive), "doesn't restart within the same occurrence");
    ExpectThrows(() => store.UpsertSchedule(new ScheduleRule { Name = "ALWAYS", BlocklistIds = [list.Id], Weekdays = [1], StartMinute = 0, EndMinute = 60 }), "already exists");
});

Test("ticking without changes doesn't rewrite the state file", () =>
{
    var store = Fresh();
    store.CreateBlocklist("A", ["a.com"], [], []);
    var written = File.GetLastWriteTimeUtc(StateStore.StatePath);
    Thread.Sleep(50);
    for (var i = 0; i < 5; i++) { store.Tick(); store.CreatePolicy(); }
    ExpectEqual(written, File.GetLastWriteTimeUtc(StateStore.StatePath), "idle ticks must not save");
    store.RecordActivity("app.closed", "slack: test");
    Expect(File.GetLastWriteTimeUtc(StateStore.StatePath) > written, "real changes still save");
});

Test("importing a Cold Turkey export and plain lists", () =>
{
    var export = """{"blocks":{"Distractions":{"web":["bsky.app","https://www.reddit.com/","*.*"],"exceptions":["file://*.*","reddit.com/r/swift"]},"Empty":{"web":[]}}}""";
    var blocks = BlocklistImporter.Parse(export, "fallback").ToList();
    ExpectEqual(1, blocks.Count);
    ExpectEqual("Distractions", blocks[0].Name);
    var store = Fresh();
    store.ImportBlocklists(blocks);
    var list = store.Load().Blocklists.Single();
    ExpectEqual("*,bsky.app,reddit.com", string.Join(",", list.Domains));
    ExpectEqual("reddit.com/r/swift", string.Join(",", list.Exceptions));

    var plain = BlocklistImporter.Parse("# my sites\r\nnews.ycombinator.com, x.com\r\n\r\ninstagram.com", "Mine").Single();
    ExpectEqual("Mine", plain.Name);
    ExpectEqual(3, plain.Domains.Count());
    var encoded = false;
    try { BlocklistImporter.Parse("CTB178C337275757A857A807F727D", "x"); } catch (InvalidDataException) { encoded = true; }
    Expect(encoded, "encoded Cold Turkey files are refused");
});

// ---- the real Chrome native messaging host process ------------------------------------------------------------

Test("the real host process speaks Chrome's native messaging protocol", () =>
{
    var store = Fresh();
    var list = store.CreateBlocklist("Social", ["reddit.com", "youtube.com/shorts"], [], []);

    var baseDir = AppContext.BaseDirectory;
    var hostDll = new[] { "Release", "Debug" }
        .Select(c => Path.GetFullPath(Path.Combine(baseDir, "..", "..", "..", "..", "FocusBlocker.NativeHost", "bin", c, "net10.0", "FocusBlocker.NativeHost.dll")))
        .FirstOrDefault(File.Exists) ?? throw new Exception("host build output not found");
    var start = new ProcessStartInfo("dotnet", $"\"{hostDll}\" chrome-extension://mchnpkbnifalondddkmcbplnlebaebmd/")
    { RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true, UseShellExecute = false };
    start.Environment["FOCUSBLOCKER_STATE_DIR"] = StateStore.DirectoryPath;
    using var host = Process.Start(start)!;

    var messages = new BlockingCollection<JsonElement>();
    new Thread(() =>
    {
        var stream = host.StandardOutput.BaseStream;
        byte[]? Read(int n)
        {
            var buffer = new byte[n]; var offset = 0;
            while (offset < n) { var got = stream.Read(buffer, offset, n - offset); if (got == 0) return null; offset += got; }
            return buffer;
        }
        while (Read(4) is { } header && Read(BitConverter.ToInt32(header)) is { } body) messages.Add(JsonDocument.Parse(body).RootElement.Clone());
    }) { IsBackground = true }.Start();

    void Send(object message)
    {
        var body = JsonSerializer.SerializeToUtf8Bytes(message);
        host.StandardInput.BaseStream.Write(BitConverter.GetBytes(body.Length));
        host.StandardInput.BaseStream.Write(body);
        host.StandardInput.BaseStream.Flush();
    }
    JsonElement? Next(int milliseconds) => messages.TryTake(out var message, milliseconds) ? message : null;

    Send(new { type = "hello", version = "0.1.0", incognitoAllowed = false, rulesRevision = "", ruleCount = 0 });
    var first = Next(15000) ?? throw new Exception("no reply to hello");
    ExpectEqual("policy", first.GetProperty("type").GetString());
    Expect(!first.GetProperty("active").GetBoolean(), "no session yet");

    var timer = Stopwatch.StartNew();
    store.StartSession([list.Id], 30, SessionLock.Timer, true);
    var pushed = Next(15000) ?? throw new Exception("session start wasn't pushed to the extension");
    Expect(pushed.GetProperty("active").GetBoolean() && pushed.GetProperty("strict").GetBoolean());
    ExpectEqual(4, pushed.GetProperty("rules").GetArrayLength());
    ExpectEqual("reddit.com", pushed.GetProperty("domains")[0].GetString());
    Expect(timer.Elapsed < TimeSpan.FromSeconds(10), $"pushed in {timer.Elapsed.TotalSeconds:0.0}s");

    var revision = pushed.GetProperty("revision").GetString();
    Send(new { type = "heartbeat", version = "0.1.0", incognitoAllowed = false, rulesRevision = revision, ruleCount = 4 });
    Thread.Sleep(500);
    Expect(store.Load().ExtensionHeartbeatUtc is not null, "heartbeat recorded");
    Expect(Next(300) is null, "matching rules aren't re-sent");

    Send(new { type = "heartbeat", version = "0.1.0", rulesRevision = "stale", ruleCount = 0 });
    ExpectEqual("policy", (Next(5000) ?? throw new Exception("stale rules weren't corrected")).GetProperty("type").GetString());

    Send(new { type = "nonsense" });
    ExpectEqual("error", (Next(5000) ?? throw new Exception("no error reply")).GetProperty("type").GetString());

    host.StandardInput.Close();
    Expect(host.WaitForExit(10000), "host exits when Chrome closes the port");
    ExpectEqual(0, host.ExitCode);
});

// ---- process closing -----------------------------------------------------------------------------------------

var T0 = new DateTimeOffset(2026, 10, 28, 12, 0, 0, TimeSpan.Zero);

FocusState Session(bool strict, bool websites = true, string[]? apps = null, bool closeOthers = true, DateTimeOffset? heartbeat = null)
{
    var list = new Blocklist { Name = "L", Domains = websites ? ["x.com"] : [], ProcessNames = [..(apps ?? [])] };
    var state = new FocusState { CloseOtherBrowsers = closeOthers, ExtensionHeartbeatUtc = heartbeat };
    state.Blocklists.Add(list);
    state.Sessions.Add(new FocusSession { BlocklistIds = [list.Id], StartedUtc = T0, EndsUtc = T0.AddHours(1), Strict = strict, Lock = "Timer" });
    return state;
}

RunningProcess P(string name, int id = 100, int startedSecondsAgo = 600) => new(id, name, T0.AddSeconds(-startedSecondsAgo));

Test("blocked apps and, in strict web sessions, other browsers are closed", () =>
{
    var state = Session(strict: true, apps: ["slack"], heartbeat: T0);
    var running = new[] { P("slack", 1), P("Firefox", 2), P("msedge", 3), P("notepad", 4), P("chrome", 5) };
    var closed = ProcessGuard.Plan(state, T0, running, chromeHostInstalled: true, ownProcessId: 999).Select(r => r.Name).ToList();
    ExpectEqual("Firefox,msedge,slack", string.Join(",", closed.Order()), "Chrome is healthy, notepad is unrelated");

    var lenient = ProcessGuard.Plan(Session(strict: false, apps: ["slack"], heartbeat: T0), T0, running, true, 999).Select(r => r.Name);
    ExpectEqual("slack", string.Join(",", lenient), "non-strict sessions leave browsers alone");
    var appsOnly = ProcessGuard.Plan(Session(strict: true, websites: false, apps: ["slack"]), T0, running, true, 999).Select(r => r.Name);
    ExpectEqual("slack", string.Join(",", appsOnly), "no website rules, so browsers stay");
    var off = ProcessGuard.Plan(Session(strict: true, apps: ["slack"], closeOthers: false, heartbeat: T0), T0, running, true, 999).Select(r => r.Name);
    ExpectEqual("slack", string.Join(",", off));
});

Test("nothing is closed without an active session", () =>
{
    var state = Session(strict: true, apps: ["slack"]);
    Expect(ProcessGuard.Plan(state, T0.AddHours(2), [P("slack")], true, 999).Count == 0, "session already over");
    state.Sessions[0].EndedUtc = T0;
    Expect(ProcessGuard.Plan(state, T0, [P("slack")], true, 999).Count == 0, "session ended early");
});

Test("system processes and FocusBlocker itself are never closed", () =>
{
    var state = Session(strict: true, apps: ["explorer", "FocusBlocker.App", "slack"], heartbeat: T0);
    var closed = ProcessGuard.Plan(state, T0, [P("explorer", 1), P("FocusBlocker.App", 2), P("slack", 3, 5), P("slack", 4)], true, ownProcessId: 4)
        .Select(r => r.Id).ToList();
    ExpectEqual("3", string.Join(",", closed), "only the other slack process, not our own or protected ones");
    Expect(StateStore.NormalizeApps(["explorer.exe", "FocusBlocker.App.exe", "slack.exe"]).SequenceEqual(["slack"]));
});

Test("Chrome gets a start-up grace period and is only closed when the extension stops responding", () =>
{
    var fresh = T0.AddSeconds(-5);
    bool Closes(DateTimeOffset? heartbeat, int startedSecondsAgo, bool host = true, bool strict = true) =>
        ProcessGuard.Plan(Session(strict, heartbeat: heartbeat), T0, [P("chrome", 1, startedSecondsAgo), P("chrome", 2, startedSecondsAgo - 3)], host, 999).Count > 0;

    Expect(!Closes(null, startedSecondsAgo: 10), "just launched: the extension is still starting");
    Expect(!Closes(T0.AddMinutes(-10), startedSecondsAgo: 20), "old heartbeat from an earlier run, but still within the grace period");
    Expect(Closes(null, startedSecondsAgo: 60), "no heartbeat after the grace period");
    Expect(Closes(T0.AddMinutes(-10), startedSecondsAgo: 3600), "stale heartbeat");
    Expect(!Closes(fresh, startedSecondsAgo: 3600), "healthy extension");
    Expect(!Closes(T0.AddSeconds(-20), startedSecondsAgo: 15), "heartbeat older than this Chrome, but it is still starting");
    Expect(!Closes(null, startedSecondsAgo: 3600, host: false), "never before the Chrome host is installed");
    Expect(!Closes(null, startedSecondsAgo: 3600, strict: false), "only strict sessions");
});

Test("a heartbeat from before this Chrome started doesn't count", () =>
{
    // Chrome restarted 40 s ago; the last heartbeat is 44 s old (not stale yet) but predates this Chrome.
    var state = Session(strict: true, heartbeat: T0.AddSeconds(-44));
    var requests = ProcessGuard.Plan(state, T0, [P("chrome", 1, 40)], true, 999);
    ExpectEqual(1, requests.Count);
    ExpectEqual("the Focus extension isn't responding", requests[0].Reason);
    // The new Chrome reported 10 s ago, after it started.
    var healthy = Session(strict: true, heartbeat: T0.AddSeconds(-10));
    ExpectEqual(0, ProcessGuard.Plan(healthy, T0, [P("chrome", 1, 40)], true, 999).Count);
});

return Run();

int Run()
{
    var failed = 0;
    foreach (var (name, body) in tests)
    {
        try { body(); Console.WriteLine("✓ " + name); }
        catch (Exception e) { failed++; Console.WriteLine($"✗ {name}\n    {e.Message}"); }
    }
    Console.WriteLine($"\n{tests.Count - failed}/{tests.Count} passed");
    return failed == 0 ? 0 : 1;
}
