# Kyoto native messaging host installer (Windows / PowerShell).
#
# Usage:
#   irm https://raw.githubusercontent.com/ankit-pn/kyoto-shell-bridge/main/install.ps1 | iex
#   (then it asks for the extension ID, OR set $env:KYOTO_EXT_ID first)
#
#   With explicit ID:
#     $env:KYOTO_EXT_ID = "<id>"; irm https://.../install.ps1 | iex
#
# Find your extension ID at chrome://extensions (Developer mode enabled).

param(
  [string]$ExtensionId = $env:KYOTO_EXT_ID
)

$ErrorActionPreference = 'Stop'
$HostName = 'com.kyoto.shell'

if (-not $ExtensionId) {
  $ExtensionId = Read-Host 'Enter your Kyoto extension ID (32 letters, a-p)'
}
if (-not $ExtensionId) {
  Write-Host 'Error: extension ID required.' -ForegroundColor Red
  exit 1
}

# Find python 3.7+
$Py = $null
foreach ($candidate in @('python', 'python3', 'py')) {
  try {
    $v = & $candidate -c "import sys; print('%d.%d' % sys.version_info[:2])"
    if ($LASTEXITCODE -eq 0) {
      $parts = $v.Trim().Split('.')
      if ([int]$parts[0] -ge 3 -and [int]$parts[1] -ge 7) {
        $Py = (Get-Command $candidate).Source
        break
      }
    }
  } catch {}
}
if (-not $Py) {
  Write-Host 'Error: Python 3.7+ is required.' -ForegroundColor Red
  Write-Host 'Install from https://www.python.org/downloads/  (check "Add to PATH")'
  exit 1
}

$InstallDir = Join-Path $env:LOCALAPPDATA 'Kyoto'
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
$HostScript = Join-Path $InstallDir 'kyoto-shell.py'
$Launcher   = Join-Path $InstallDir 'kyoto-shell.bat'

# Embedded host script — keep in sync with install/kyoto-shell.py.
$HostBody = @'
#!/usr/bin/env python3
"""Kyoto native messaging host (embedded by install.ps1).

Supports both synchronous exec (legacy) and background jobs with
idle-timeout-based killing. See install/kyoto-shell.py for the
canonical, fully-commented copy.
"""
import json, os, struct, subprocess, sys, threading, time, traceback, uuid

_write_lock = threading.Lock()

def _read_message():
    raw = sys.stdin.buffer.read(4)
    if len(raw) < 4: return None
    (length,) = struct.unpack('<I', raw)
    body = sys.stdin.buffer.read(length)
    if len(body) < length: return None
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
    proc = subprocess.Popen(command, shell=True, cwd=cwd, env=env,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1,
        encoding='utf-8', errors='replace')
    job_id = 'job_' + uuid.uuid4().hex[:12]
    job = {'proc': proc, 'stdout': [], 'stderr': [], 'exit_code': None,
        'done': False, 'killed_reason': None, 'last_output': time.time(),
        'started_at': time.time(), 'idle_timeout_ms': max(2000, int(idle_timeout_ms)),
        'command': command[:240], 'cwd': cwd or os.getcwd(), 'lock': threading.Lock()}
    with JOBS_LOCK: JOBS[job_id] = job
    def _reader(stream, key):
        try:
            for line in iter(stream.readline, ''):
                with job['lock']:
                    job[key].append(line); job['last_output'] = time.time()
        except: pass
        finally:
            try: stream.close()
            except: pass
    threading.Thread(target=_reader, args=(proc.stdout, 'stdout'), daemon=True).start()
    threading.Thread(target=_reader, args=(proc.stderr, 'stderr'), daemon=True).start()
    def _waiter():
        try: ec = proc.wait()
        except: ec = -1
        time.sleep(0.05)
        with job['lock']:
            job['exit_code'] = ec; job['done'] = True; job['done_at'] = time.time()
    threading.Thread(target=_waiter, daemon=True).start()
    return job_id, job

def _job_snapshot(job, drain=False):
    now = time.time()
    with job['lock']:
        s_out = ''.join(job['stdout']); s_err = ''.join(job['stderr'])
        if drain: job['stdout'].clear(); job['stderr'].clear()
        return {'stdout': s_out, 'stderr': s_err, 'exitCode': job['exit_code'],
            'done': job['done'], 'killedReason': job['killed_reason'],
            'idleMs': int((now - job['last_output']) * 1000),
            'elapsedMs': int((now - job['started_at']) * 1000),
            'idleTimeoutMs': job['idle_timeout_ms']}

