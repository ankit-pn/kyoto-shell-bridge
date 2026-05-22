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
"""Kyoto native messaging host (embedded by install.sh).

Supports both synchronous exec (legacy) and background jobs with
idle-timeout-based killing. See install/kyoto-shell.py for the
canonical, fully-commented copy.
"""
import json
import os
import struct
import subprocess
import sys
import threading
import time
import traceback
import uuid


_write_lock = threading.Lock()


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
    with _write_lock:
        sys.stdout.buffer.write(struct.pack('<I', len(body)))
        sys.stdout.buffer.write(body)
        sys.stdout.buffer.flush()


JOBS = {}
JOBS_LOCK = threading.Lock()
DEFAULT_IDLE_MS = 60000
REAPER_TICK_S = 3.0
DONE_JOB_TTL_S = 1800.0


def _spawn(command, cwd, env, idle_timeout_ms):
    proc = subprocess.Popen(
        command, shell=True, cwd=cwd, env=env,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        text=True, bufsize=1, encoding='utf-8', errors='replace',
    )
    job_id = 'job_' + uuid.uuid4().hex[:12]
    job = {
        'proc': proc,
        'stdout': [],
        'stderr': [],
        'exit_code': None,
        'done': False,
        'killed_reason': None,
        'last_output': time.time(),
        'started_at': time.time(),
        'idle_timeout_ms': max(2000, int(idle_timeout_ms)),
        'command': command[:240],
        'cwd': cwd or os.getcwd(),
        'lock': threading.Lock(),
    }
    with JOBS_LOCK:
        JOBS[job_id] = job

    def _reader(stream, key):
        try:
            for line in iter(stream.readline, ''):
                with job['lock']:
                    job[key].append(line)
                    job['last_output'] = time.time()
        except Exception:
            pass
        finally:
            try:
                stream.close()
            except Exception:
                pass

    threading.Thread(target=_reader, args=(proc.stdout, 'stdout'), daemon=True).start()
    threading.Thread(target=_reader, args=(proc.stderr, 'stderr'), daemon=True).start()

    def _waiter():
        try:
            ec = proc.wait()
        except Exception:
            ec = -1
        time.sleep(0.05)
        with job['lock']:
            job['exit_code'] = ec
            job['done'] = True
            job['done_at'] = time.time()

    threading.Thread(target=_waiter, daemon=True).start()
    return job_id, job


def _job_snapshot(job, *, drain=False):
    now = time.time()
    with job['lock']:
        stdout_text = ''.join(job['stdout'])
        stderr_text = ''.join(job['stderr'])
        if drain:
            job['stdout'].clear()
            job['stderr'].clear()
        return {
            'stdout': stdout_text,
            'stderr': stderr_text,
            'exitCode': job['exit_code'],
            'done': job['done'],
            'killedReason': job['killed_reason'],
            'idleMs': int((now - job['last_output']) * 1000),
            'elapsedMs': int((now - job['started_at']) * 1000),
            'idleTimeoutMs': job['idle_timeout_ms'],
        }


def _wait_for_done(job, *, max_wait_s=None):
    deadline = (time.time() + max_wait_s) if max_wait_s is not None else None
    while True:
        with job['lock']:
            if job['done']:
                return True
        if deadline is not None and time.time() >= deadline:
            return False
        time.sleep(0.1)


def _reaper_loop():
    while True:
        time.sleep(REAPER_TICK_S)
        now = time.time()
        with JOBS_LOCK:
            items = list(JOBS.items())
        to_evict = []
        for jid, j in items:
            with j['lock']:
                done_at = j.get('done_at')
                if done_at is not None and (now - done_at) > DONE_JOB_TTL_S:
                    to_evict.append(jid)
                    continue
                if j['done'] or j['killed_reason']:
                    continue
                idle_ms = (now - j['last_output']) * 1000
                if idle_ms <= j['idle_timeout_ms']:
                    continue
                j['killed_reason'] = f'idle for {int(idle_ms)}ms (limit {j["idle_timeout_ms"]}ms)'
            try:
                j['proc'].kill()
            except Exception:
                pass
        if to_evict:
            with JOBS_LOCK:
                for jid in to_evict:
                    JOBS.pop(jid, None)


threading.Thread(target=_reaper_loop, daemon=True).start()


def _start_job_msg(msg):
    cmd = msg.get('command')
    if not isinstance(cmd, str) or not cmd.strip():
        return {'id': msg.get('id'), 'error': 'command is required'}
    cwd = msg.get('cwd') or None
    env = os.environ.copy()
    if isinstance(msg.get('env'), dict):
        env.update({k: str(v) for k, v in msg['env'].items()})
    idle_ms = int(msg.get('idleTimeoutMs') or DEFAULT_IDLE_MS)
    try:
        job_id, _job = _spawn(cmd, cwd, env, idle_ms)
    except FileNotFoundError as e:
        return {'id': msg.get('id'), 'error': f'command not found: {e}'}
    except Exception as e:
        return {'id': msg.get('id'), 'error': f'spawn failed: {e}'}
    return {'id': msg.get('id'), 'type': 'job_started', 'jobId': job_id, 'idleTimeoutMs': idle_ms}


