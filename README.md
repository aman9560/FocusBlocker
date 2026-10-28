# Focus Blocker

<p align="center"><img src="Assets/github-banner.png" alt="Focus Blocker GitHub banner" width="100%"></p>

<p align="center">
  <a href="https://github.com/aman9560/FocusBlocker/actions/workflows/ci.yml"><img src="https://github.com/aman9560/FocusBlocker/actions/workflows/ci.yml/badge.svg" alt="CI status"></a>
  <a href="https://github.com/aman9560/FocusBlocker/releases/latest"><img src="https://img.shields.io/github/v/release/aman9560/FocusBlocker" alt="Latest release"></a>
  <img src="https://img.shields.io/badge/macOS-13%2B%20Apple%20silicon-lightgrey" alt="macOS 13+ on Apple silicon">
  <img src="https://img.shields.io/badge/Windows-10%2F11%20x64-lightgrey" alt="Windows 10 and 11, x64">
</p>

Focus Blocker is a desktop focus app for **macOS and Windows**. You collect distracting websites and apps into named blocklists, start timed focus sessions or recurring weekly schedules, and optionally add accountability locks so a session is hard to cut short. A companion **Chrome extension** applies the website rules inside Chrome and talks to the desktop app through a native messaging host.

It is a personal-use project: everything stays on your computer, there is no account and no cloud.

Focus Blocker is an independent implementation. It is not affiliated with or endorsed by Cold Turkey or any other focus-blocking product.

<p align="center"><img src="Assets/focus-logo-transparent.png" alt="Focus Blocker logo" width="320"></p>

