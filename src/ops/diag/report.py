"""Private evidence bundles. Offline inputs are data, never commands."""
from dataclasses import asdict
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat

from . import __version__
from .runtime import read_bounded, write_private

STATUSES = {'ok', 'skipped', 'failed', 'timeout', 'truncated', 'interrupted'}
ROOT_FILES = {'manifest.json', 'summary.md', 'observations.json', 'collection.jsonl',
              'checksums.sha256', 'README.txt'}
CHILD_FILES = {
    'raw': {'baseline.json', 'cpu-before.json', 'cpu-after.json', 'memory-before.json',
            'memory-after.json', 'io-before.json', 'io-after.json'},
    'cpu': {'perf.data', 'perf.stderr.txt', 'stdout.txt', 'runner.json', 'maps.txt', 'elf-identities.json'},
    'build': {'diag-build.json'},
    'smaps-before': {'stdout.txt', 'stderr.txt', 'runner.json'},
    'smaps-after': {'stdout.txt', 'stderr.txt', 'runner.json'},
}
LIMITATIONS = [
    'CPU samples cover one worker user-space instruction addresses, not Lua call stacks or kernel hotspots.',
    'A native lock hotspot does not identify a plugin. Short-term memory growth does not prove a leak.',
    'Worker RSS may share pages; one worker PSS is not container memory.',
    'Network counters cover the current network namespace, may include sidecars, and are not gateway RPS.',
    'Hidden cgroup ancestors remain unknown. Missing or skipped data is not evidence of health.',
    'perf sample count, lost records and parseability require matching offline Linux tooling.',
]


def allowed(name):
    parts = PurePosixPath(name).parts
    if not name or name.startswith('/') or '..' in parts or str(PurePosixPath(name)) != name:
        return False
    return (len(parts) == 1 and name in ROOT_FILES or
            len(parts) == 2 and parts[0] in CHILD_FILES and parts[1] in CHILD_FILES[parts[0]])


def inventory(root):
    files = {}
    total, text = 0, 0
    for base, dirs, names in os.walk(root, followlinks=False):
        rel = Path(base).relative_to(root)
        for directory in dirs:
            path = Path(base) / directory
            if rel != Path('.') or directory not in CHILD_FILES or path.is_symlink():
                raise ValueError('unexpected directory or symlink')
        for name in names:
            path = Path(base) / name
            relative = path.relative_to(root).as_posix()
            info = path.lstat()
            if not allowed(relative) or not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
                raise ValueError('unexpected file, hardlink or symlink: ' + relative)
            cap = 16 * 1024**2 if relative == 'cpu/perf.data' else 2 * 1024**2
            if info.st_size > cap:
                raise ValueError('file exceeds budget')
            total += info.st_size
            if relative != 'cpu/perf.data':
                text += info.st_size
            files[relative] = info.st_size
    if total > 24 * 1024**2 or text > 2 * 1024**2:
        raise ValueError('bundle exceeds budget')
    return files


def digest_file(path):
    digest = hashlib.sha256()
    fd = os.open(str(path), os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, 'rb') as stream:
        if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
            raise ValueError('not a regular file')
        for _ in range(257):
            value = stream.read(65536)
            if not value:
                return digest.hexdigest()
            digest.update(value)
    raise ValueError('file exceeds budget')


