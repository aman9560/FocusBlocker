# Focus Blocker

Focus Blocker is an independent macOS focus tool for timed sessions, schedules, website blocklists, and app blocking. It is not affiliated with or endorsed by any other focus-blocking product.

> **Status:** early development. The current implementation targets macOS 13 or later and Apple silicon. It has no Windows build.

![Focus Blocker logo](Assets/focus-logo.png)

## Features

- Timed focus sessions with optional accountability password
- Recurring schedules and website blocklists
- Chrome extension integration through a native messaging host
- Optional background agent for app and browser enforcement
- Local activity log and import of supported blocklist formats

Enforcement on a personal administrator account is intended to add friction and make casual bypasses visible. It cannot prevent an administrator from stopping or removing the software.

## Build

The current build script uses the Swift compiler directly and requires the macOS Command Line Tools:

```sh
./build.sh
./build.sh app
```

`./build.sh app` assembles `.build/FocusBlocker.app`. The app is ad-hoc signed for local use; it is not notarized for distribution. Review the relevant source code before enabling the optional background agent or browser integration.

## Browser extension

Load the `Extension` directory as an unpacked extension in Chrome, then install the native messaging host using the `focusctl` command. The extension's public manifest key pins its development ID. The matching private signing key is intentionally not included in this repository.

## Platform support

This repository contains a macOS implementation only. Windows support would require a separate Windows app, background-service, storage, and enforcement implementation; no Windows installer or release is currently available.
