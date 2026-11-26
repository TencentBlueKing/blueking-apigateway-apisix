"""Internal watchdog. Not a production CLI. Only signals its own Popen group."""
import json
import os
from pathlib import Path
import resource
import selectors
import signal
import subprocess
import sys
import time


class OwnedChild:
    def __init__(self, argv, env, limits):
        def child_limits():
            resource.setrlimit(resource.RLIMIT_AS, (limits[0], limits[0]))
            resource.setrlimit(resource.RLIMIT_CPU, (3, 4))
            resource.setrlimit(resource.RLIMIT_FSIZE, (limits[1], limits[1]))
            resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
        self.process = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                        stderr=subprocess.PIPE, env=env, start_new_session=True,
                                        preexec_fn=child_limits)
        # This process is our unreaped child: its PID cannot be reused until wait.
        self.pid = self.process.pid

    def stop(self):
        for sig in (signal.SIGINT, signal.SIGKILL):
            if self.process.poll() is not None:
                break
            if os.getpgid(self.pid) != self.pid:
                raise RuntimeError('owned process group identity changed')
            os.killpg(self.pid, sig)
            try:
                self.process.wait(timeout=.2)
            except subprocess.TimeoutExpired:
                pass


def rss(pid):
    try:
        with open('/proc/%d/statm' % pid) as stream:
            return int(stream.read(1024).split()[1]) * os.sysconf('SC_PAGE_SIZE')
    except (OSError, ValueError, IndexError):
        return 0


def main():
    timeout, output, max_as, max_file = sys.argv[1:5]
    output = Path(output)
    started = time.monotonic()
    deadline = started + float(timeout)
    os.umask(0o077)
    os.nice(10)
    resource.setrlimit(resource.RLIMIT_AS, (int(max_as), int(max_as)))
    resource.setrlimit(resource.RLIMIT_CPU, (3, 4))
    resource.setrlimit(resource.RLIMIT_FSIZE, (int(max_file), int(max_file)))
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    child = None
    interrupted = [False]
    for sig in (signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, lambda *_: interrupted.__setitem__(0, True))
    status, reason = 'ok', None
    streams = []
    try:
        child = OwnedChild(sys.argv[5:], dict(os.environ), (int(max_as), int(max_file)))
        with selectors.DefaultSelector() as selector:
            selector.register(sys.stdin, selectors.EVENT_READ, ('parent', None))
            for label, pipe in [('stdout', child.process.stdout), ('stderr', child.process.stderr)]:
                fd = os.open(str(output / (label + '.txt')),
                             os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
                stream = os.fdopen(fd, 'wb')
                streams.append(stream)
                selector.register(pipe, selectors.EVENT_READ, (label, stream))
            counts = {'stdout': 0, 'stderr': 0}
            while True:
                if interrupted[0]:
                    status, reason = 'interrupted', 'signal'
                    break
                if time.monotonic() >= deadline:
                    status, reason = 'timeout', 'deadline'
                    break
                if rss(os.getpid()) + rss(os.getppid()) + rss(child.pid) > 96 * 1024 * 1024:
                    status, reason = 'interrupted', 'collector_rss_limit'
                    break
                for key, _ in selector.select(.1):
                    label, stream = key.data
                    data = os.read(key.fd, 8192)
                    if label == 'parent':
                        if not data:
                            interrupted[0] = True
                        continue
                    if not data:
                        selector.unregister(key.fileobj)
                        continue
                    available = max(0, 65536 - counts[label])
                    stream.write(data[:available])
                    counts[label] += len(data)
                    if counts[label] > 65536:
                        status, reason = 'truncated', 'output_limit'
                        interrupted[0] = True
                if reason == 'output_limit':
                    break
                if child.process.poll() is not None and len(selector.get_map()) == 1:
                    break
    except Exception as exc:
        status, reason = 'failed', type(exc).__name__
    finally:
        if child:
            child.stop()
            for pipe in (child.process.stdout, child.process.stderr):
                pipe.close()
        for stream in streams:
            stream.close()
    code = child.process.poll() if child else None
    if status == 'ok' and code != 0:
        status, reason = 'failed', 'nonzero_exit'
    value = {'status': status, 'reason': reason, 'returncode': code,
             'child_pid': child.pid if child else None, 'reaped': code is not None,
             'elapsed_seconds': time.monotonic() - started}
    fd = os.open(str(output / 'runner.json'), os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'w') as stream:
        json.dump(value, stream)


if __name__ == '__main__':
    main()
