"""The public four-mode CLI. No operational knobs or implicit sampling."""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import signal
import shlex
import sys
import tempfile
import time

from .collectors import collect
from .model import Budget, Result
from .report import write_bundle
from .runtime import ControlLock, private_directory


class Parser(argparse.ArgumentParser):
    def error(self, message):
        self.print_help(sys.stderr)
        self.exit(64, '\napisix-diag: ' + message + '\n')


def main(argv=None):
    started = time.monotonic()
    parser = Parser(description='Bounded APISIX diagnostics; private evidence, no automatic upload.',
                    allow_abbrev=False)
    modes = parser.add_mutually_exclusive_group(required=True)
    for mode in ('cpu', 'memory', 'io', 'all'):
        modes.add_argument('--' + mode, dest='mode', action='store_const', const=mode)
    parser.add_argument('--output-dir', default='/tmp/apisix-diag', metavar='PATH',
                        help='private writable parent directory (default: /tmp/apisix-diag)')
    try:
        args = parser.parse_args(argv)
    except SystemExit as exc:
        return exc.code
    os.umask(0o077)
    results, run = [], None
    metadata = {'mode': args.mode, 'started_at_utc': datetime.now(timezone.utc).isoformat()}
    def interrupt(*_):
        raise KeyboardInterrupt
    old_handlers = {sig: signal.signal(sig, interrupt) for sig in (signal.SIGTERM, signal.SIGINT)}
    try:
        parent = private_directory(Path(args.output_dir))
        with ControlLock():
            run = Path(tempfile.mkdtemp(prefix='run-' + datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ') + '-', dir=parent))
            try:
                os.nice(10)
                results = collect(args.mode, run, Budget(40 if args.mode == 'all' else 20), started=started)
            except KeyboardInterrupt:
                results.append(Result('collection', 'interrupted', 'user_interrupt'))
            except Exception as exc:
                metadata['fatal'] = type(exc).__name__
                results.append(Result('collection', 'failed', type(exc).__name__))
            metadata['elapsed_seconds'] = time.monotonic() - started
            manifest_path = write_bundle(results, run, metadata)
            manifest = json.loads(manifest_path.read_text())
            print((run / 'summary.md').read_text())
            print('Evidence directory: ' + str(run))
            print('Copy once after collection: kubectl cp -n NAMESPACE -c CONTAINER ' + shlex.quote('POD:' + str(run)) + ' ./apisix-diag-evidence')
            return {'complete': 0, 'partial': 10, 'failed': 20, 'interrupted': 130}[manifest['status']]
    except BlockingIOError:
        print('apisix-diag: another collector is active or the 60 second cooldown has not expired', file=sys.stderr)
        return 75
    except KeyboardInterrupt:
        return 130
    except (OSError, ValueError) as exc:
        print('apisix-diag: cannot safely start/finalize: ' + str(exc), file=sys.stderr)
        if run:
            print('Partial evidence retained at: ' + str(run), file=sys.stderr)
        return 20
    finally:
        for sig, handler in old_handlers.items():
            signal.signal(sig, handler)
