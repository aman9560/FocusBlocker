using System.Text.Json;
using FocusBlocker.Core;

const int MaxMessageBytes = 1024 * 1024;
var store = new StateStore();
var input = Console.OpenStandardInput();
var output = Console.OpenStandardOutput();
var writeLock = new object();
string lastRevision = "";
var revisionLock = new object();

void Send(Dictionary<string, object?> message)
{
    var body = JsonSerializer.SerializeToUtf8Bytes(message);
    if (body.Length > MaxMessageBytes) return;
    var header = BitConverter.GetBytes(body.Length);
    lock (writeLock)
    {
        output.Write(header);
        output.Write(body);
        output.Flush();
    }
}

// Sends the current policy when it changed, or when the extension reports rules that don't match ours (for example
// after it reloaded). A busy or briefly unreadable state file must not take the host down: the extension keeps its
// current rules and the next poll tries again.
void SendPolicy(bool force = false, string? extensionRevision = null)
{
    try
    {
        var policy = store.CreatePolicy();
        var revision = policy["revision"]?.ToString() ?? "";
        lock (revisionLock)
        {
            if (!force && revision == lastRevision && (extensionRevision is null || extensionRevision == revision)) return;
            lastRevision = revision;
        }
        Send(policy);
    }
    catch (Exception error)
    {
        Console.Error.WriteLine("Focus Blocker native host: could not read policy: " + error.Message);
    }
}

using var timer = new Timer(_ => SendPolicy(), null, TimeSpan.FromSeconds(2), TimeSpan.FromSeconds(2));
try
{
    while (true)
    {
        var header = ReadExactly(input, 4);
        if (header is null) break;
        var length = BitConverter.ToInt32(header);
        if (length < 0 || length > MaxMessageBytes) break;
        var body = ReadExactly(input, length);
        if (body is null) break;
        using var document = JsonDocument.Parse(body);
        var type = document.RootElement.TryGetProperty("type", out var typeNode) ? typeNode.GetString() : null;
        if (type is "hello" or "getPolicy") SendPolicy(force: true);
        else if (type == "heartbeat")
        {
            store.RecordExtensionHeartbeat();
            var reported = document.RootElement.TryGetProperty("rulesRevision", out var node) && node.ValueKind == JsonValueKind.String ? node.GetString() : null;
            SendPolicy(extensionRevision: reported);
        }
        else Send(new Dictionary<string, object?> { ["type"] = "error", ["message"] = "unknown message type" });
    }
}
catch (Exception error)
{
    Console.Error.WriteLine("Focus Blocker native host: " + error.Message);
    return 1;
}
return 0;

static byte[]? ReadExactly(Stream input, int length)
{
    var bytes = new byte[length];
    var offset = 0;
    while (offset < length)
    {
        var read = input.Read(bytes, offset, length - offset);
        if (read == 0) return offset == 0 ? null : throw new EndOfStreamException();
        offset += read;
    }
    return bytes;
}
