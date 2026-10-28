# FocusBlocker installer for Windows 10/11 (x64). No administrator rights needed.
#
#   irm https://raw.githubusercontent.com/aman9560/FocusBlocker/main/install-windows.ps1 | iex
#
# Why this avoids the SmartScreen "Windows protected your PC" warning: that warning is triggered by the
# "downloaded from the internet" mark a web browser puts on files. Invoke-WebRequest doesn't add it, and this
# script also clears it from everything it installs. FocusBlocker isn't signed with a paid code-signing
# certificate, which is why a browser download is flagged; installing this way means there is nothing to bypass.
#
# Settings are environment variables, because "irm | iex" can't take parameters. For example, to install
# a ZIP you already have, without downloading:
#   $env:FOCUSBLOCKER_ZIP = "C:\path\FocusBlocker-Windows-x64.zip"; .\install-windows.ps1
#
#   FOCUSBLOCKER_ZIP              install this FocusBlocker-Windows-x64.zip instead of downloading
#   FOCUSBLOCKER_VERSION          a release tag such as v0.2.5 (default: latest)
#   FOCUSBLOCKER_DIR              install folder (default: %LOCALAPPDATA%\Programs\FocusBlocker)
#   FOCUSBLOCKER_NO_CHROME_HOST   set to 1 to skip registering the Chrome native messaging host
#   FOCUSBLOCKER_NO_LAUNCH        set to 1 to not start the app afterwards
#   FOCUSBLOCKER_FORCE            set to 1 to update even while a focus session is running

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
# Windows PowerShell 5.1 defaults to older TLS versions that GitHub refuses, and draws a very slow progress bar.
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$ProgressPreference = 'SilentlyContinue'

function Say([string]$Message) { Write-Host "==> $Message" -ForegroundColor Cyan }
function Setting([string]$Name, [string]$Default = '') {
    $value = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($value)) { return $Default }
    return $value
}

$repo = 'aman9560/FocusBlocker'
$version = Setting 'FOCUSBLOCKER_VERSION' 'latest'
$installDir = Setting 'FOCUSBLOCKER_DIR' (Join-Path $env:LOCALAPPDATA 'Programs\FocusBlocker')
$localZip = Setting 'FOCUSBLOCKER_ZIP'
$exeName = 'FocusBlocker.App.exe'

if (-not [Environment]::Is64BitOperatingSystem) { throw 'FocusBlocker for Windows needs a 64-bit version of Windows.' }

# Updating while a session runs would stop the background agent that enforces it, so refuse unless told otherwise.
function Test-ActiveSession {
    $statePath = Join-Path $env:LOCALAPPDATA 'FocusBlocker\state.json'
    if (-not (Test-Path $statePath)) { return $false }
    try {
        $state = Get-Content -Raw -Path $statePath | ConvertFrom-Json
        $now = [DateTimeOffset]::UtcNow
        foreach ($session in @($state.sessions)) {
            if ($null -ne $session.endedUtc) { continue }
            # PowerShell 7 returns dates as DateTime objects, Windows PowerShell 5.1 as text; handle both without
            # converting through a culture-specific string.
            $end = $session.endsUtc
            $endsAt = if ($end -is [datetime]) { [DateTimeOffset]$end } else { [DateTimeOffset]::Parse([string]$end, [Globalization.CultureInfo]::InvariantCulture) }
            if ($endsAt -gt $now) { return $true }
        }
    } catch { return $false }  # An unreadable state file must not block an update.
    return $false
}
if ((Test-ActiveSession) -and ((Setting 'FOCUSBLOCKER_FORCE') -ne '1')) {
    throw 'A FocusBlocker session is running. Finish it first (updating would stop its enforcement), or set $env:FOCUSBLOCKER_FORCE = "1" to update anyway.'
}