def _poll_msg(msg):
    job_id = msg.get('jobId')
    with JOBS_LOCK:
        job = JOBS.get(job_id)
    if not job:
        return {'id': msg.get('id'), 'error': f'no such job: {job_id}'}
    snap = _job_snapshot(job, drain=bool(msg.get('clear')))
    return {'id': msg.get('id'), 'type': 'job_status', 'jobId': job_id, **snap}


def _kill_msg(msg):
    job_id = msg.get('jobId')
    with JOBS_LOCK:
        job = JOBS.get(job_id)
    if not job:
        return {'id': msg.get('id'), 'error': f'no such job: {job_id}'}
    with job['lock']:
        if not job['killed_reason']:
            job['killed_reason'] = msg.get('reason') or 'requested'
    try:
        job['proc'].kill()
    except Exception:
        pass
    return {'id': msg.get('id'), 'type': 'job_killed', 'jobId': job_id}


def _list_msg(msg):
    now = time.time()
    with JOBS_LOCK:
        items = list(JOBS.items())
    out = []
    for jid, j in items:
        with j['lock']:
            out.append({
                'jobId': jid,
                'command': j['command'],
                'cwd': j['cwd'],
                'done': j['done'],
                'exitCode': j['exit_code'],
                'killedReason': j['killed_reason'],
                'idleMs': int((now - j['last_output']) * 1000),
                'elapsedMs': int((now - j['started_at']) * 1000),
                'idleTimeoutMs': j['idle_timeout_ms'],
            })
    return {'id': msg.get('id'), 'type': 'jobs', 'jobs': out}


def _sync_exec_msg(msg):
    cmd = msg.get('command')
    if not isinstance(cmd, str) or not cmd.strip():
        return {'id': msg.get('id'), 'error': 'command is required'}
    cwd = msg.get('cwd') or None
    env = os.environ.copy()
    if isinstance(msg.get('env'), dict):
        env.update({k: str(v) for k, v in msg['env'].items()})

    idle_ms = msg.get('idleTimeoutMs')
    if idle_ms is not None:
        try:
            job_id, job = _spawn(cmd, cwd, env, int(idle_ms))
        except FileNotFoundError as e:
            return {'id': msg.get('id'), 'error': f'command not found: {e}'}
        except Exception as e:
            return {'id': msg.get('id'), 'error': f'spawn failed: {e}'}
        _wait_for_done(job)
        snap = _job_snapshot(job)
        out = {'id': msg.get('id'), 'cwd': job['cwd'], **snap, 'jobId': job_id}
        if snap['killedReason']:
            out['error'] = f'killed: {snap["killedReason"]}'
            if out.get('exitCode') is None:
                out['exitCode'] = -1
        return out

    timeout_ms = int(msg.get('timeoutMs') or 60000)
    try:
        result = subprocess.run(
            cmd, shell=True, cwd=cwd, env=env,
            capture_output=True, text=True, timeout=timeout_ms / 1000.0,
        )
        return {
            'id': msg.get('id'),
            'stdout': result.stdout,
            'stderr': result.stderr,
            'exitCode': result.returncode,
            'cwd': cwd or os.getcwd(),
        }
    except subprocess.TimeoutExpired as e:
        return {
            'id': msg.get('id'),
            'error': f'timed out after {timeout_ms} ms',
            'stdout': (e.stdout or '') if isinstance(e.stdout, str) else '',
            'stderr': (e.stderr or '') if isinstance(e.stderr, str) else '',
            'exitCode': -1,
        }
    except FileNotFoundError as e:
        return {'id': msg.get('id'), 'error': f'command not found: {e}'}
    except Exception:
        return {'id': msg.get('id'), 'error': traceback.format_exc(limit=2)}


def _handle(msg):
    t = msg.get('type')
    if t == 'ping':
        return {'id': msg.get('id'), 'type': 'pong', 'platform': sys.platform, 'cwd': os.getcwd(), 'jobs': True}
    if t == 'exec_bg':
        return _start_job_msg(msg)
    if t == 'job_poll':
        return _poll_msg(msg)
    if t == 'job_kill':
        return _kill_msg(msg)
    if t == 'jobs_list':
        return _list_msg(msg)
    return _sync_exec_msg(msg)


def main():
    while True:
        try:
            msg = _read_message()
        except Exception as e:
            sys.stderr.write(f'kyoto-shell: read error: {e}\n')
            return
        if msg is None:
            return
        try:
            _write_message(_handle(msg))
        except Exception as e:
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
