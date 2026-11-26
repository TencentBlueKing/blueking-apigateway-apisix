"""Exact, fail-closed validation matrix and fixed recorder arguments."""
import hashlib
import re
from pathlib import Path

KEYS = ('target_build_id', 'collector_digest', 'architecture', 'kernel', 'perf_version',
        'budget_version', 'security')


def collector_digest(root=None):
    root = root or Path(__file__).resolve().parent.parent
    digest = hashlib.sha256()
    for path in sorted([root / 'apisix-diag', *list((root / 'diag').glob('*.py'))]):
        digest.update(str(path.relative_to(root)).encode() + b'\0')
        digest.update(path.read_bytes())
    return digest.hexdigest()


def validated(matrix, context, feature):
    if not isinstance(matrix, dict) or matrix.get('schema_version') != 1:
        return False
    if feature not in ('perf_ip', 'smaps_rollup') or not all(context.get(k) is not None for k in KEYS):
        return False
    if not context.get('target_build_id') or not context.get('collector_digest'):
        return False
    security = context.get('security')
    if (not isinstance(security, dict) or type(security.get('seccomp')) is not int
            or security['seccomp'] not in (0, 1, 2)
            or not isinstance(security.get('cap_eff'), str)
            or not re.fullmatch('[0-9a-fA-F]{8,16}', security['cap_eff'])
            or type(security.get('perf_event_paranoid')) is not int):
        return False
    entries = matrix.get('entries')
    if not isinstance(entries, list) or len(entries) > 128:
        return False
    for entry in entries:
        if (isinstance(entry, dict) and entry.get(feature + '_validated') is True
                and isinstance(entry.get('report'), str) and entry['report']
                and all(entry.get(key) == context[key] for key in KEYS)):
            return True
    return False


def perf_argv(pid, path, budget):
    return ['/usr/bin/perf', 'record', '-e', 'cpu-clock:u', '-F', str(budget.perf_hz),
            '-p', str(pid), '--no-inherit', '-m', '64K', '--no-buildid',
            '--no-buildid-cache', '-o', str(path), '--', '/bin/sleep', str(budget.perf_seconds)]