$work = Join-Path ([IO.Path]::GetTempPath()) ('focusblocker-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
try {
    # --- 1. Get the ZIP ---------------------------------------------------------------------------------------------
    $zip = Join-Path $work 'FocusBlocker-Windows-x64.zip'
    if ($localZip) {
        if (-not (Test-Path $localZip)) { throw "FOCUSBLOCKER_ZIP not found: $localZip" }
        Say "Installing $localZip"
        Copy-Item -Path $localZip -Destination $zip
    } else {
        $base = if ($version -eq 'latest') { "https://github.com/$repo/releases/latest/download" } else { "https://github.com/$repo/releases/download/$version" }
        Say "Downloading FocusBlocker ($version), about 90 MB"
        Invoke-WebRequest -UseBasicParsing -Uri "$base/FocusBlocker-Windows-x64.zip" -OutFile $zip
    }
    $extracted = Join-Path $work 'extracted'
    Expand-Archive -Path $zip -DestinationPath $extracted -Force
    if (-not (Test-Path (Join-Path $extracted $exeName))) { throw "The ZIP doesn't contain $exeName. Use the complete FocusBlocker-Windows-x64.zip." }

    # --- 2. Stop running copies (the window and the hidden background agent share one process name) -------------------
    $running = @(Get-Process -Name 'FocusBlocker.App' -ErrorAction SilentlyContinue)
    if ($running.Count -gt 0) {
        Say 'Closing the running FocusBlocker'
        foreach ($process in $running) { [void]$process.CloseMainWindow() }
        Start-Sleep -Seconds 3
        # The background agent has no window to close, so it is stopped directly. It starts again with the app.
        Get-Process -Name 'FocusBlocker.App' -ErrorAction SilentlyContinue | Stop-Process -Force
        Start-Sleep -Seconds 1
    }

    # --- 3. Replace the files. Blocklists, sessions and settings live in %LOCALAPPDATA%\FocusBlocker, which is untouched.
    if (Test-Path $installDir) { Remove-Item -Recurse -Force $installDir }
    New-Item -ItemType Directory -Path $installDir -Force | Out-Null
    Copy-Item -Path (Join-Path $extracted '*') -Destination $installDir -Recurse -Force

    # --- 4. Clear the "downloaded from the internet" mark so SmartScreen has nothing to warn about -------------------
    Get-ChildItem -Path $installDir -Recurse -File | Unblock-File
    $exe = Join-Path $installDir $exeName
    Say "Installed $installDir"

    # --- 5. Start Menu shortcut ----------------------------------------------------------------------------------------
    $programs = [Environment]::GetFolderPath('Programs')
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut((Join-Path $programs 'FocusBlocker.lnk'))
    $shortcut.TargetPath = $exe
    $shortcut.WorkingDirectory = $installDir
    $shortcut.Description = 'FocusBlocker'
    $shortcut.Save()

    # --- 6. Chrome native messaging host ---------------------------------------------------------------------------------
    if ((Setting 'FOCUSBLOCKER_NO_CHROME_HOST') -ne '1') {
        Say 'Registering the Chrome connection'
        $hostSetup = Start-Process -FilePath $exe -ArgumentList '--install-host' -Wait -PassThru
        if ($hostSetup.ExitCode -eq 0) { Write-Host '    Chrome can now talk to FocusBlocker.' }
        else { Write-Warning "Couldn't register the Chrome host. Open FocusBlocker and use 'Install Chrome host'." }
    }

    # --- 7. Done ------------------------------------------------------------------------------------------------------
    if ((Setting 'FOCUSBLOCKER_NO_LAUNCH') -ne '1') { Start-Process -FilePath $exe }
    Write-Host @"

FocusBlocker is installed. One thing remains, and Chrome requires you to do it yourself:

  To block websites in Chrome, open chrome://extensions, turn on Developer mode, click
  "Load unpacked", and choose:  $installDir\extension
  Then open the extension's Details and turn on "Allow in Incognito". Keep that folder in place.

  In FocusBlocker, open Protection to turn on the background agent, which closes blocked apps.
"@
}
finally {
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}
