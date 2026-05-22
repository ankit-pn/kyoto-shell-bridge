# Kyoto shell bridge installer

One-shot installers for the native messaging host that lets the
[Kyoto](https://github.com/ankit-pn/kyoto) Chrome extension run shell
commands on your machine.

## Install

**Linux / macOS**

```bash
curl -fsSL https://raw.githubusercontent.com/ankit-pn/kyoto-shell-bridge/main/install.sh \
  | bash -s -- <YOUR_EXTENSION_ID>
```

**Windows (PowerShell)**

```powershell
$env:KYOTO_EXT_ID = "<YOUR_EXTENSION_ID>"
irm https://raw.githubusercontent.com/ankit-pn/kyoto-shell-bridge/main/install.ps1 | iex
```

Find your extension ID at `chrome://extensions` (Developer mode on),
or open Kyoto → ⚙ Settings → **Shell bridge** — the ID is shown with
a Copy button and the install command is pre-filled.

## What it does

- Drops `kyoto-shell.py` under your home dir
  (`~/.local/share/kyoto/`, `~/Library/Application Support/Kyoto/`,
  or `%LOCALAPPDATA%\Kyoto\`).
- Writes the Chrome native messaging manifest into every Chromium
  browser's `NativeMessagingHosts/` directory it can find (Chrome,
  Chromium, Edge, Brave, Vivaldi, Opera, Arc on macOS).
- On Windows, registers the manifest under HKCU per browser.
- No sudo, no ports opened — Chrome speaks to the host over stdio.

After install, restart Chrome and test with `/sh echo hello` in Kyoto.

## Files

- `install.sh` — bash installer for Linux & macOS.
- `install.ps1` — PowerShell installer for Windows.
- `kyoto-shell.py` — the native messaging host. The bash and PowerShell
  installers embed this script inline (heredoc / here-string) so the
  curl|bash one-liner doesn't need a second download. The standalone
  copy is here for transparency and for users who want to run it
  manually.

## Uninstall

Delete the install directory and the native messaging manifests:

```bash
# Linux
rm -rf ~/.local/share/kyoto
rm -f ~/.config/google-chrome/NativeMessagingHosts/com.kyoto.shell.json
rm -f ~/.config/chromium/NativeMessagingHosts/com.kyoto.shell.json
# … and any other Chromium browser variants you have

# macOS
rm -rf "$HOME/Library/Application Support/Kyoto"
find "$HOME/Library/Application Support" -name 'com.kyoto.shell.json' -delete
```

```powershell
# Windows
Remove-Item -Recurse -Force $env:LOCALAPPDATA\Kyoto
Get-ChildItem HKCU:\Software -Recurse -Filter 'com.kyoto.shell' | Remove-Item -Recurse -Force
```
