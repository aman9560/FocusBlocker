# IMPORTANT: THE CHROME EXTENSION IS A SEPARATE INSTALL

The Focus Blocker app and its installer do **not** install the Chrome extension automatically. Chrome requires users to install this extension separately. The extension is not currently published in the Chrome Web Store.

## Install the extension

1. Download `FocusBlocker-Chrome-Extension.zip` and extract it to a folder you will keep in place. Do not move or delete that folder after loading it.
2. In Chrome, open `chrome://extensions`.
3. Turn on **Developer mode**.
4. Click **Load unpacked** and select the extracted `FocusBlocker-Chrome-Extension` folder.

## Connect the native host on macOS

After installing Focus Blocker in `/Applications`, open Terminal and run:

```sh
/Applications/FocusBlocker.app/Contents/Helpers/focusctl chrome install-host --extension-id mchnpkbnifalondddkmcbplnlebaebmd
```

The extension ID is pinned in the included manifest. Reload the extension from `chrome://extensions` if Chrome asks.

## Connect the native host on Windows

Use `FocusBlocker-Windows-x64.zip`, not the standalone EXE. Extract the full ZIP to a folder you will keep in place, run `FocusBlocker.App.exe`, and choose **Install Chrome host** in the app. In `chrome://extensions`, enable **Developer mode**, click **Load unpacked**, and select the ZIP's `extension` folder. Keep the extracted folder in place.

The extension connects Chrome to Focus Blocker through a registered native messaging host. The extension and the desktop app are separate components; installing one does not silently install the other.
