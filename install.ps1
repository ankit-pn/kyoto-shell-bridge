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
"""Kyoto native messaging host (embedded by install.ps1)."""
import json, os, struct, subprocess, sys, traceback

def _read_message():
    raw = sys.stdin.buffer.read(4)
    if len(raw) < 4: return None
    (length,) = struct.unpack('<I', raw)
    body = sys.stdin.buffer.read(length)
    if len(body) < length: return None
    return json.loads(body.decode('utf-8'))

def _write_message(obj):
    body = json.dumps(obj).encode('utf-8')
    sys.stdout.buffer.write(struct.pack('<I', len(body)))
    sys.stdout.buffer.write(body)
    sys.stdout.buffer.flush()

def _handle(msg):
    out = {'id': msg.get('id')}
    if msg.get('type') == 'ping':
        out['type'] = 'pong'; out['platform'] = sys.platform; out['cwd'] = os.getcwd()
        return out
    command = msg.get('command')
    if not isinstance(command, str) or not command.strip():
        out['error'] = 'command is required'; return out
    cwd = msg.get('cwd') or None
    timeout_ms = int(msg.get('timeoutMs') or 60000)
    env = os.environ.copy()
    if isinstance(msg.get('env'), dict):
        env.update({k: str(v) for k, v in msg['env'].items()})
    try:
        result = subprocess.run(command, shell=True, cwd=cwd, env=env,
            capture_output=True, text=True, timeout=timeout_ms / 1000.0)
        out.update(stdout=result.stdout, stderr=result.stderr,
            exitCode=result.returncode, cwd=cwd or os.getcwd())
    except subprocess.TimeoutExpired as e:
        out.update(error=f'timed out after {timeout_ms} ms',
            stdout=(e.stdout or '') if isinstance(e.stdout, str) else '',
            stderr=(e.stderr or '') if isinstance(e.stderr, str) else '', exitCode=-1)
    except FileNotFoundError as e:
        out['error'] = f'command not found: {e}'
    except Exception:
        out['error'] = traceback.format_exc(limit=2)
    return out

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