def _wait_for_done(job, max_wait_s=None):
    deadline = (time.time() + max_wait_s) if max_wait_s is not None else None
    while True:
        with job['lock']:
            if job['done']: return True
        if deadline is not None and time.time() >= deadline: return False
        time.sleep(0.1)

def _reaper_loop():
    while True:
        time.sleep(REAPER_TICK_S)
        now = time.time()
        with JOBS_LOCK: items = list(JOBS.items())
        to_evict = []
        for jid, j in items:
            with j['lock']:
                done_at = j.get('done_at')
                if done_at is not None and (now - done_at) > DONE_JOB_TTL_S:
                    to_evict.append(jid); continue
                if j['done'] or j['killed_reason']: continue
                idle_ms = (now - j['last_output']) * 1000
                if idle_ms <= j['idle_timeout_ms']: continue
                j['killed_reason'] = f'idle for {int(idle_ms)}ms (limit {j["idle_timeout_ms"]}ms)'
            try: j['proc'].kill()
            except: pass
        if to_evict:
            with JOBS_LOCK:
                for jid in to_evict: JOBS.pop(jid, None)
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
    try: job_id, _j = _spawn(cmd, cwd, env, idle_ms)
    except FileNotFoundError as e: return {'id': msg.get('id'), 'error': f'command not found: {e}'}
    except Exception as e: return {'id': msg.get('id'), 'error': f'spawn failed: {e}'}
    return {'id': msg.get('id'), 'type': 'job_started', 'jobId': job_id, 'idleTimeoutMs': idle_ms}

def _poll_msg(msg):
    job_id = msg.get('jobId')
    with JOBS_LOCK: job = JOBS.get(job_id)
    if not job: return {'id': msg.get('id'), 'error': f'no such job: {job_id}'}
    snap = _job_snapshot(job, drain=bool(msg.get('clear')))
    return {'id': msg.get('id'), 'type': 'job_status', 'jobId': job_id, **snap}

def _kill_msg(msg):
    job_id = msg.get('jobId')
    with JOBS_LOCK: job = JOBS.get(job_id)
    if not job: return {'id': msg.get('id'), 'error': f'no such job: {job_id}'}
    with job['lock']:
        if not job['killed_reason']: job['killed_reason'] = msg.get('reason') or 'requested'
    try: job['proc'].kill()
    except: pass
    return {'id': msg.get('id'), 'type': 'job_killed', 'jobId': job_id}

def _list_msg(msg):
    now = time.time()
    with JOBS_LOCK: items = list(JOBS.items())
    out = []
    for jid, j in items:
        with j['lock']:
            out.append({'jobId': jid, 'command': j['command'], 'cwd': j['cwd'],
                'done': j['done'], 'exitCode': j['exit_code'],
                'killedReason': j['killed_reason'],
                'idleMs': int((now - j['last_output']) * 1000),
                'elapsedMs': int((now - j['started_at']) * 1000),
                'idleTimeoutMs': j['idle_timeout_ms']})
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
        try: job_id, job = _spawn(cmd, cwd, env, int(idle_ms))
        except FileNotFoundError as e: return {'id': msg.get('id'), 'error': f'command not found: {e}'}
        except Exception as e: return {'id': msg.get('id'), 'error': f'spawn failed: {e}'}
        _wait_for_done(job)
        snap = _job_snapshot(job)
        out = {'id': msg.get('id'), 'cwd': job['cwd'], **snap, 'jobId': job_id}
        if snap['killedReason']:
            out['error'] = f'killed: {snap["killedReason"]}'
            if out.get('exitCode') is None: out['exitCode'] = -1
        return out
    timeout_ms = int(msg.get('timeoutMs') or 60000)
    try:
        result = subprocess.run(cmd, shell=True, cwd=cwd, env=env,
            capture_output=True, text=True, timeout=timeout_ms / 1000.0)
        return {'id': msg.get('id'), 'stdout': result.stdout, 'stderr': result.stderr,
            'exitCode': result.returncode, 'cwd': cwd or os.getcwd()}
    except subprocess.TimeoutExpired as e:
        return {'id': msg.get('id'), 'error': f'timed out after {timeout_ms} ms',
            'stdout': (e.stdout or '') if isinstance(e.stdout, str) else '',
            'stderr': (e.stderr or '') if isinstance(e.stderr, str) else '', 'exitCode': -1}
    except FileNotFoundError as e:
        return {'id': msg.get('id'), 'error': f'command not found: {e}'}
    except Exception:
        return {'id': msg.get('id'), 'error': traceback.format_exc(limit=2)}