> [!IMPORTANT]
> **macOS: you must run an approval command in Terminal before the app will open.**
> Focus Blocker is not notarized by Apple (that needs a paid Apple Developer ID), so macOS blocks it the first time. Run the approval command **once** in Terminal, and only then will it run on your Mac. See [macOS install](#macos-install-approval-command-required) right below.

## Contents

- [macOS install (approval command required)](#macos-install-approval-command-required)
- [Windows install](#windows-install)
- [Set up Chrome website blocking](#set-up-chrome-website-blocking)
- [Quick start](#quick-start)
- [Features](#features)
- [macOS and Windows compared](#macos-and-windows-compared)
- [Command-line tool (macOS)](#command-line-tool-macos)
- [How it works](#how-it-works)
- [Security model and limits](#security-model-and-limits)
- [Troubleshooting](#troubleshooting)
- [Uninstall](#uninstall)
- [Build from source and run the tests](#build-from-source-and-run-the-tests)
- [Project layout](#project-layout)
- [Releasing](#releasing)
- [Contributing and commit rules](#contributing-and-commit-rules)
- [Privacy](#privacy)
- [License](#license)

---

## macOS install (approval command required)

Requires **macOS 13 or later on an Apple silicon Mac** (M1 or newer).

### Why an approval command is needed

macOS puts a "quarantine" flag on anything downloaded through a web browser, and Gatekeeper refuses to open a flagged app unless it was signed with a paid Apple Developer ID and notarized by Apple. Focus Blocker is signed ad hoc instead, so without the approval step you will see "FocusBlocker is damaged and can't be opened" or "Apple could not verify FocusBlocker is free of malware", and the app will not start.

The approval command removes that quarantine flag from **this one app**. It does not turn Gatekeeper off and does not change any macOS security setting.

### Option A: install from Terminal (recommended)

Open **Terminal** (Applications → Utilities → Terminal) and run this single command. It is the approval step and the install in one:

```sh
curl -fsSL https://raw.githubusercontent.com/aman9560/FocusBlocker/main/install-mac.sh | bash
```

It downloads the latest release, installs `FocusBlocker.app` into `/Applications`, removes the quarantine flag, registers the Chrome connection, and opens the app. Files downloaded by `curl` never get the quarantine flag in the first place, which is why nothing is blocked.

### Option B: you already downloaded the DMG or ZIP in a browser

1. Drag `FocusBlocker.app` into **Applications**.
2. Open **Terminal** and run the approval command:

   ```sh
   xattr -dr com.apple.quarantine /Applications/FocusBlocker.app
   ```

3. Open Focus Blocker from Applications. It now runs.

(macOS also offers **System Settings → Privacy & Security → Open Anyway**, but the command above is the most reliable.)

Only run the approval command on a copy that came from this repository's [Releases](https://github.com/aman9560/FocusBlocker/releases/latest) or that you built yourself, and feel free to read [install-mac.sh](install-mac.sh) first. `./install-mac.sh --help` lists its options, for example `--app PATH` to install a build you made yourself and `--version TAG` to install a specific release.

### After the app opens

macOS asks you to approve two more things yourself; no script can do these for you:

1. **Background agent.** In Focus Blocker open **Protection → Turn on agent**, then allow it in **System Settings → General → Login Items** (named *Login Items & Extensions* on newer macOS versions). The agent is what closes blocked apps and keeps schedules running when the window is closed.
2. **Notifications.** Allow notifications for Focus Blocker when asked (**System Settings → Notifications**) so you see session start, end and "app closed" messages.

After you update the app later, open it once: it re-registers the agent automatically, because macOS ties the agent to the exact build that was approved.

The installer will not update while a focus session is running (replacing the app would stop the agent that enforces it). Your blocklists, schedules and history are kept across updates.

---

## Windows install

Requires **Windows 10 or 11, 64-bit**. No administrator rights are needed. Open **PowerShell** and run:

```powershell
irm https://raw.githubusercontent.com/aman9560/FocusBlocker/main/install-windows.ps1 | iex
```

This downloads the latest release ZIP, installs it under `%LOCALAPPDATA%\Programs\FocusBlocker`, adds a Start Menu shortcut, registers the Chrome connection, and starts the app. Files downloaded this way do not carry the "downloaded from the internet" mark, so SmartScreen's "Windows protected your PC" warning does not appear (the script also clears the mark from everything it installs). You can read [install-windows.ps1](install-windows.ps1) first.

To install by hand, download `FocusBlocker-Windows-x64.zip` from the [Releases](https://github.com/aman9560/FocusBlocker/releases/latest), extract it somewhere you will keep it, and run `FocusBlocker.App.exe`. If SmartScreen warns, choose **More info → Run anyway**. See [Windows/README.md](Windows/README.md) for details and options (environment variables such as `FOCUSBLOCKER_ZIP` and `FOCUSBLOCKER_VERSION`).

In the app, open **Protection** and turn on **Run FocusBlocker in the background and at sign-in** if you want blocked apps to be closed and schedules to keep running while the window is closed.

The installer will not update while a focus session is running.

---

## Set up Chrome website blocking

Website rules are applied in Chrome by a small extension. The desktop app alone does **not** block websites in any browser. The extension is **not** in the Chrome Web Store, so you load it yourself:

1. Find the extension folder:
   - **macOS:** the installer put a copy in `~/FocusBlocker-Chrome-Extension`.
   - **Windows:** use the `extension` folder inside `%LOCALAPPDATA%\Programs\FocusBlocker`.
   - Or download `FocusBlocker-Chrome-Extension.zip` from the [Releases](https://github.com/aman9560/FocusBlocker/releases/latest) and extract it.
2. In Chrome open `chrome://extensions` and turn on **Developer mode** (top right).
3. Click **Load unpacked** and choose that folder. **Keep the folder in place**; Chrome reads it from there every time it starts.
4. Open the extension's **Details** and turn on **Allow in Incognito**, otherwise private windows are not filtered.
5. Make sure the Chrome connection is registered:
   - **macOS:** `/Applications/FocusBlocker.app/Contents/Helpers/focusctl chrome install-host --extension-id mchnpkbnifalondddkmcbplnlebaebmd` (the installer already did this).
   - **Windows:** use **Install Chrome host** in the app, or run `FocusBlocker.App.exe --install-host`.
6. Check it worked. On macOS, **Chrome** in the sidebar (or `focusctl chrome status`) shows the connection and rule count. The extension badge shows **ON** during a session.

The extension has a fixed ID (`mchnpkbnifalondddkmcbplnlebaebmd`) so the connection can be registered ahead of time. More detail is in the [extension setup guide](Assets/CHROME-EXTENSION-INSTALL.md).

---

## Quick start

1. Open Focus Blocker and create a **blocklist** (for example "Distractions"). Add websites such as `reddit.com` or `youtube.com/shorts`, and apps you want closed.
2. Optionally set an **accountability password** (**Protection** on Windows, **Accountability** on macOS), ideally one a friend chooses so you don't know it.
3. Start a **session**: pick one or more blocklists, a length (up to 12 hours), a lock type, and whether it is strict.
4. Or create a **weekly schedule** so focus time starts by itself.
5. Watch the activity log to see what happened.

---

## Features

### Blocklists

A blocklist is a named group of rules. A session or schedule can combine several lists.

| Rule type | Example | What it does |
|---|---|---|
| Website | `reddit.com` | Blocks the site **and all its subdomains** (`old.reddit.com`, `www.reddit.com`). `www.` and `https://` are optional when you type it. |
| Path | `youtube.com/shorts` | Blocks only that part of a site. Matches whole path segments, so `/shorts` does not block `/shortstack`. |
| Exception | `reddit.com/r/swift` | Stays reachable even though a broader rule blocks it. |
| All websites | `*` (or `*.*`) | Blocks every website; combined with exceptions this becomes an **allowlist** ("only my work sites"). |
| App (macOS) | a bundle ID such as `com.tinyspeck.slackmacgap` | Closed while a session runs. Choose apps with the app picker. |
| App (Windows) | a process name such as `slack` | Closed while a session runs. `.exe` and full paths are accepted. |

Rules are normalized when saved (case, ports, trailing slashes, `www.`). Entries that are not websites, such as `file://` rules, are rejected rather than guessed. When several active lists apply, an exception only survives if every list that blocks that site also excepts it, so one list can never quietly unblock another list's site.

Apps that are part of the operating system (Finder, Dock, System Settings, Terminal and Activity Monitor on macOS; Explorer, Task Manager and similar on Windows) and Focus Blocker itself can never be blocked, so a session can't leave you without a working computer.

**Importing.** You can import websites from a plain text file (one site per line, `#` for comments) or from a Cold Turkey JSON export (each Cold Turkey block becomes its own list). Rules that are not websites are skipped and reported. Cold Turkey's own encoded export format is not supported, and Focus Blocker never reads Cold Turkey's files directly.

### Focus sessions

Pick blocklists, a duration (1 minute to 12 hours), a lock, and optionally strict mode. A session keeps running if you close the main window, as long as the background agent is on.

**Locks:**

| Lock | Ending early |
|---|---|
| None | Stop it with the normal **End session** button. |
| Timer | The normal stop control is disabled until the time is up. |
| Password | Requires the accountability password. |

**Strict mode** stops you weakening an active session from inside the app: while a strict session uses a list you can add sites and apps to it but not remove them, you cannot add exceptions, delete or rename it, weaken or delete the schedules, change the accountability password, or turn off the "close other browsers" setting.

### Weekly schedules

Choose days, a start and end time, blocklists, and a lock. A schedule starts a session when its window opens and ends it when the window closes. Overnight windows (for example 23:00 to 06:00) work. The time zone is fixed when you create the schedule, so travelling or changing the Mac's time zone does not move it. Each occurrence starts at most one session: if you end it with the failsafe, it does not restart until the next occurrence.

### Accountability password

An optional password that ends password-locked sessions early. It is stored only as a salted PBKDF2-SHA256 hash (600,000 iterations). After three wrong attempts you are locked out for 30 seconds, doubling each time up to one hour. It cannot be changed during a strict session. For real accountability, have someone else set it.

### Chrome website blocking

The extension applies the active website rules inside Chrome using Chrome's own blocking engine, so a blocked page never loads and shows a Focus Blocker page with the time remaining. It also catches in-page navigations (for example YouTube moving to `/shorts`) and redirects tabs that were already open when a session started. If the desktop app is unreachable, the last rules stay in force until the session's expected end.

During **strict** sessions that block websites, the background agent also protects the setup:

- Chrome is closed if the extension stops responding (no heartbeat for 30 seconds on macOS, 45 on Windows) or, on macOS, if Chrome was started with extensions disabled. A freshly launched Chrome gets 30 seconds to start the extension, and nothing is closed before the Chrome host is installed.
- **Other browsers are closed**, because they cannot run the extension and would otherwise be a way around your website blocks. macOS: Safari (and Safari web apps), Arc, Firefox, Brave, Edge, Opera, Vivaldi and others. Windows: Edge, Firefox, Brave, Opera, Vivaldi, Arc and others. You can turn this off in **Protection**, but not during a strict session.

### Background agent

A per-user background process that, while a session is active, closes blocked apps, enforces the browser rules above, and (on macOS) posts notifications. It asks apps to quit exactly as the close button or ⌘Q would and **never force-quits**, so unsaved work is not lost. An app that stays open, for example behind a save dialog, is hidden and asked again every 10 seconds. On macOS it is a Login Item you approve once; on Windows it starts at sign-in. If it is turned off, a banner in the macOS app warns you that blocked apps won't be closed.

### Activity log and emergency failsafe

Focus Blocker records session starts and ends, closed apps, failed and refused unlock attempts, setting changes, clock anomalies and failsafe use. The log is chained with an HMAC, so editing or removing an individual entry is detected (**Activity → Verify log** on macOS, `focusctl audit --verify`). It cannot stop an administrator deleting the whole file.

If you genuinely must stop a locked session, use **Emergency end** in the app. It ends all active sessions immediately, records that it did, and keeps your blocklists, schedules, password and settings. Without opening the window:

- **macOS:** `/Applications/FocusBlocker.app/Contents/Helpers/focusctl failsafe-end`
- **Windows:** `FocusBlocker.App.exe --failsafe-end`

Both ask for confirmation. Because the failsafe needs no password, a timer lock is a speed bump rather than a hard lock.

### Notifications (macOS)

The agent posts a notification when a session starts or ends (however it was started: the app, `focusctl`, a schedule, or the timer running out) and when it closes an app or browser, including how long the block lasts.

---

## macOS and Windows compared

The two apps are separate implementations: macOS is Swift (SwiftUI), Windows is .NET 10 (WPF). They share the extension and the rule semantics, and behave the same except where noted.

| | macOS | Windows |
|---|---|---|
| Requirements | macOS 13+, Apple silicon | Windows 10/11, x64 |
| Screens | Session, Blocklists, Schedules, Protection, Chrome, Accountability, Activity | Focus, Blocklists, Schedules, Protection, Activity (password is in Protection) |
| Apps are identified by | Bundle ID (renamed or copied apps still match) | Process name |
| Background agent | Login Item you approve in System Settings | Starts at sign-in (Run key), no approval prompt |
| Notifications | Yes | No |
| Session clock | Counts elapsed time with a clock that changing the system time cannot shorten; a reboot never ends a session | Ends by the wall clock, so changing the system clock affects sessions |
| State stored in | `~/Library/Application Support/FocusBlocker` | `%LOCALAPPDATA%\FocusBlocker` |
| Command-line tool | `focusctl` | `FocusBlocker.App.exe --failsafe-end` and `--install-host` only |
| Distributed as | ZIP, DMG, installer script | ZIP, EXE, installer script |
| Gatekeeper / SmartScreen | Approval command needed (see above) | Avoided by the installer; manual download may show SmartScreen |

---

## Command-line tool (macOS)

`focusctl` ships inside the app at `/Applications/FocusBlocker.app/Contents/Helpers/focusctl` and shares all state with the app, the agent and the Chrome host.

```text
focusctl status [--json]
focusctl blocklist list | create NAME | add NAME | remove NAME | delete NAME
         (with --domain D, --except D, --app BUNDLE_ID, repeatable)
focusctl password set
focusctl start --blocklist NAME [--blocklist NAME]... --minutes N [--lock timer|password|none] [--no-strict]
focusctl stop
focusctl failsafe-end
focusctl schedule list | add NAME --blocklist NAME... --days mon,tue|weekdays|all --from HH:MM --to HH:MM [--tz ZONE] [--lock L] [--no-strict] | delete NAME
focusctl import FILE [--into NAME] [--dry-run]
focusctl settings close-other-browsers on|off
focusctl policy [--json]            # what is being blocked right now
focusctl chrome-rules               # the compiled Chrome rules
focusctl audit [--verify]
focusctl chrome status | install-host --extension-id ID [--dry-run] | uninstall-host | extension-id PATH/TO/manifest.json
```

Sessions started from the command line default to **strict and timer-locked**. `--state-dir`, `--key-file` and `--password-stdin` are available for scripting and tests.

---

## How it works

```text
 ┌──────────────── Focus Blocker app (SwiftUI / WPF) ────────────────┐
 │  screens, session controls, Protection, activity                  │
 └───────────────┬───────────────────────────────────────────────────┘
                 │ all of them read and write the same locked state folder
 ┌───────────────▼─────────────┐     ┌─────────────────────────────────────────┐
 │  Engine (FocusCore / Core)  │◄────┤ Background agent                        │
 │  sessions, schedules, rules,│     │ closes blocked apps and browsers,       │
 │  locks, password, audit log │     │ notifications, keeps schedules running  │
 └───────────────▲─────────────┘     └─────────────────────────────────────────┘
                 │
 ┌───────────────┴─────────────┐  stdin/stdout   ┌───────────────────────────┐
 │ Native messaging host       │◄───────────────►│ Chrome extension (MV3)    │
 │ sends rules, records        │  length-prefixed│ applies rules with Chrome's│
 │ heartbeats                  │  JSON           │ blocking engine, block page│
 └─────────────────────────────┘                 └───────────────────────────┘
```

- **Engine.** One authority for sessions, schedules, blocklists, the password and the audit log. Every operation locks the shared state folder, reloads it, advances time, validates, saves and audits, so the app, the agent, the host and the command-line tool can all act without overwriting each other.
- **State.** JSON written atomically with a flush to disk. On macOS it is authenticated with an HMAC and a last-known-good backup is kept: if the file is edited by hand it falls back to the backup and logs the recovery. The file is not rewritten on every tick: it is saved when something changes (and, on macOS, at least every 30 seconds).
- **Rules.** Both engines compile the active lists into Chrome `declarativeNetRequest` rules (redirect the page to the block page, block sub-requests, allow exceptions with higher priority). A shared URL fixture, `Tests/fixtures/url-cases.json`, keeps the Swift engine and the extension's own matcher in agreement.
- **Extension.** Talks to the host over Chrome native messaging, applies rules, sweeps open tabs, and sends a heartbeat every 15 seconds. It can only read policy: it never receives the password and cannot end or change a session.
- **Agent.** On macOS it is `FocusBlockerAgent.app` inside the app bundle, registered through `SMAppService`. On Windows it is the same executable started with `--agent` at sign-in. The decision of what to close is plain, tested logic (`Guards.swift` on macOS, `ProcessGuard.cs` on Windows).

---

## Security model and limits

Focus Blocker is built to make distractions **harder to reach and bypasses more deliberate**. It is **not tamper-proof**.

- **Administrator access wins.** Someone with admin rights can stop the agent, edit or delete the state files, remove the extension, or uninstall the app. Everything here is friction and accountability, not enforcement. The same is true of other app-level blockers.
- **No system-level blocking.** It installs no driver, kernel or system extension and does not touch the firewall, hosts file or DNS. Blocking an app before it launches would need Apple's restricted Endpoint Security entitlement.
- **Websites are blocked only in Chrome**, with the extension installed and allowed in incognito. Other browsers are closed during strict website sessions rather than filtered. Per-site blocking in every browser or app would need a network filter, which requires a paid Apple Developer account on macOS.
- **Apps are closed after they open**, not prevented from opening, and they may be visible for a moment. They are asked to quit, never force-killed.
- **Failsafe.** The emergency failsafe ends any session without the password.
- **Windows sessions follow the system clock.** Setting the clock forward ends them early.
- **Unsigned.** The apps are not code-signed with a paid certificate: macOS needs the approval command and Windows may show SmartScreen on a manual download. Read the install scripts and the source before running them.

---

## Troubleshooting

**macOS says the app is "damaged" or "can't be verified".** You skipped the approval step. Run `xattr -dr com.apple.quarantine /Applications/FocusBlocker.app` in Terminal, or reinstall with the Terminal command in [macOS install](#macos-install-approval-command-required).

**Blocked apps aren't being closed (macOS).** The background agent is off. A red banner says so. Open **Protection → Turn on agent** and allow it in **System Settings → General → Login Items**. After an update, open the app once so it re-registers the agent.

**Chrome shows no rules or the status says not connected.** Check that the extension is loaded and enabled in `chrome://extensions`, that the Chrome host is registered (see [Chrome setup](#set-up-chrome-website-blocking)), and reload the extension. On macOS `focusctl chrome status` shows the last heartbeat and whether incognito is allowed.

**Websites in a private window aren't blocked.** Turn on **Allow in Incognito** for the extension.

**Chrome keeps closing during a strict session.** In a strict website session Chrome is closed when the extension is not responding. Make sure the extension is loaded and enabled. If you need out, use the emergency failsafe.

**An app I blocked isn't closed.** On macOS, check the app's bundle ID is right and that the agent is on. On Windows, the process name must match the running process (without `.exe`). System apps and Focus Blocker itself cannot be blocked.

**The installer says a session is running.** Finish or end the session first. Updating would stop the agent that enforces it. (`--force` on macOS and `FOCUSBLOCKER_FORCE=1` on Windows override this.)

**The extension folder disappeared.** Chrome needs the folder you loaded to stay where it was. Put it somewhere permanent and load it again.

---

## Uninstall

**macOS**

1. Make sure no strict session is running, then in the app turn the agent off (**Protection**) or remove Focus Blocker in **System Settings → General → Login Items**.
2. Quit the app and delete `/Applications/FocusBlocker.app`.
3. Remove the Chrome host: `focusctl chrome uninstall-host` (run it before deleting the app), or delete `~/Library/Application Support/Google/Chrome/NativeMessagingHosts/com.focusblocker.nmh.json`.
4. Optionally delete your data: `~/Library/Application Support/FocusBlocker` and `~/FocusBlocker-Chrome-Extension`.
5. Remove the extension in `chrome://extensions`.

**Windows**

1. Turn off the background agent in **Protection**, then close the app.
2. Delete `%LOCALAPPDATA%\Programs\FocusBlocker` and the Start Menu shortcut `FocusBlocker`.
3. Remove the registry values the app created under `HKEY_CURRENT_USER`: `Software\Microsoft\Windows\CurrentVersion\Run` → `FocusBlockerAgent`, and the key `Software\Google\Chrome\NativeMessagingHosts\com.focusblocker.nmh`.
4. Optionally delete your data: `%LOCALAPPDATA%\FocusBlocker`.
5. Remove the extension in `chrome://extensions`.

---

## Build from source and run the tests

### macOS

Requires the Swift compiler (Xcode Command Line Tools) and Node.js for the extension tests.

```sh
./build.sh test   # builds the engine and runs the Swift and extension tests
./build.sh app    # assembles .build/FocusBlocker.app (ad-hoc signed)
./install-mac.sh --app .build/FocusBlocker.app
python3 -I Tests/e2e/nmh_e2e.py .build    # runs the real Chrome host over pipes
```

`build.sh` calls `swiftc` directly; `Package.swift` is provided for when Xcode is installed. The SwiftUI views use a small `@LocalState` wrapper because `@State` is a macro whose plugin ships only with Xcode.

### Windows

Requires the .NET 10 SDK.

```sh
dotnet run --project Windows/FocusBlocker.Tests -c Release   # engine, process rules, and the real Chrome host process
dotnet build Windows/FocusBlocker.App/FocusBlocker.App.csproj -c Release
```

The tests run on any OS. The WPF app itself only runs on Windows; on macOS or Linux it compiles with `-p:EnableWindowsTargeting=true`.

### Continuous integration

`.github/workflows/ci.yml` runs the macOS and Windows tests on every push to `main` and every pull request. Both must pass before merging.

---

## Project layout

```text
Sources/
  FocusCore/          macOS engine: sessions, schedules, rules, locks, password, audit log, Chrome rules
  FocusBlockerApp/    macOS SwiftUI app
  focus-agent/        macOS background agent
  focus-nmh/          macOS Chrome native messaging host
  focusctl/           macOS command-line tool
Windows/
  FocusBlocker.Core/        Windows engine (rules, state, process guard, importer)
  FocusBlocker.App/         WPF app and background agent
  FocusBlocker.NativeHost/  Windows Chrome native messaging host
  FocusBlocker.Tests/       Windows tests, including one that runs the real host
Extension/            Chrome extension (Manifest V3), shared by both platforms
Tests/                Swift tests, extension tests, shared URL fixture, host end-to-end test
Assets/               icons, logo, banner, extension setup guide
install-mac.sh        macOS installer
install-windows.ps1   Windows installer
build.sh              macOS build, test and packaging script
.github/              CI and release workflows, pull request template
```

---

## Releasing

Releases are built by GitHub Actions. Push a version tag (for example `v0.2.6`) or run the **Release** workflow from the Actions tab with a version. It runs the tests, builds the macOS app (ZIP and DMG), the Windows app (ZIP and EXE) and the extension ZIP, and publishes them as one release. The installers always download the **latest** release, so a fix only reaches users once a release exists.

Never name a workflow-level environment variable `VERSION`: MSBuild reads environment variables as properties, so it becomes the projects' version and every `dotnet restore` fails. The workflow uses `RELEASE_TAG`.

---

## Contributing and commit rules

Contributions are welcome. The short version, with the full guide in [CONTRIBUTING.md](CONTRIBUTING.md):

1. **Branch** from `main` using `type/short-description`, for example `fix/windows-chrome-grace`, `feat/mac-snooze`, `docs/readme`. Never commit directly to `main`.
2. **Commit** with a clear, imperative subject of 72 characters or fewer (`Fix Chrome closing during start-up`, not `fixed stuff`), a prefix when it only concerns one area (`Windows:`, `Mac:`, `Extension:`, `CI:`, `Docs:`), and a body that explains **why**. One logical change per commit.
3. **Test** before you push. Run the macOS and/or Windows tests listed above. Fix bugs with a test that fails without the fix.
4. **Keep platforms in step.** A change to rule matching, locks or strict-mode behaviour must be made in both engines (and in `Tests/fixtures/url-cases.json` where it applies).
5. **Open a pull request** against `main`, fill in the template, and wait for CI to pass. Merge with a merge commit (not a squash) so commits are preserved.
6. **Never commit** secrets, signing keys (`signing/extension-key.pem` is git-ignored), build output (`.build/`, `dist/`, `bin/`, `obj/`) or personal data.

---

## Privacy

Focus Blocker keeps its settings, blocklists, schedules, sessions and activity history on your device only. It has no account, no analytics and no cloud sync, and it makes no network requests while running. (The installers contact GitHub to download releases.) The Chrome extension talks only to the local app through Chrome native messaging, to read the active rules and report its connection status.

---

## License

No license has been chosen for this project yet. Until one is added, all rights are reserved by the author. If you want to reuse the code, please open an issue.
