using System.Text.Json.Serialization;

namespace FocusBlocker.Core;

public enum SessionLock { None, Timer, Password }

public sealed class Blocklist
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public string Name { get; set; } = "";
    public List<string> Domains { get; set; } = [];
    public List<string> Exceptions { get; set; } = [];
    public List<string> ProcessNames { get; set; } = [];
}

public sealed class FocusSession
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public List<Guid> BlocklistIds { get; set; } = [];
    public DateTimeOffset StartedUtc { get; set; }
    public DateTimeOffset EndsUtc { get; set; }
    public DateTimeOffset? EndedUtc { get; set; }
    public string EndReason { get; set; } = "";
    public string Lock { get; set; } = "Timer";
    public bool Strict { get; set; }
    public Guid? ScheduleId { get; set; }
    public DateTimeOffset? OccurrenceStartUtc { get; set; }
    [JsonIgnore] public bool IsActive => EndedUtc is null && EndsUtc > DateTimeOffset.UtcNow;
}

public sealed class ScheduleRule
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public string Name { get; set; } = "";
    public List<Guid> BlocklistIds { get; set; } = [];
    public List<int> Weekdays { get; set; } = [];
    public int StartMinute { get; set; }
    public int EndMinute { get; set; }
    public string TimeZoneId { get; set; } = TimeZoneInfo.Local.Id;
    public string Lock { get; set; } = "Timer";
    public bool Strict { get; set; } = true;
    public bool Enabled { get; set; } = true;
}

public sealed class PasswordRecord
{
    public string Salt { get; set; } = "";
    public string Hash { get; set; } = "";
    public int Iterations { get; set; } = 600_000;
}

public sealed class ActivityEntry
{
    public long Sequence { get; set; }
    public DateTimeOffset TimeUtc { get; set; }
    public string Event { get; set; } = "";
    public string Detail { get; set; } = "";
    public string PreviousMac { get; set; } = "";
    public string Mac { get; set; } = "";
}

public sealed class FocusState
{
    public int SchemaVersion { get; set; } = 2;
    public List<Blocklist> Blocklists { get; set; } = [];
    public List<FocusSession> Sessions { get; set; } = [];
    public List<ScheduleRule> Schedules { get; set; } = [];
    public Dictionary<Guid, DateTimeOffset> LastScheduledOccurrences { get; set; } = [];
    public PasswordRecord? AccountabilityPassword { get; set; }
    public int PasswordFailures { get; set; }
    public DateTimeOffset? PasswordLockedUntilUtc { get; set; }
    public bool AgentEnabled { get; set; }
    public bool CloseOtherBrowsers { get; set; } = true;
    public DateTimeOffset? ExtensionHeartbeatUtc { get; set; }
    public List<ActivityEntry> Activity { get; set; } = [];

    // v0.1.0 preview state migration fields.
    public bool SessionActive { get; set; }
    public bool Strict { get; set; }
    public DateTimeOffset? SessionEndsUtc { get; set; }
    public List<string> Domains { get; set; } = [];
    public List<string> Exceptions { get; set; } = [];
    public List<string> ProcessNames { get; set; } = [];
}

public sealed record DomainRule(string Host, string? Path)
{
    public bool IsAll => Host == "*";
    public string Text => Host + (Path ?? "");

    public static DomainRule? Parse(string raw)
    {
        var value = raw.Trim().ToLowerInvariant();
        if (value.Length == 0 || value.StartsWith('#')) return null;
        while (value.EndsWith("/*", StringComparison.Ordinal) || value.EndsWith('*'))
            value = value[..(value.EndsWith("/*", StringComparison.Ordinal) ? value.Length - 2 : value.Length - 1)];
        if (value is "*" or "*.*" or "*/" or "*.*/") return new DomainRule("*", null);
        var scheme = value.IndexOf("://", StringComparison.Ordinal);
        if (scheme >= 0)
        {
            var protocol = value[..scheme];
            if (protocol is not ("http" or "https")) return null;
            value = value[(scheme + 3)..];
        }
        var end = value.IndexOfAny(['?', '#']);
        if (end >= 0) value = value[..end];
        if (value.StartsWith("*.", StringComparison.Ordinal)) value = value[2..];
        var slash = value.IndexOf('/');
        var host = (slash < 0 ? value : value[..slash]).TrimEnd('.');
        var path = slash < 0 ? null : value[slash..].TrimEnd('/');
        if (host.StartsWith("www.", StringComparison.Ordinal)) host = host[4..];
        try { host = new System.Globalization.IdnMapping().GetAscii(host); } catch { return null; }
        if (host.Length == 0 || host.Contains(' ') || (!host.Contains('.') && host != "localhost") || host.Contains("..")) return null;
        if (path is { } p && (p.Contains('*') || p.Contains('^') || p.Contains('|') || p.Contains(' '))) return null;
        return new DomainRule(host, string.IsNullOrEmpty(path) ? null : path);
    }

    public bool Covers(DomainRule other)
    {
        if (IsAll) return true;
        if (!(other.Host == Host || other.Host.EndsWith("." + Host, StringComparison.Ordinal))) return false;
        if (Path is null) return true;
        return other.Path is not null && (other.Path == Path || other.Path.StartsWith(Path + "/", StringComparison.Ordinal));
    }
}