def _handle(msg):
    t = msg.get('type')
    if t == 'ping':
        return {'id': msg.get('id'), 'type': 'pong', 'platform': sys.platform,
            'cwd': os.getcwd(), 'jobs': True}
    if t == 'exec_bg': return _start_job_msg(msg)
    if t == 'job_poll': return _poll_msg(msg)
    if t == 'job_kill': return _kill_msg(msg)
    if t == 'jobs_list': return _list_msg(msg)
    return _sync_exec_msg(msg)

def main():
    while True:
        try: msg = _read_message()
        except Exception as e:
            sys.stderr.write(f'kyoto-shell: read error: {e}\n'); return
        if msg is None: return
        try: _write_message(_handle(msg))
        except Exception as e:
            try: _write_message({'id': msg.get('id') if isinstance(msg, dict) else None,
                                 'error': f'host exception: {e}'})
            except: return

if __name__ == '__main__':
    main()
'@
Set-Content -Path $HostScript -Value $HostBody -NoNewline -Encoding UTF8

# Windows needs a .bat / .cmd launcher to be the native host (Chrome
# can't directly run a .py file).
$BatBody = "@echo off`r`n""$Py"" ""$HostScript"" %*`r`n"
Set-Content -Path $Launcher -Value $BatBody -NoNewline -Encoding ASCII

# Manifest is referenced by a per-user registry key under each browser.
$ManifestPath = Join-Path $InstallDir "$HostName.json"
$Manifest = @{
  name = $HostName
  description = 'Kyoto shell bridge (extension <-> local shell)'
  path = $Launcher
  type = 'stdio'
  allowed_origins = @("chrome-extension://$ExtensionId/")
} | ConvertTo-Json -Depth 4
Set-Content -Path $ManifestPath -Value $Manifest -Encoding UTF8

# Browsers to register with. Each gets its own registry entry pointing
# at the same manifest file.
$Browsers = @(
  'HKCU:\Software\Google\Chrome\NativeMessagingHosts',
  'HKCU:\Software\Chromium\NativeMessagingHosts',
  'HKCU:\Software\Microsoft\Edge\NativeMessagingHosts',
  'HKCU:\Software\BraveSoftware\Brave-Browser\NativeMessagingHosts',
  'HKCU:\Software\Vivaldi\NativeMessagingHosts',
  'HKCU:\Software\Opera Software\Opera Stable\NativeMessagingHosts'
)

$Wrote = 0
foreach ($parent in $Browsers) {
  try {
    New-Item -Path $parent -Force | Out-Null
    New-Item -Path (Join-Path $parent $HostName) -Force | Out-Null
    Set-ItemProperty -Path (Join-Path $parent $HostName) -Name '(Default)' -Value $ManifestPath
    Write-Host "  + $parent\$HostName" -ForegroundColor Green
    $Wrote++
  } catch {
    # Browser not installed; skip.
  }
}

Write-Host ''
Write-Host 'Installed Kyoto shell bridge.' -ForegroundColor Green
Write-Host "  Python:     $Py" -ForegroundColor DarkGray
Write-Host "  Host:       $HostScript" -ForegroundColor DarkGray
Write-Host "  Launcher:   $Launcher" -ForegroundColor DarkGray
Write-Host "  Manifest:   $ManifestPath" -ForegroundColor DarkGray
Write-Host "  Registered: $Wrote browser(s)" -ForegroundColor DarkGray
Write-Host ''
Write-Host 'Restart Chrome (close all windows), then in Kyoto try:  /sh echo hello' -ForegroundColor DarkGray

if ($Wrote -eq 0) {
  Write-Host 'No browser registries were written. Open Chrome at least once and re-run.' -ForegroundColor Yellow
  exit 2
}
