using System.Text.Json;

namespace FocusBlocker.Core;

/// <summary>
/// Reads website rules from a file: a Cold Turkey JSON export (made with Cold Turkey's own "Export all blocks to
/// file…") or a plain list with one site per line. Encoded Cold Turkey files are refused with instructions.
/// </summary>
public static class BlocklistImporter
{
    public static IEnumerable<(string Name, IEnumerable<string> Domains, IEnumerable<string> Exceptions)> Parse(string contents, string fallbackName)
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
}
