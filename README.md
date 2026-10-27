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

The repository includes the macOS app and a separate early Windows preview. Windows does not yet include all macOS features; see [Windows setup and limitations](Windows/README.md). A Windows x64 ZIP is published on the [Releases page](https://github.com/aman9560/FocusBlocker/releases) after its Windows CI build succeeds.