def write_bundle(results, output_dir, metadata):
    root = output_dir
    for result in results:
        if result.status not in STATUSES:
            raise ValueError('unknown collector status')
    status = ('interrupted' if any(r.status == 'interrupted' and r.reason == 'user_interrupt' for r in results)
              else 'failed' if metadata.get('fatal') or not results
              else 'complete' if all(r.status == 'ok' for r in results) else 'partial')
    cpu = next((r for r in results if r.name == 'cpu.perf'), None)
    observations = []
    for result in results:
        if result.name.endswith('.delta'):
            observations.append({'id': result.name, 'observation': result.data,
                                 'evidence': [{'path': p, 'field': '$'} for p in result.evidence],
                                 'limitations': LIMITATIONS})
    manifest = dict(metadata, schema_version=1, tool_version=__version__, status=status,
                    privacy='private', budget_version=1,
                    target=cpu.data.get('target') if cpu else None,
                    collectors=[{'name': r.name, 'status': r.status, 'reason': r.reason,
                                 'evidence': r.evidence} for r in results], limitations=LIMITATIONS)
    summary = ['# APISIX diagnostics — PRIVATE', '', 'Status: ' + status,
               'Mode: ' + metadata.get('mode', 'unknown'),
               'Elapsed: %.3f seconds' % metadata.get('elapsed_seconds', 0), '']
    if metadata.get('mode') in ('cpu', 'all'):
        summary.append('CPU 原生采样未完成（含尚未离线校验的记录）。')
        if cpu and cpu.data.get('native_recording_created'):
            summary.append('perf.data 已生成；有效样本数、丢失样本及可解析性尚待离线验证。')
    summary.extend('- %s: %s%s' % (r.name, r.status, ' — ' + r.reason if r.reason else '') for r in results)
    summary.extend(['', *LIMITATIONS])
    contents = {'summary.md': '\n'.join(summary) + '\n',
                'observations.json': json.dumps(observations, indent=2) + '\n',
                'collection.jsonl': ''.join(json.dumps(asdict(r)) + '\n' for r in results),
                'README.txt': 'PRIVATE evidence, schema_version=1. All files are data, not execution instructions.\n'
                              'Raw JSON contains bounded allowlisted counters; collection.jsonl records omissions.\n'
                              'Checksums detect transport corruption, not authenticity. CPU/Lua attribution is limited.\n'}
    for name, content in contents.items():
        write_private(root / name, content.encode())
    manifest['files'] = [{'path': name, 'bytes': size} for name, size in sorted(inventory(root).items())]
    write_private(root / 'manifest.json', (json.dumps(manifest, indent=2) + '\n').encode())
    files = inventory(root)
    checksums = ''.join(digest_file(root / name) + '  ' + name + '\n' for name in sorted(files))
    write_private(root / 'checksums.sha256', checksums.encode())
    inventory(root)
    return root / 'manifest.json'


def verify_bundle(root):
    root = Path(root)
    if root.is_symlink() or not root.is_dir():
        raise ValueError('expected a real bundle directory')
    # Reject symlink ancestors too; external symbol roots are checked separately.
    if any(p.is_symlink() for p in root.absolute().parents):
        raise ValueError('symlink ancestor')
    files = inventory(root)
    raw = read_bounded(root / 'checksums.sha256', 65536)
    if raw.status != 'ok':
        raise ValueError('checksums unavailable')
    seen = set()
    for line in raw.data['text'].splitlines():
        parts = line.split('  ', 1)
        if len(parts) != 2:
            raise ValueError('invalid checksum line')
        digest, name = parts
        if not re.fullmatch('[a-f0-9]{64}', digest) or not allowed(name) or name in seen or name == 'checksums.sha256':
            raise ValueError('invalid checksum path')
        if name not in files or digest_file(root / name) != digest:
            raise ValueError('checksum mismatch: ' + name)
        seen.add(name)
    if seen != set(files) - {'checksums.sha256'} or not ROOT_FILES.issubset(files):
        raise ValueError('unlisted or missing evidence')
    manifest = json.loads(read_bounded(root / 'manifest.json', 2 * 1024**2).data['text'])
    if manifest.get('schema_version') != 1:
        raise ValueError('unsupported schema_version')
    if manifest.get('status') not in ('complete', 'partial', 'failed', 'interrupted'):
        raise ValueError('invalid bundle status')
    for item in manifest.get('files', []):
        if item.get('path') not in files or item.get('bytes') != files[item['path']]:
            raise ValueError('manifest file mismatch')
    for result in manifest.get('collectors', []):
        if result.get('status') not in STATUSES:
            raise ValueError('invalid collector status')
        if any(p not in files for p in result.get('evidence', [])):
            raise ValueError('missing linked evidence')
    return manifest
