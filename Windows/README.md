# Windows preview

The Windows app is an early .NET 10 preview for Windows 11 x64 and supported Windows 10 LTSC/Enterprise editions. It provides timed sessions, Chrome website rules through the shared MV3 extension, and polite app closing while its window is running.

## Install from the release ZIP

1. Extract the full ZIP to a folder you control and run `FocusBlocker.App.exe`.
2. In the app, choose **Install Chrome host**.
3. Open `chrome://extensions`, enable Developer mode, and load the included `extension` folder.
4. Add domains or process names, set a duration, and start a session.

The Chrome host is registered for the current Windows account. The extension is not listed in the Chrome Web Store; load the included folder manually. Use one domain or process name per line. Process names omit `.exe`.

## Limits in this preview

The app must remain running for process closing. It asks apps to close normally and does not force-terminate them. Closing the app stops process enforcement. Chrome rules remain active until the session end is sent to the extension or its expiry grace elapses. This preview has no recurring schedules, no administrator-level enforcement, and no early-unlock password. An administrator can stop or remove it.

The macOS implementation remains in the repository root. The Windows app is a separate implementation and does not share the Swift engine.
