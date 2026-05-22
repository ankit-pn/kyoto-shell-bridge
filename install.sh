#!/usr/bin/env bash
# Kyoto native messaging host installer (Linux + macOS).
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/ankit-pn/kyoto-shell-bridge/main/install.sh | bash -s -- <EXTENSION_ID>
#   curl -fsSL .../install.sh | KYOTO_EXT_ID=<id> bash
#   ./install.sh <EXTENSION_ID>
#
# Find your extension ID at chrome://extensions (toggle Developer mode).
# The bridge writes its files entirely under $HOME — no sudo required.

set -euo pipefail

HOST_NAME="com.kyoto.shell"
EXT_ID="${1:-${KYOTO_EXT_ID:-}}"

c_red()    { printf '\033[31m%s\033[0m\n' "$*" >&2; }
c_green()  { printf '\033[32m%s\033[0m\n' "$*"; }
c_yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
c_dim()    { printf '\033[2m%s\033[0m\n' "$*"; }

if [[ -z "$EXT_ID" ]]; then
  c_red "Error: extension ID required."
  cat >&2 <<'USAGE'

Usage:
  ./install.sh <EXTENSION_ID>
or
  curl -fsSL https://raw.githubusercontent.com/ankit-pn/kyoto-shell-bridge/main/install.sh \
    | bash -s -- <EXTENSION_ID>

Find your extension ID at chrome://extensions (toggle Developer mode).
Kyoto's Settings drawer also shows it under "Shell bridge".

USAGE
  exit 1
fi

if [[ ! "$EXT_ID" =~ ^[a-p]{32}$ ]]; then
  c_yellow "Warning: '$EXT_ID' doesn't look like a Chrome extension ID."
  c_yellow "Extension IDs are exactly 32 characters, letters a-p only."
  c_yellow "Continuing anyway in case Chrome has changed the format."
fi

case "$(uname -s)" in
  Linux*)
    PLATFORM=linux
    INSTALL_DIR="$HOME/.local/share/kyoto"
    declare -a MANIFEST_DIRS=(
      "$HOME/.config/google-chrome/NativeMessagingHosts"
      "$HOME/.config/chromium/NativeMessagingHosts"
      "$HOME/.config/google-chrome-beta/NativeMessagingHosts"
      "$HOME/.config/google-chrome-unstable/NativeMessagingHosts"
      "$HOME/.config/microsoft-edge/NativeMessagingHosts"
      "$HOME/.config/BraveSoftware/Brave-Browser/NativeMessagingHosts"
      "$HOME/.config/vivaldi/NativeMessagingHosts"
      "$HOME/.config/opera/NativeMessagingHosts"
    )
    ;;
  Darwin*)
    PLATFORM=macos
    INSTALL_DIR="$HOME/Library/Application Support/Kyoto"
    declare -a MANIFEST_DIRS=(
      "$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts"
      "$HOME/Library/Application Support/Chromium/NativeMessagingHosts"
      "$HOME/Library/Application Support/Google/Chrome Beta/NativeMessagingHosts"
      "$HOME/Library/Application Support/Google/Chrome Canary/NativeMessagingHosts"
      "$HOME/Library/Application Support/Microsoft Edge/NativeMessagingHosts"
      "$HOME/Library/Application Support/BraveSoftware/Brave-Browser/NativeMessagingHosts"
      "$HOME/Library/Application Support/Vivaldi/NativeMessagingHosts"
      "$HOME/Library/Application Support/com.operasoftware.Opera/NativeMessagingHosts"
      "$HOME/Library/Application Support/Arc/User Data/NativeMessagingHosts"
    )
    ;;
  *)
    c_red "Unsupported OS: $(uname -s)"
    c_yellow "On Windows, use install.ps1 instead:"
    c_yellow "  irm https://raw.githubusercontent.com/ankit-pn/kyoto-shell-bridge/main/install.ps1 | iex"
    exit 1
    ;;
esac

PY=""
for candidate in python3 python; do
  if command -v "$candidate" >/dev/null 2>&1; then
    if "$candidate" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 7) else 1)' 2>/dev/null; then
      PY="$candidate"
      break
    fi
  fi
done
if [[ -z "$PY" ]]; then
  c_red "Error: Python 3.7+ is required but was not found in PATH."
  c_yellow "Install it: https://www.python.org/downloads/   (or 'brew install python' on macOS)"
  exit 1
fi
PY_PATH="$(command -v "$PY")"

mkdir -p "$INSTALL_DIR"
HOST_SCRIPT="$INSTALL_DIR/kyoto-shell.py"

# Embedded host script. Keep in sync with install/kyoto-shell.py.
cat > "$HOST_SCRIPT" <<'PYEOF'
#!/usr/bin/env python3
"""Kyoto native messaging host (embedded by install.sh)."""
import json
import os
import struct
import subprocess
import sys
import traceback


