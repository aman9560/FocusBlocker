using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace FocusBlocker.Core;

public sealed class FocusState
{
    public bool SessionActive { get; set; }
    public bool Strict { get; set; }
    public DateTimeOffset? SessionEndsUtc { get; set; }
    public List<string> Domains { get; set; } = [];
    public List<string> Exceptions { get; set; } = [];
    public List<string> ProcessNames { get; set; } = [];
}

public sealed class StateStore
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = true,
        Converters = { new JsonStringEnumConverter() }
    };

    public static string DirectoryPath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "FocusBlocker");
    public static string StatePath => Path.Combine(DirectoryPath, "state.json");

    public FocusState Load()
    {
        try
        {
            if (!File.Exists(StatePath)) return new FocusState();
            return JsonSerializer.Deserialize<FocusState>(File.ReadAllText(StatePath), JsonOptions) ?? new FocusState();
        }
        catch
        {
            return new FocusState();
        }
    }

    public void Save(FocusState state)
    {
        Directory.CreateDirectory(DirectoryPath);
        var temp = StatePath + ".tmp";
        File.WriteAllText(temp, JsonSerializer.Serialize(state, JsonOptions), new UTF8Encoding(false));
        File.Move(temp, StatePath, overwrite: true);
    }

    public Dictionary<string, object?> CreatePolicy()
    {
        var state = Load();
        var active = state.SessionActive && state.SessionEndsUtc is { } end && end > DateTimeOffset.UtcNow;
        if (state.SessionActive && !active)
        {
            state.SessionActive = false;
            state.Strict = false;
            state.SessionEndsUtc = null;
            Save(state);
        }

        var domains = NormalizeMany(state.Domains);
        var exceptions = NormalizeMany(state.Exceptions);
        var rules = new List<Dictionary<string, object?>>();
        if (active)
        {
            var id = 1;
            foreach (var domain in domains)
                rules.Add(Rule(id++, 1, "block", domain));
            id = 1001;
            foreach (var domain in exceptions)
                rules.Add(Rule(id++, 2, "allow", domain));
        }

        var revisionInput = string.Join("\n", new[] { active.ToString(), state.Strict.ToString(),
            state.SessionEndsUtc?.ToUnixTimeMilliseconds().ToString() ?? "", string.Join(",", domains), string.Join(",", exceptions) });
        var revision = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(revisionInput))).ToLowerInvariant();
        return new Dictionary<string, object?>
        {
            ["type"] = "policy",
            ["protocol"] = 1,
            ["active"] = active,
            ["strict"] = active && state.Strict,
            ["revision"] = revision,
            ["estimatedEnd"] = active ? state.SessionEndsUtc!.Value.ToUnixTimeMilliseconds() : null,
            ["domains"] = active ? domains : [],
            ["exceptions"] = active ? exceptions : [],
            ["rules"] = rules
        };
    }

    public static List<string> NormalizeMany(IEnumerable<string> values) => values
        .Select(NormalizeDomain)
        .Where(value => value is not null)
        .Select(value => value!)
        .Distinct(StringComparer.OrdinalIgnoreCase)
        .Order(StringComparer.OrdinalIgnoreCase)
        .ToList();

    public static string? NormalizeDomain(string input)
    {
        var value = input.Trim();
        if (value.Length == 0 || value.StartsWith('#')) return null;
        if (value.StartsWith("*.", StringComparison.Ordinal)) value = value[2..];
        if (!value.Contains("://", StringComparison.Ordinal)) value = "https://" + value;
        if (!Uri.TryCreate(value, UriKind.Absolute, out var uri) || string.IsNullOrWhiteSpace(uri.Host)) return null;
        var host = uri.IdnHost.TrimEnd('.').ToLowerInvariant();
        if (host.Length == 0 || host.Contains(' ')) return null;
        return host;
    }

    private static Dictionary<string, object?> Rule(int id, int priority, string action, string domain) => new()
    {
        ["id"] = id,
        ["priority"] = priority,
        ["action"] = new Dictionary<string, object?> { ["type"] = action },
        ["condition"] = new Dictionary<string, object?> { ["urlFilter"] = "||" + domain + "^" }
    };
}
