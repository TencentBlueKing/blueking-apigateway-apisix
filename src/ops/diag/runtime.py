"""Bounded I/O, private paths, container-wide admission and owned runners."""
import errno
import fcntl
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import time
from typing import List, Optional

from .model import Budget, Identity, Result


class LimitReached(Exception):
    pass


def read_bounded(path: Path, max_bytes: int) -> Result:
    try:
        fd = os.open(str(path), os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(fd, 'rb') as stream:
            if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
                raise OSError('not a regular file')
            value = stream.read(max_bytes + 1)
        truncated = len(value) > max_bytes
        return Result(str(path), 'truncated' if truncated else 'ok',
                      'byte_limit' if truncated else None,
                      {'text': value[:max_bytes].decode('utf-8', 'replace')})
    except OSError as exc:
        return Result(str(path), 'skipped', type(exc).__name__)


def private_directory(path: Path) -> Path:
    """Walk without following symlinks, including intermediate components."""
    path = Path(os.path.abspath(str(path)))
    if path == Path('/') or path.parts[1] in ('proc', 'sys', 'dev'):
        raise OSError('output/control directory cannot be a pseudo filesystem')
    fd = os.open('/', os.O_RDONLY | os.O_DIRECTORY)
    try:
        for index, part in enumerate(path.parts[1:]):
            try:
                os.mkdir(part, 0o700, dir_fd=fd)
            except FileExistsError:
                pass
            next_fd = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd)
            fd = next_fd
            info = os.fstat(fd)
            leaf = index == len(path.parts) - 2
            trusted = info.st_uid in (0, os.geteuid())
            sticky = bool(info.st_mode & stat.S_ISVTX) and info.st_uid == 0 and not leaf
            if not trusted or ((info.st_mode & 0o022) and not sticky):
                raise OSError('untrusted owner or writable directory: ' + str(path))
            if leaf and (info.st_uid != os.geteuid() or info.st_mode & 0o077):
                raise OSError('directory must be owned by current uid and mode 0700')
    finally:
        os.close(fd)
    return path


def write_private(path: Path, value: bytes) -> None:
    fd = os.open(str(path), os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'wb') as stream:
        stream.write(value)


class ControlLock:
    def __init__(self, path: Optional[Path] = None):
        self.path = path or Path('/tmp/apisix-diag-control')
        self.fd = None

    def __enter__(self):
        private_directory(self.path)
        self.fd = os.open(str(self.path / 'lock'), os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        try:
            info = os.fstat(self.fd)
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or info.st_mode & 0o077:
                raise OSError('unsafe lock')
            fcntl.flock(self.fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            value = os.read(self.fd, 256).decode('ascii')
            now = time.monotonic()
            if value and now - float(value) < 60:
                raise BlockingIOError(errno.EAGAIN, '60 second cooldown')
            os.lseek(self.fd, 0, os.SEEK_SET)
            os.ftruncate(self.fd, 0)
            os.write(self.fd, str(now).encode('ascii'))
            return self
        except BaseException:
            os.close(self.fd)
            self.fd = None
            raise

    def __exit__(self, *args):
        if self.fd is not None:
            os.close(self.fd)
            self.fd = None


def identity_unchanged(before: Identity, after: Optional[Identity]) -> bool:
    return after is not None and before == after


def rss_bytes(pid: int) -> int:
    result = read_bounded(Path('/proc') / str(pid) / 'statm', 1024)
    try:
        return int(result.data['text'].split()[1]) * os.sysconf('SC_PAGE_SIZE')
    except (KeyError, ValueError, IndexError):
        return 0


def run_owned(argv: List[str], timeout_seconds: float, output_dir: Path,
              budget: Budget, guard=None) -> Result:
    """A separate watchdog owns ALL signals, and survives caller SIGKILL.

    EOF on its stdin cancels the recorder. The watchdog also has an independent
    wall deadline; no business PID is ever accepted by the signal function.
    """
    output_dir = private_directory(output_dir)
    started = time.monotonic()
    runner = Path(__file__).with_name('runner.py')
    env = {'PATH': '/usr/bin:/bin', 'LANG': 'C', 'HOME': str(output_dir),
           'PERF_CONFIG': '/dev/null', 'PERF_CONFIG_NOSYSTEM': '1',
           'PERF_CONFIG_NOGLOBAL': '1', 'DEBUGINFOD_URLS': '', 'PYTHONDONTWRITEBYTECODE': '1'}
    process = subprocess.Popen(
        [sys.executable, '-I', str(runner), str(timeout_seconds), str(output_dir),
         str(budget.child_as_bytes), str(budget.max_perf_bytes), *argv],
        stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        env=env, start_new_session=True)
    reason = None
    try:
        while process.poll() is None:
            if time.monotonic() - started > timeout_seconds + 1:
                reason = 'runner_deadline'
                break
            if rss_bytes(os.getpid()) + rss_bytes(process.pid) > budget.rss_stop_bytes:
                reason = 'collector_rss_limit'
                break
            if guard:
                reason = guard()
                if reason:
                    break
            time.sleep(.1)
    finally:
        # Closing the owned pipe requests cancellation without signalling any PID.
        process.stdin.close()
        try:
            process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            reason = 'runner_not_reaped'
    result_path = output_dir / 'runner.json'
    raw = read_bounded(result_path, 65536)
    try:
        value = json.loads(raw.data['text'])
        status = value.pop('status')
        child_reason = value.pop('reason', None)
    except (KeyError, ValueError):
        status, child_reason, value = 'failed', 'runner_result_unavailable', {}
    value.update(argv=argv, elapsed_seconds=time.monotonic() - started,
                 runner_reaped=process.poll() is not None,
                 reaped=value.get('reaped', False) and process.poll() is not None)
    if not value['reaped']:
        reason = reason or 'child_not_reaped'
    if reason:
        status, child_reason = 'interrupted', reason
    return Result('owned-child', status, child_reason, value)


class Session:
    def __init__(self, output_dir: Path, budget: Budget, started=None):
        self.output_dir = output_dir
        self.budget = budget
        self.started = time.monotonic() if started is None else started
        self.deadline = self.started + budget.deadline_seconds - 1  # reserve report time
        self.text_bytes = 0
        self.read_bytes = 0

    def check(self):
        if time.monotonic() >= self.deadline:
            raise LimitReached('deadline')
        if rss_bytes(os.getpid()) > self.budget.rss_stop_bytes:
            raise LimitReached('collector_rss_limit')

    def read(self, path: Path, limit=None) -> Result:
        self.check()
        remaining = self.budget.max_text_bytes - self.read_bytes
        if remaining <= 0:
            raise LimitReached('read_budget')
        result = read_bounded(path, min(limit or self.budget.read_bytes, remaining))
        self.read_bytes += len(result.data.get('text', '').encode())
        return result

    def save(self, name: str, data) -> str:
        value = (json.dumps(data, ensure_ascii=True, indent=2) + '\n').encode()
        if self.text_bytes + len(value) > self.budget.max_text_bytes // 2:
            raise LimitReached('text_budget')
        path = self.output_dir / name
        path.parent.mkdir(mode=0o700, exist_ok=True)
        write_private(path, value)
        self.text_bytes += len(value)
        return name

    def pause(self, seconds: float):
        until = time.monotonic() + seconds
        while time.monotonic() < until:
            self.check()
            time.sleep(min(.25, max(0, until - time.monotonic())))
