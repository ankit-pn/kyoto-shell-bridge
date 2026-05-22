#!/usr/bin/env python3
"""
Kyoto native messaging host.

Speaks Chrome's native messaging protocol on stdin/stdout:
  - 4-byte little-endian length prefix
  - JSON body of that length

Accepted message shapes:
  Synchronous exec (legacy):
    { "id", "command", "cwd"?, "timeoutMs"?, "env"?, "idleTimeoutMs"? }
    → { "id", "stdout", "stderr", "exitCode", "cwd" }
    If `idleTimeoutMs` is set, runs via the same backgrounded Popen
    machinery and only kills the process when it stops producing
    output for that long — instead of using a wall-clock timeout.

  Background exec (new):
    { "id", "type": "exec_bg", "command", "cwd"?, "env"?, "idleTimeoutMs"? }
    → { "id", "type": "job_started", "jobId", "idleTimeoutMs" }

  Poll / wait / kill / list:
    { "id", "type": "job_poll", "jobId", "clear"? }
       → { "id", "stdout", "stderr", "exitCode"?, "done", "idleMs", "elapsedMs", "killedReason"? }
    { "id", "type": "job_kill", "jobId", "reason"? }
       → { "id", "type": "job_killed", "jobId" }
    { "id", "type": "jobs_list" }
       → { "id", "type": "jobs", "jobs": [...] }

  Ping:
    { "id", "type": "ping" } → { "id", "type": "pong", "platform", "cwd", "jobs": true }

Runs commands via the user's shell. The host has the user's full
filesystem and network access; treat it accordingly.
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


# --- protocol ---------------------------------------------------------------

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


# --- job tracking -----------------------------------------------------------

JOBS = {}            # jobId -> dict of job state
JOBS_LOCK = threading.Lock()
DEFAULT_IDLE_MS = 60000
REAPER_TICK_S = 3.0


def _spawn(command, cwd, env, idle_timeout_ms):
    """Spawn a subprocess and register it as a tracked job."""
    proc = subprocess.Popen(
        command, shell=True, cwd=cwd, env=env,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        text=True, bufsize=1,
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
        # Give the reader threads one tick to drain any final lines
        # before we mark the job done.
        time.sleep(0.05)
        with job['lock']:
            job['exit_code'] = ec
            job['done'] = True

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
    """Block until the job is done. If max_wait_s is given, return False on timeout."""
    deadline = (time.time() + max_wait_s) if max_wait_s is not None else None
    while True:
        with job['lock']:
            if job['done']:
                return True
        if deadline is not None and time.time() >= deadline:
            return False
        time.sleep(0.1)


def _reaper_loop():
    """Kill jobs that have gone silent for longer than their idle timeout."""
    while True:
        time.sleep(REAPER_TICK_S)
        now = time.time()
        with JOBS_LOCK:
            items = list(JOBS.items())
        for _jid, j in items:
            with j['lock']:
                if j['done'] or j['killed_reason']:
                    continue
                idle_ms = (now - j['last_output']) * 1000
                if idle_ms <= j['idle_timeout_ms']:
                    continue
                reason = f'idle for {int(idle_ms)}ms (limit {j["idle_timeout_ms"]}ms)'
                j['killed_reason'] = reason
            try:
                j['proc'].kill()
            except Exception:
                pass


threading.Thread(target=_reaper_loop, daemon=True).start()


# --- message handlers -------------------------------------------------------

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
    return {
        'id': msg.get('id'),
        'type': 'job_started',
        'jobId': job_id,
        'idleTimeoutMs': idle_ms,
    }


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
    """
    Synchronous exec: legacy behaviour, plus optional idle timeout. If
    idleTimeoutMs is present, we go through the Popen+reaper machinery
    and block until the process is reaped (either it finished, or it
    was killed for idleness). Otherwise we use subprocess.run with a
    hard wall-clock timeout.
    """
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
        # Wait for the reaper or natural completion.
        _wait_for_done(job)
        snap = _job_snapshot(job)
        out = {'id': msg.get('id'), 'cwd': job['cwd'], **snap, 'jobId': job_id}
        if snap['killedReason']:
            out['error'] = f'killed: {snap["killedReason"]}'
            if out.get('exitCode') is None:
                out['exitCode'] = -1
        return out

    # Legacy wall-clock timeout path.
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
        return {
            'id': msg.get('id'),
            'type': 'pong',
            'platform': sys.platform,
            'cwd': os.getcwd(),
            'jobs': True,
        }
    if t == 'exec_bg':
        return _start_job_msg(msg)
    if t == 'job_poll':
        return _poll_msg(msg)
    if t == 'job_kill':
        return _kill_msg(msg)
    if t == 'jobs_list':
        return _list_msg(msg)
    # Default: synchronous exec (legacy + optional idleTimeoutMs).
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
                _write_message({
                    'id': msg.get('id') if isinstance(msg, dict) else None,
                    'error': f'host exception: {e}',
                })
            except Exception:
                return


if __name__ == '__main__':
    main()
