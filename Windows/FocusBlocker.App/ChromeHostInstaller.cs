using System.IO;
using System.Text.Json;
using FocusBlocker.Core;
using Microsoft.Win32;

namespace FocusBlocker.App;

/// <summary>Registers the Chrome native messaging host for the current Windows account. Used by the app's button and by --install-host.</summary>
public static class ChromeHostInstaller
{
    /// <summary>Pinned by the "key" in the extension's manifest.json.</summary>
    public const string ExtensionId = "mchnpkbnifalondddkmcbplnlebaebmd";
    private const string HostName = "com.focusblocker.nmh";

    /// <summary>Copies the host out of the app folder, writes its manifest and points Chrome at it. Returns the manifest path.</summary>
    public static string Install()
    {
        // The release is a single-file app published with IncludeAllContentForSelfExtract, so AppContext.BaseDirectory is the
        // temporary extraction folder, not the install folder that holds "host". The running exe's own folder is.
        var appFolder = Path.GetDirectoryName(Environment.ProcessPath) ?? AppContext.BaseDirectory;
        var source = Path.Combine(appFolder, "host");
        var executable = Path.Combine(source, "FocusBlocker.NativeHost.exe");
        if (!File.Exists(executable)) throw new FileNotFoundException("The host folder is missing. Use the complete Windows release ZIP.", executable);

        var install = Path.Combine(StateStore.DirectoryPath, "native-host");
        Directory.CreateDirectory(install);
        foreach (var file in Directory.GetFiles(source)) File.Copy(file, Path.Combine(install, Path.GetFileName(file)), overwrite: true);

        var manifestPath = Path.Combine(StateStore.DirectoryPath, "native-host.json");
        var manifest = new
        {
            name = HostName,
            description = "FocusBlocker Chrome native messaging host",
            path = Path.Combine(install, "FocusBlocker.NativeHost.exe"),
            type = "stdio",
            allowed_origins = new[] { $"chrome-extension://{ExtensionId}/" }
        };
        File.WriteAllText(manifestPath, JsonSerializer.Serialize(manifest, new JsonSerializerOptions { WriteIndented = true }));
        using var key = Registry.CurrentUser.CreateSubKey($@"Software\Google\Chrome\NativeMessagingHosts\{HostName}");
        key.SetValue(null, manifestPath, RegistryValueKind.String);
        return manifestPath;
    }
}
