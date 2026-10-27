using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace FocusBlocker.Core;

/// <summary>Versioned, per-user state and operations shared by the UI, Chrome host and background agent.</summary>
public sealed class StateStore
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = true,
        PropertyNameCaseInsensitive = true,
        Converters = { new JsonStringEnumConverter() }
    };
    private static readonly string MutexName = "Local\\FocusBlocker-" + Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(Environment.UserName)))[..16];

    public static string DirectoryPath => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "FocusBlocker");
    public static string StatePath => Path.Combine(DirectoryPath, "state.json");
    private static string KeyPath => Path.Combine(DirectoryPath, "activity.key");

    public FocusState Load() => Locked(LoadUnsafe);

    public T Update<T>(Func<FocusState, T> action)
    {
        return Locked(() =>
        {
            var state = LoadUnsafe();
            TickUnsafe(state, DateTimeOffset.UtcNow);
            try
            {
                var result = action(state);
                SaveUnsafe(state);
                return result;
            }
            catch
            {
                // Failed password attempts and their lockout state must survive the exception.
                SaveUnsafe(state);
                throw;
            }
        });
    }

    public void Update(Action<FocusState> action) => Update(state => { action(state); return true; });

    public void Tick()
    {
        Locked(() =>
        {
            var state = LoadUnsafe();
            TickUnsafe(state, DateTimeOffset.UtcNow);
            SaveUnsafe(state);
            return true;
        });
    }

    public void RecordExtensionHeartbeat() => Update(state => state.ExtensionHeartbeatUtc = DateTimeOffset.UtcNow);

    public Dictionary<string, object?> CreatePolicy()
    {
        return Update(state => PolicyUnsafe(state, DateTimeOffset.UtcNow));
    }

    public Blocklist CreateBlocklist(string name, IEnumerable<string> domains, IEnumerable<string> exceptions, IEnumerable<string> apps)
    {
        return Update(state =>
        {
            var title = name.Trim();
            if (title.Length == 0) throw new InvalidOperationException("Enter a blocklist name.");
            if (state.Blocklists.Any(b => b.Name.Equals(title, StringComparison.OrdinalIgnoreCase))) throw new InvalidOperationException("A blocklist with that name already exists.");
            var list = new Blocklist { Name = title, Domains = NormalizeRules(domains), Exceptions = NormalizeRules(exceptions), ProcessNames = NormalizeApps(apps) };
            state.Blocklists.Add(list);
            AddActivity(state, "blocklist.created", title);
            return list;
        });
    }

    public void UpdateBlocklist(Blocklist edited)
    {
        Update(state =>
        {
            var index = state.Blocklists.FindIndex(b => b.Id == edited.Id);
            if (index < 0) throw new InvalidOperationException("That blocklist no longer exists.");
            var old = state.Blocklists[index];
            var name = edited.Name.Trim();
            if (name.Length == 0) throw new InvalidOperationException("Enter a blocklist name.");
            if (state.Blocklists.Any(b => b.Id != old.Id && b.Name.Equals(name, StringComparison.OrdinalIgnoreCase))) throw new InvalidOperationException("A blocklist with that name already exists.");
            var updated = new Blocklist { Id = old.Id, Name = name, Domains = NormalizeRules(edited.Domains), Exceptions = NormalizeRules(edited.Exceptions), ProcessNames = NormalizeApps(edited.ProcessNames) };
            if (IsStrictList(state, old.Id))
            {
                if (!updated.Domains.ToHashSet(StringComparer.OrdinalIgnoreCase).IsSupersetOf(old.Domains)) throw new InvalidOperationException("A strict session is using this list. You can add blocked sites, but cannot remove any.");
                if (!updated.ProcessNames.ToHashSet(StringComparer.OrdinalIgnoreCase).IsSupersetOf(old.ProcessNames)) throw new InvalidOperationException("A strict session is using this list. You can add blocked apps, but cannot remove any.");
                if (!updated.Exceptions.ToHashSet(StringComparer.OrdinalIgnoreCase).IsSubsetOf(old.Exceptions)) throw new InvalidOperationException("A strict session is using this list. You cannot add exceptions.");
                if (updated.Name != old.Name) throw new InvalidOperationException("A strict session is using this list. You cannot rename it yet.");
            }
            state.Blocklists[index] = updated;
            AddActivity(state, "blocklist.updated", updated.Name);
            return true;
        });
    }

    public void DeleteBlocklist(Guid id)
    {
        Update(state =>
        {
            var list = state.Blocklists.FirstOrDefault(b => b.Id == id) ?? throw new InvalidOperationException("That blocklist no longer exists.");
            if (state.Sessions.Any(s => s.IsActive && s.BlocklistIds.Contains(id))) throw new InvalidOperationException("This blocklist is in an active session.");
            if (state.Schedules.Any(s => s.BlocklistIds.Contains(id))) throw new InvalidOperationException("A schedule uses this blocklist. Delete or edit that schedule first.");
            state.Blocklists.Remove(list);
            AddActivity(state, "blocklist.deleted", list.Name);
            return true;
        });
    }

    public FocusSession StartSession(IEnumerable<Guid> blocklistIds, int minutes, SessionLock sessionLock, bool strict)
    {
        return Update(state =>
        {
            var ids = blocklistIds.Distinct().ToList();
            if (ids.Count == 0 || ids.Any(id => state.Blocklists.All(b => b.Id != id))) throw new InvalidOperationException("Choose at least one existing blocklist.");
            if (minutes is < 1 or > 720) throw new InvalidOperationException("Session length must be between 1 and 720 minutes.");
            if (sessionLock == SessionLock.Password && state.AccountabilityPassword is null) throw new InvalidOperationException("Set an accountability password in Protection before choosing password lock.");
            var now = DateTimeOffset.UtcNow;
            var session = new FocusSession { BlocklistIds = ids, StartedUtc = now, EndsUtc = now.AddMinutes(minutes), Lock = sessionLock.ToString(), Strict = strict };
            state.Sessions.Add(session);
            AddActivity(state, "session.started", $"{string.Join(", ", state.Blocklists.Where(b => ids.Contains(b.Id)).Select(b => b.Name))}; {minutes} minutes; {session.Lock}; strict={strict}");
            return session;
        });
    }

    public void StopSessions(string? password)
    {
        Update(state =>
        {
            var active = state.Sessions.Where(s => s.IsActive).ToList();
            if (active.Count == 0) return true;
            if (active.Any(s => s.Lock == SessionLock.Timer.ToString())) throw new InvalidOperationException("A timer-locked session cannot end early.");
            if (active.Any(s => s.Lock == SessionLock.Password.ToString()))
            {
                if (state.PasswordLockedUntilUtc is { } until && until > DateTimeOffset.UtcNow) throw new InvalidOperationException($"Password entry is locked for another {(int)(until - DateTimeOffset.UtcNow).TotalSeconds} seconds.");
                if (state.AccountabilityPassword is null || !VerifyPassword(password ?? "", state.AccountabilityPassword))
                {
                    state.PasswordFailures++;
                    if (state.PasswordFailures >= 3)
                    {
                        var seconds = Math.Min(3600, 30 * Math.Pow(2, state.PasswordFailures - 3));
                        state.PasswordLockedUntilUtc = DateTimeOffset.UtcNow.AddSeconds(seconds);
                    }
                    AddActivity(state, "unlock.failed", $"failures={state.PasswordFailures}");
                    throw new InvalidOperationException("The accountability password is incorrect.");
                }
                state.PasswordFailures = 0;
                state.PasswordLockedUntilUtc = null;
            }
            foreach (var session in active)
            {
                session.EndedUtc = DateTimeOffset.UtcNow;
                session.EndReason = session.Lock == SessionLock.Password.ToString() ? "unlockedWithPassword" : "stoppedUnlocked";
            }
            AddActivity(state, "session.stopped", $"Ended {active.Count} active session(s).");
            return true;
        });
    }

    public int EndSessionsWithFailsafe()
    {
        var ended = 0;
        Update(state =>
        {
            var active = state.Sessions.Where(s => s.IsActive).ToList();
            foreach (var session in active)
            {
                session.EndedUtc = DateTimeOffset.UtcNow;
                session.EndReason = "failsafe";
            }
            ended = active.Count;
            if (ended > 0) AddActivity(state, "session.failsafe_ended", $"Ended {ended} active session(s); configuration preserved");
            return ended > 0;
        });
        return ended;
    }

    public void SetPassword(string password, string? currentPassword)
    {
        Update(state =>
        {
            if (state.Sessions.Any(s => s.IsActive && s.Strict)) throw new InvalidOperationException("You cannot change the accountability password during a strict session.");
            if (password.Length < 8) throw new InvalidOperationException("Use at least 8 characters for the accountability password.");
            if (state.AccountabilityPassword is { } current)
            {
                if (state.PasswordLockedUntilUtc is { } until && until > DateTimeOffset.UtcNow) throw new InvalidOperationException("Password changes are temporarily locked after failed attempts.");
                if (!VerifyPassword(currentPassword ?? "", current))
                {
                    state.PasswordFailures++;
                    if (state.PasswordFailures >= 3) state.PasswordLockedUntilUtc = DateTimeOffset.UtcNow.AddSeconds(Math.Min(3600, 30 * Math.Pow(2, state.PasswordFailures - 3)));
                    AddActivity(state, "password.change.failed", "");
                    throw new InvalidOperationException("The current password is incorrect.");
                }
            }
            state.AccountabilityPassword = MakePassword(password);
            state.PasswordFailures = 0;
            state.PasswordLockedUntilUtc = null;
            AddActivity(state, currentPassword is null ? "password.set" : "password.changed", "");
            return true;
        });
    }

    public void UpsertSchedule(ScheduleRule rule)
    {
        Update(state =>
        {
            ValidateSchedule(state, rule);
            var index = state.Schedules.FindIndex(s => s.Id == rule.Id);
            if (index >= 0)
            {
                var old = state.Schedules[index];
                if (state.Sessions.Any(s => s.IsActive && s.Strict) && !NoWeakerThan(rule, old)) throw new InvalidOperationException("An active strict session prevents weakening this schedule.");
                state.Schedules[index] = rule;
            }
            else
            {
                if (state.Schedules.Any(s => s.Name.Equals(rule.Name, StringComparison.OrdinalIgnoreCase))) throw new InvalidOperationException("A schedule with that name already exists.");
                state.Schedules.Add(rule);
            }
            AddActivity(state, "schedule.saved", rule.Name);
            return true;
        });
        Tick();
    }

    public void DeleteSchedule(Guid id)
    {
        Update(state =>
        {
            var rule = state.Schedules.FirstOrDefault(s => s.Id == id) ?? throw new InvalidOperationException("That schedule no longer exists.");
            if (state.Sessions.Any(s => s.IsActive && s.Strict) && rule.Enabled) throw new InvalidOperationException("An active strict session prevents disabling or deleting schedules.");
            state.Schedules.Remove(rule);
            state.LastScheduledOccurrences.Remove(id);
            AddActivity(state, "schedule.deleted", rule.Name);
            return true;
        });
    }

    public void ImportBlocklists(IEnumerable<(string Name, IEnumerable<string> Domains, IEnumerable<string> Exceptions)> imported)
    {
        Update(state =>
        {
            if (state.Sessions.Any(s => s.IsActive && s.Strict)) throw new InvalidOperationException("Blocklists cannot be imported during a strict session.");
            foreach (var item in imported)
            {
                var name = item.Name.Trim();
                if (name.Length == 0) name = "Imported";
                var existing = state.Blocklists.FirstOrDefault(b => b.Name.Equals(name, StringComparison.OrdinalIgnoreCase));
                if (existing is null) state.Blocklists.Add(new Blocklist { Name = name, Domains = NormalizeRules(item.Domains), Exceptions = NormalizeRules(item.Exceptions) });
                else
                {
                    existing.Domains = NormalizeRules(existing.Domains.Concat(item.Domains));
                    existing.Exceptions = NormalizeRules(existing.Exceptions.Concat(item.Exceptions));
                }
                AddActivity(state, "blocklist.imported", name);
            }
            return true;
        });
    }

    public List<ActivityEntry> ReadActivity() => Load().Activity.OrderByDescending(a => a.Sequence).Take(500).ToList();

    public static List<string> NormalizeMany(IEnumerable<string> values) => NormalizeRules(values);

    public static string? NormalizeDomain(string input) => DomainRule.Parse(input)?.Text;

    public static List<string> NormalizeRules(IEnumerable<string> rules) => rules.Select(DomainRule.Parse).Where(r => r is not null).Select(r => r!.Text)
        .Distinct(StringComparer.OrdinalIgnoreCase).Order(StringComparer.OrdinalIgnoreCase).ToList();

    public static List<string> NormalizeApps(IEnumerable<string> names) => names.Select(n => Path.GetFileNameWithoutExtension(n)).Where(n => !string.IsNullOrWhiteSpace(n))
        .Select(n => n!.Trim()).Where(n => !new[] { "csrss", "dwm", "explorer", "lsass", "services", "smss", "wininit", "winlogon", "focusblocker" }.Contains(n, StringComparer.OrdinalIgnoreCase))
        .Distinct(StringComparer.OrdinalIgnoreCase).Order(StringComparer.OrdinalIgnoreCase).ToList();

    public static PasswordRecord MakePassword(string password)
    {
        var salt = RandomNumberGenerator.GetBytes(16);
        var hash = Rfc2898DeriveBytes.Pbkdf2(Encoding.UTF8.GetBytes(password), salt, 600_000, HashAlgorithmName.SHA256, 32);
        return new PasswordRecord { Salt = Convert.ToBase64String(salt), Hash = Convert.ToBase64String(hash), Iterations = 600_000 };
    }

    public static bool VerifyPassword(string password, PasswordRecord record)
    {
        try
        {
            var hash = Rfc2898DeriveBytes.Pbkdf2(Encoding.UTF8.GetBytes(password), Convert.FromBase64String(record.Salt), record.Iterations, HashAlgorithmName.SHA256, 32);
            return CryptographicOperations.FixedTimeEquals(hash, Convert.FromBase64String(record.Hash));
        }
        catch { return false; }
    }

    public static bool NoWeakerThan(ScheduleRule next, ScheduleRule old)
    {
        if (!old.Enabled) return true;
        return next.Enabled && next.BlocklistIds.ToHashSet().IsSupersetOf(old.BlocklistIds)
            && next.Weekdays.ToHashSet().IsSupersetOf(old.Weekdays) && next.StartMinute == old.StartMinute && next.EndMinute == old.EndMinute
            && next.TimeZoneId == old.TimeZoneId && LockStrength(next.Lock) >= LockStrength(old.Lock) && (next.Strict || !old.Strict);
    }

    private static int LockStrength(string value) => value switch { "Timer" => 2, "Password" => 1, _ => 0 };

    private FocusState LoadUnsafe()
    {
        try
        {
            if (!File.Exists(StatePath)) return new FocusState();
            var state = JsonSerializer.Deserialize<FocusState>(File.ReadAllText(StatePath), JsonOptions) ?? new FocusState();
            state.Blocklists ??= []; state.Sessions ??= []; state.Schedules ??= []; state.Activity ??= []; state.LastScheduledOccurrences ??= [];
            state.Domains ??= []; state.Exceptions ??= []; state.ProcessNames ??= [];
            if (state.Blocklists.Count == 0 && (state.Domains.Count > 0 || state.Exceptions.Count > 0 || state.ProcessNames.Count > 0))
            {
                var list = new Blocklist { Name = "Imported from preview", Domains = NormalizeRules(state.Domains), Exceptions = NormalizeRules(state.Exceptions), ProcessNames = NormalizeApps(state.ProcessNames) };
                state.Blocklists.Add(list);
                if (state.SessionActive && state.SessionEndsUtc is { } end && end > DateTimeOffset.UtcNow)
                    state.Sessions.Add(new FocusSession { BlocklistIds = [list.Id], StartedUtc = DateTimeOffset.UtcNow, EndsUtc = end, Lock = state.Strict ? "Timer" : "None", Strict = state.Strict });
                AddActivity(state, "state.migrated", "Imported rules from the Windows preview state.");
                state.SchemaVersion = 2;
                SaveUnsafe(state);
            }
            return state;
        }
        catch (JsonException) { return new FocusState(); }
        catch (IOException) { return new FocusState(); }
    }

    private void SaveUnsafe(FocusState state)
    {
        Directory.CreateDirectory(DirectoryPath);
        var tmp = StatePath + ".tmp";
        File.WriteAllText(tmp, JsonSerializer.Serialize(state, JsonOptions), new UTF8Encoding(false));
        File.Move(tmp, StatePath, overwrite: true);
    }

    private static T Locked<T>(Func<T> operation)
    {
        using var mutex = new Mutex(false, MutexName);
        var held = false;
        try { try { held = mutex.WaitOne(TimeSpan.FromSeconds(30)); } catch (AbandonedMutexException) { held = true; }
            if (!held) throw new TimeoutException("Focus Blocker state is busy.");
            return operation();
        }
        finally { if (held) mutex.ReleaseMutex(); }
    }

    private static void AddActivity(FocusState state, string eventName, string detail)
    {
        try
        {
            Directory.CreateDirectory(DirectoryPath);
            var key = File.Exists(KeyPath) ? File.ReadAllBytes(KeyPath) : RandomNumberGenerator.GetBytes(32);
            if (!File.Exists(KeyPath)) File.WriteAllBytes(KeyPath, key);
            var previous = state.Activity.LastOrDefault()?.Mac ?? "";
            var entry = new ActivityEntry { Sequence = (state.Activity.LastOrDefault()?.Sequence ?? 0) + 1, TimeUtc = DateTimeOffset.UtcNow, Event = eventName, Detail = detail, PreviousMac = previous };
            var message = string.Join("\u001f", previous, entry.Sequence.ToString(CultureInfo.InvariantCulture), entry.TimeUtc.ToUnixTimeMilliseconds().ToString(CultureInfo.InvariantCulture), eventName, detail);
            entry.Mac = Convert.ToHexString(HMACSHA256.HashData(key, Encoding.UTF8.GetBytes(message))).ToLowerInvariant();
            state.Activity.Add(entry);
            if (state.Activity.Count > 500) state.Activity.RemoveRange(0, state.Activity.Count - 500);
        }
        catch { /* Activity recording must never prevent a session state transition. */ }
    }

    private static void TickUnsafe(FocusState state, DateTimeOffset now)
    {
        var changed = false;
        foreach (var session in state.Sessions.Where(s => s.EndedUtc is null && s.EndsUtc <= now))
        {
            session.EndedUtc = session.EndsUtc;
            session.EndReason = "completed";
            AddActivity(state, "session.completed", session.Id.ToString());
            changed = true;
        }
        if (state.PasswordLockedUntilUtc is { } lockEnd && lockEnd <= now) { state.PasswordLockedUntilUtc = null; changed = true; }

        foreach (var schedule in state.Schedules.Where(s => s.Enabled))
        {
            var window = ActiveWindow(schedule, now);
            if (window is null || state.LastScheduledOccurrences.GetValueOrDefault(schedule.Id) == window.Value.Start) continue;
            state.LastScheduledOccurrences[schedule.Id] = window.Value.Start;
            var ids = schedule.BlocklistIds.Where(id => state.Blocklists.Any(b => b.Id == id)).Distinct().ToList();
            if (ids.Count == 0 || (schedule.Lock == "Password" && state.AccountabilityPassword is null))
            {
                AddActivity(state, "schedule.skipped", schedule.Name + ": invalid or missing password configuration");
                changed = true;
                continue;
            }
            var ends = window.Value.End;
            if (ends <= now) continue;
            state.Sessions.Add(new FocusSession { BlocklistIds = ids, StartedUtc = now, EndsUtc = ends, Lock = schedule.Lock, Strict = schedule.Strict, ScheduleId = schedule.Id, OccurrenceStartUtc = window.Value.Start });
            AddActivity(state, "session.started", $"schedule {schedule.Name}");
            changed = true;
        }
        _ = changed;
    }

    private static (DateTimeOffset Start, DateTimeOffset End)? ActiveWindow(ScheduleRule rule, DateTimeOffset now)
    {
        TimeZoneInfo zone;
        try { zone = TimeZoneInfo.FindSystemTimeZoneById(rule.TimeZoneId); } catch { zone = TimeZoneInfo.Local; }
        var localNow = TimeZoneInfo.ConvertTime(now, zone);
        var today = DateTime.SpecifyKind(localNow.DateTime.Date, DateTimeKind.Unspecified);
        var duration = (rule.EndMinute - rule.StartMinute + 1440) % 1440;
        if (duration == 0) duration = 1440;
        for (var offset = -1; offset <= 0; offset++)
        {
            var day = today.AddDays(offset);
            if (!rule.Weekdays.Contains((int)day.DayOfWeek)) continue;
            var startLocal = day.AddMinutes(rule.StartMinute);
            var endLocal = startLocal.AddMinutes(duration);
            if (zone.IsInvalidTime(startLocal) || zone.IsInvalidTime(endLocal)) continue;
            var start = new DateTimeOffset(startLocal, zone.GetUtcOffset(startLocal)).ToUniversalTime();
            var end = new DateTimeOffset(endLocal, zone.GetUtcOffset(endLocal)).ToUniversalTime();
            if (start <= now && now < end) return (start, end);
        }
        return null;
    }

    private static void ValidateSchedule(FocusState state, ScheduleRule rule)
    {
        rule.Name = rule.Name.Trim();
        if (rule.Name.Length == 0 || rule.BlocklistIds.Count == 0 || rule.Weekdays.Count == 0 || rule.Weekdays.Any(d => d is < 0 or > 6)
            || rule.StartMinute is < 0 or >= 1440 || rule.EndMinute is < 0 or >= 1440) throw new InvalidOperationException("Enter a name, at least one blocklist and day, and valid times.");
        if (state.Blocklists.All(b => rule.BlocklistIds.All(id => id != b.Id))) throw new InvalidOperationException("Choose a blocklist that exists.");
        try { _ = TimeZoneInfo.FindSystemTimeZoneById(rule.TimeZoneId); } catch { rule.TimeZoneId = TimeZoneInfo.Local.Id; }
        if (rule.Lock == "Password" && state.AccountabilityPassword is null) throw new InvalidOperationException("Set an accountability password before creating a password-locked schedule.");
    }

    private static Dictionary<string, object?> PolicyUnsafe(FocusState state, DateTimeOffset now)
    {
        var active = state.Sessions.Where(s => s.EndedUtc is null && s.EndsUtc > now).ToList();
        var lists = state.Blocklists.Where(b => active.Any(s => s.BlocklistIds.Contains(b.Id))).ToList();
        var domains = lists.SelectMany(b => b.Domains).Select(DomainRule.Parse).Where(d => d is not null).Cast<DomainRule>().Distinct().OrderBy(d => d.Text).ToList();
        var rawExceptions = lists.SelectMany(b => b.Exceptions).Select(DomainRule.Parse).Where(d => d is not null).Cast<DomainRule>().Distinct();
        var exceptions = rawExceptions.Where(exception => lists.All(list =>
        {
            var listDomains = list.Domains.Select(DomainRule.Parse).Where(d => d is not null).Cast<DomainRule>().ToList();
            var affects = listDomains.Any(block => exception.Covers(block) || block.Covers(exception));
            if (!affects) return true;
            return list.Exceptions.Select(DomainRule.Parse).Where(d => d is not null).Cast<DomainRule>().Any(allowed => allowed.Covers(exception));
        })).OrderBy(d => d.Text).ToList();

        var rules = new List<Dictionary<string, object?>>();
        var id = 1;
        string[] subresourceTypes = ["sub_frame", "xmlhttprequest", "websocket", "media", "image", "script", "stylesheet", "font", "object", "ping", "other"];
        void Add(int priority, string action, Dictionary<string, object?> condition, string[] resourceTypes, string? extensionPath = null)
        {
            var act = new Dictionary<string, object?> { ["type"] = action };
            if (extensionPath is not null) act["redirect"] = new Dictionary<string, object?> { ["extensionPath"] = extensionPath };
            condition["resourceTypes"] = resourceTypes;
            rules.Add(new Dictionary<string, object?> { ["id"] = id++, ["priority"] = priority, ["action"] = act, ["condition"] = condition });
        }
        foreach (var rule in domains)
        {
            var condition = rule.IsAll ? new Dictionary<string, object?> { ["urlFilter"] = "|http" }
                : rule.Path is null ? new Dictionary<string, object?> { ["requestDomains"] = new[] { rule.Host } }
                : new Dictionary<string, object?> { ["urlFilter"] = $"||{rule.Host}{rule.Path}^" };
            if (rule.IsAll)
            {
                Add(1, "redirect", new Dictionary<string, object?>(condition), ["main_frame"], "/blocked.html");
                Add(1, "block", condition, ["sub_frame"]);
            }
            else
            {
                Add(1, "redirect", new Dictionary<string, object?>(condition), ["main_frame"], "/blocked.html");
                Add(1, "block", condition, subresourceTypes);
            }
        }
        var blocksAll = domains.Any(d => d.IsAll);
        foreach (var rule in exceptions)
        {
            var condition = rule.IsAll ? new Dictionary<string, object?> { ["urlFilter"] = "|http" }
                : rule.Path is null ? new Dictionary<string, object?> { ["requestDomains"] = new[] { rule.Host } }
                : new Dictionary<string, object?> { ["urlFilter"] = $"||{rule.Host}{rule.Path}^" };
            Add(2, "allow", new Dictionary<string, object?>(condition), ["main_frame", .. subresourceTypes]);
            if (blocksAll) Add(2, "allowAllRequests", condition, ["main_frame", "sub_frame"]);
        }

        var revisionInput = active.Select(s => s.Id.ToString()).Concat(domains.Select(d => d.Text)).Concat(exceptions.Select(d => d.Text));
        var revision = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(string.Join("\n", revisionInput)))).ToLowerInvariant();
        var end = active.Count == 0 ? (DateTimeOffset?)null : active.Max(s => s.EndsUtc);
        return new Dictionary<string, object?>
        {
            ["type"] = "policy", ["protocol"] = 1, ["active"] = active.Count > 0, ["strict"] = active.Any(s => s.Strict),
            ["revision"] = revision, ["estimatedEnd"] = end?.ToUnixTimeMilliseconds(),
            ["domains"] = active.Count > 0 ? domains.Select(d => d.Text).ToList() : [],
            ["exceptions"] = active.Count > 0 ? exceptions.Select(d => d.Text).ToList() : [], ["rules"] = rules
        };
    }

    public static bool IsStrictList(FocusState state, Guid id) => state.Sessions.Any(s => s.IsActive && s.Strict && s.BlocklistIds.Contains(id));

}
