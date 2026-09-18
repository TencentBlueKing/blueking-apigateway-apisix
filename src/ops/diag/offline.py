"""Offline verification and bounded perf parsing; never execute bundle strings."""
import csv
import io
import json
from pathlib import Path, PurePosixPath
import platform
import re
import shutil
import stat
import tempfile

from .elf import build_id
from .model import Budget
from .report import LIMITATIONS, verify_bundle
from .runtime import read_bounded, run_owned, write_private


def parse_hotspots(text):
    rows, invalid = [], False
    for line in text.splitlines():
        if not line.strip() or line.lstrip().startswith('#'):
            continue
        fields = [v.strip() for v in line.split(';', 4)]
        try:
            if len(fields) != 5:
                raise ValueError('invalid field count')
            overhead, period, samples, dso, symbol = fields
            float(overhead.rstrip('%'))
            period, samples = int(period), int(samples)
            if min(period, samples) < 0:
                raise ValueError('negative counts')
            unresolved = '[unknown]' in dso or '[unknown]' in symbol or bool(re.search(r'\b0x[0-9a-f]+\b', symbol))
            rows.append({'dso': dso, 'symbol': symbol, 'period': period, 'samples': samples,
                         'unresolved': unresolved})
        except ValueError:
            invalid = True
    count, periods = sum(r['samples'] for r in rows), sum(r['period'] for r in rows)
    for row in rows:
        row['sample_fraction'] = row['samples'] / count if count else None
        row['period_fraction'] = row['period'] / periods if periods else None
    return {'status': 'ok' if count > 0 and periods > 0 and not invalid else 'unavailable',
            'sample_count': count, 'period_total': periods, 'lost_samples': None,
            'unresolved_sample_fraction': sum(r['samples'] for r in rows if r['unresolved']) / count if count else None,
            'rows': rows, 'limitations': ['Lost samples unknown; denominator is captured user-space samples of one worker.']}


def validate_symbols(identities, root):
    root = Path(root).absolute()
    if root.is_symlink() or any(p.is_symlink() for p in root.parents):
        raise ValueError('symbol root has symlink components')
    result = []
    if not isinstance(identities, list) or len(identities) > 17:
        raise ValueError('invalid ELF identity list')
    for item in identities:
        name = item.get('path', '')
        path = PurePosixPath(name)
        if not path.is_absolute() or '..' in path.parts:
            raise ValueError('unsafe ELF path')
        local = root.joinpath(*path.parts[1:])
        if any(p.is_symlink() for p in [local, *local.parents] if p == root or root in p.parents):
            raise ValueError('symbol symlink')
        if not item.get('build_id'):
            continue  # unknown identity is never symbolized
        if not local.exists():
            continue  # retain unresolved addresses
        info = local.stat()
        if not stat.S_ISREG(info.st_mode) or info.st_size > 256 * 1024**2:
            raise ValueError('invalid symbol file')
        if build_id(local) != item['build_id']:
            raise ValueError('ELF Build ID mismatch: ' + name)
        result.append((name, local))
    return result



def anonymous_observation(entry, worker_labels, group_labels):
    value = json.loads(json.dumps(entry))
    data = value.get('observation', {})
    for key in ('finished_at_utc', 'monotonic_start', 'monotonic_end'):
        data.pop(key, None)
    workers = data.get('workers', {})
    for pid in workers:
        worker_labels.setdefault(pid, 'worker-' + str(len(worker_labels) + 1))
    if 'workers' in data:
        data['workers'] = {worker_labels[pid]: fields for pid, fields in workers.items()}
    counters = data.get('cgroup_counter_deltas', {})
    for path in counters:
        group_labels.setdefault(path, 'cgroup-' + str(len(group_labels) + 1))
    if 'cgroup_counter_deltas' in data:
        data['cgroup_counter_deltas'] = {group_labels[path]: fields for path, fields in counters.items()}
    for key in ('container_memory_before', 'container_memory_after'):
        for group in data.get(key, []):
            path = group.pop('path', None)
            group_labels.setdefault(path, 'cgroup-' + str(len(group_labels) + 1))
            group['group'] = group_labels[path]
    return value


