using System.Text.Json;
using FocusBlocker.Core;

const int MaxMessageBytes = 1024 * 1024;
var store = new StateStore();
var input = Console.OpenStandardInput();
var output = Console.OpenStandardOutput();
var writeLock = new object();
string lastRevision = "";

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

void SendPolicy()
{
    var policy = store.CreatePolicy();
    var revision = policy["revision"]?.ToString() ?? "";
    if (revision == lastRevision) return;
    lastRevision = revision;
    Send(policy);
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
        if (type is "hello" or "getPolicy") SendPolicy();
        else if (type is not "heartbeat") Send(new Dictionary<string, object?> { ["type"] = "error", ["message"] = "unknown message type" });
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