def _read_message():
    raw = sys.stdin.buffer.read(4)
    if len(raw) < 4:
        return None
    (length,) = struct.unpack('<I', raw)
    body = sys.stdin.buffer.read(length)
    if len(body) < length:
        return None
    return json.loads(body.decode('utf-8'))


def _write_message(obj):
    body = json.dumps(obj).encode('utf-8')
    sys.stdout.buffer.write(struct.pack('<I', len(body)))
    sys.stdout.buffer.write(body)
    sys.stdout.buffer.flush()


def _handle(msg):
    out = {'id': msg.get('id')}
    if msg.get('type') == 'ping':
        out['type'] = 'pong'
        out['platform'] = sys.platform
        out['cwd'] = os.getcwd()
        return out

    command = msg.get('command')
    if not isinstance(command, str) or not command.strip():
        out['error'] = 'command is required'
        return out

    cwd = msg.get('cwd') or None
    timeout_ms = int(msg.get('timeoutMs') or 60000)
    env = os.environ.copy()
    if isinstance(msg.get('env'), dict):
        env.update({k: str(v) for k, v in msg['env'].items()})

    try:
        result = subprocess.run(
            command, shell=True, cwd=cwd, env=env,
            capture_output=True, text=True, timeout=timeout_ms / 1000.0,
        )
        out.update(
            stdout=result.stdout,
            stderr=result.stderr,
            exitCode=result.returncode,
            cwd=cwd or os.getcwd(),
        )
    except subprocess.TimeoutExpired as e:
        out.update(
            error=f'timed out after {timeout_ms} ms',
            stdout=(e.stdout or '') if isinstance(e.stdout, str) else '',
            stderr=(e.stderr or '') if isinstance(e.stderr, str) else '',
            exitCode=-1,
        )
    except FileNotFoundError as e:
        out['error'] = f'command not found: {e}'
    except Exception:  # noqa: BLE001
        out['error'] = traceback.format_exc(limit=2)
    return out


def main():
    while True:
        try:
            msg = _read_message()
        except Exception as e:  # noqa: BLE001
            sys.stderr.write(f'kyoto-shell: read error: {e}\n')
            return
        if msg is None:
            return
        try:
            _write_message(_handle(msg))
        except Exception as e:  # noqa: BLE001
            try:
                _write_message({'id': msg.get('id') if isinstance(msg, dict) else None,
                                'error': f'host exception: {e}'})
            except Exception:
                return


if __name__ == '__main__':
    main()
PYEOF

chmod +x "$HOST_SCRIPT"

# Native messaging requires Chrome to run the host as an executable. On
# Linux/macOS we make the .py executable directly with its shebang.
# Some distros don't have python3 in env's default PATH for headless
# launches; use an explicit launcher to be safe.
LAUNCHER="$INSTALL_DIR/kyoto-shell.sh"
cat > "$LAUNCHER" <<LAUNCHEREOF
#!/usr/bin/env bash
exec "$PY_PATH" "$HOST_SCRIPT" "\$@"
LAUNCHEREOF
chmod +x "$LAUNCHER"

write_manifest() {
  local dir="$1"
  # Only write to dirs whose parent (the browser's user-data dir) exists.
  local parent="$(dirname "$dir")"
  if [[ ! -d "$parent" ]]; then return 0; fi
  mkdir -p "$dir"
  cat > "$dir/$HOST_NAME.json" <<MANIFEST
{
  "name": "$HOST_NAME",
  "description": "Kyoto shell bridge (extension <-> local shell)",
  "path": "$LAUNCHER",
  "type": "stdio",
  "allowed_origins": [
    "chrome-extension://$EXT_ID/"
  ]
}
MANIFEST
  c_green "  ✓ $dir/$HOST_NAME.json"
}

c_green "Installing Kyoto shell bridge…"
c_dim "  Platform:   $PLATFORM"
c_dim "  Python:     $PY_PATH"
c_dim "  Host:       $HOST_SCRIPT"
c_dim "  Launcher:   $LAUNCHER"
c_dim "  Allowed ID: $EXT_ID"
echo

c_green "Writing native messaging manifests:"
WROTE=0
for dir in "${MANIFEST_DIRS[@]}"; do
  if write_manifest "$dir"; then
    if [[ -f "$dir/$HOST_NAME.json" ]]; then WROTE=$((WROTE + 1)); fi
  fi
done

if [[ "$WROTE" -eq 0 ]]; then
  c_yellow "No browser user-data directories found — wrote nothing."
  c_yellow "Open Chrome (or another Chromium-based browser) at least once, then re-run."
  exit 2
fi

echo
c_green "Done. $WROTE manifest(s) installed."
c_dim "Restart Chrome (close all windows), then test with:"
c_dim "  In Kyoto: /sh echo hello"
