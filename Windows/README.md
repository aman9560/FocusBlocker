# FocusBlocker for Windows

The Windows x64 app includes named website and application blocklists, exceptions and path rules, timed sessions, weekly schedules, timer/password locks, strict-session edit protection, an accountability password, blocklist import, recent activity history, Chrome website blocking, and an optional sign-in background agent.

## Install

1. Download and extract `FocusBlocker-Windows-x64.zip` to a folder you control.
2. Run `FocusBlocker.App.exe`.
3. In **Protection**, turn on the background agent if you want process enforcement and schedules to continue while the window is closed. It starts at sign-in for this Windows account.
4. To block sites in Chrome, use **Install Chrome host**, then open `chrome://extensions`, enable Developer mode, and choose **Load unpacked** to select the included `extension` folder.
5. Create one or more blocklists, choose them in **Focus session** or a schedule, and start.

The Chrome extension must be installed separately. Chrome does not currently have this extension in the Web Store. The standalone EXE does not contain the extension and native host; use the complete ZIP for Chrome support.

## Enforcement and limitations

The background agent asks configured applications to close normally. It may also ask alternate browsers or Chrome to close during strict website sessions, depending on Protection settings and extension heartbeat. It never force-terminates processes. Website enforcement in Chrome uses the shared extension and its native messaging host. Schedules are evaluated by the app and continue while the optional background agent is running.

During a session, **Emergency end active blocks…** immediately ends active sessions, including timer- and password-locked sessions. It keeps blocklists, schedules, passwords and settings, and records the action in Activity. A scheduled session will not restart until its next scheduled occurrence.

For recovery without opening the main window, run `FocusBlocker.App.exe --failsafe-end`. On macOS, run `/Applications/FocusBlocker.app/Contents/Helpers/focusctl failsafe-end` in Terminal. Both ask for confirmation before ending active sessions.

Accountability passwords are stored as salted PBKDF2-SHA256 hashes. Repeated incorrect unlock attempts are temporarily locked out. The local activity history is chained with HMAC tags. These add accountability and friction; they are not administrator-proof protections. A user with sufficient access can stop the agent, alter local state, disable the extension, or uninstall FocusBlocker. This app does not install a tamper-proof driver or enforce Windows firewall policies.

Windows is a separate .NET 10/WPF implementation; it does not share the macOS Swift engine. The Windows release is self-contained for x64, so the download is larger than the small macOS package.
