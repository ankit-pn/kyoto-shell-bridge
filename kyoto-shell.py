#!/usr/bin/env python3
"""
Kyoto native messaging host.

Speaks Chrome's native messaging protocol on stdin/stdout:
  - 4-byte little-endian length prefix
  - JSON body of that length

Accepted message shapes:
  { "id": "<corr>", "command": "<shell command>",
    "cwd": "<path>"?, "timeoutMs": <int>?, "env": { ... }? }

Responds with the same `id` and:
  { "id": "<corr>", "stdout": "...", "stderr": "...",
    "exitCode": <int>, "cwd": "<absolute>" }
  or
  { "id": "<corr>", "error": "<message>" }

Runs commands via the user's shell. The host has the user's full
filesystem and network access; treat it accordingly.
"""

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
            command,
            shell=True,
            cwd=cwd,
            env=env,
            capture_output=True,
            text=True,
            timeout=timeout_ms / 1000.0,
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