def analyze(root, symbols=None):
    root = Path(root).absolute()
    manifest = verify_bundle(root)
    output = Path(tempfile.mkdtemp(prefix=root.name + '-analysis-', dir=root.parent))
    report = ['# APISIX offline analysis — PRIVATE', '',
              'Observed bundle status: ' + manifest['status'],
              'Integrity: all allowlisted files match checksums (not an authenticity guarantee).', '']
    observations = json.loads(read_bounded(root / 'observations.json', 2 * 1024**2).data['text'])
    report.append('## Observed counters')
    worker_labels, group_labels = {}, {}
    for entry in observations:
        entry = anonymous_observation(entry, worker_labels, group_labels)
        # Escape untrusted text inside a JSON code block with backticks escaped.
        report.extend(['', '```json', json.dumps(entry, indent=2).replace('`', '\\u0060'), '```'])
    native = {'status': 'unavailable', 'reason': 'perf_data_or_symbols_unavailable', 'lost_samples': None}
    if (root / 'cpu/perf.data').is_file() and symbols:
        if platform.system() != 'Linux' or not Path('/usr/bin/perf').is_file():
            native['reason'] = 'matching_linux_perf_required'
        else:
            identities = json.loads(read_bounded(root / 'cpu/elf-identities.json', 65536).data['text'])
            matched = validate_symbols(identities['files'], symbols)
            version_dir = output / 'version'
            version_dir.mkdir(mode=0o700)
            version = run_owned(['/usr/bin/perf', 'version'], 2, version_dir, Budget(20))
            actual = read_bounded(version_dir / 'stdout.txt', 65536).data.get('text', '').strip()
            build = json.loads(read_bounded(root / 'build/diag-build.json', 1024 * 1024).data['text'])
            if version.status != 'ok' or actual != build.get('perf_version'):
                native['reason'] = 'perf_version_mismatch'
            else:
                # A fresh symfs contains ONLY matching files; never pass the caller's
                # entire tree or a local same-name DSO to perf.
                with tempfile.TemporaryDirectory(prefix='symbols-', dir=output) as tmp:
                    symfs = Path(tmp)
                    total = 0
                    for name, path in matched:
                        total += path.stat().st_size
                        if total > 512 * 1024**2:
                            raise ValueError('symbol staging budget exceeded')
                        dest = symfs / name.lstrip('/')
                        dest.parent.mkdir(parents=True, mode=0o700, exist_ok=True)
                        shutil.copyfile(path, dest, follow_symlinks=False)
                        if build_id(dest) != build_id(path):
                            raise ValueError('symbol changed during staging')
                    perf_dir = output / 'perf'
                    perf_dir.mkdir(mode=0o700)
                    argv = ['/usr/bin/perf', '--buildid-dir', str(output / 'empty-cache'),
                            'report', '--stdio', '--no-children', '--no-demangle', '--ignore-vmlinux',
                            '--symfs', str(symfs), '-i', str(root / 'cpu/perf.data'),
                            '--percent-limit', '0', '--fields', 'overhead,period,sample,dso,symbol',
                            '--sort', 'dso,symbol', '--field-separator', ';']
                    result = run_owned(argv, 15, perf_dir, Budget(20))
                    native = parse_hotspots(read_bounded(perf_dir / 'stdout.txt', 65536).data.get('text', ''))
                    native['execution'] = result.data
                    if result.status != 'ok':
                        native.update(status='unavailable', reason=result.reason)
                    stream = io.StringIO()
                    writer = csv.DictWriter(stream, fieldnames=['dso', 'symbol', 'period', 'samples', 'unresolved',
                                                               'sample_fraction', 'period_fraction'])
                    writer.writeheader()
                    writer.writerows(native['rows'])
                    write_private(output / 'cpu-hotspots.csv', stream.getvalue().encode())
    write_private(output / 'native-analysis.json', (json.dumps(native, indent=2) + '\n').encode())
    public_native = {key: value for key, value in native.items() if key != 'execution'}
    report.extend(['', '## Native samples', json.dumps(public_native, indent=2).replace('`', '\\u0060'),
                   '', '## Candidate explanations',
                   'No automatic root-cause attribution. Counter changes and native symbols are evidence for further investigation.',
                   '', '## Cannot determine', *['- ' + value for value in LIMITATIONS],
                   '', '## Minimum next context',
                   'Correlate the observed symptom, sampling window/timezone, deployment changes and a healthy control bundle.'])
    write_private(output / 'analysis.md', ('\n'.join(report) + '\n').encode())
    return output / 'analysis.md'
