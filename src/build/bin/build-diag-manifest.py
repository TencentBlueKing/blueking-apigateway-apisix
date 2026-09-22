#!/usr/bin/python3
"""Build-only inventory of final patched image; optionally export matching symbols."""
import argparse
import hashlib
import json
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys


def command(argv):
    result = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=30,
                            env={'PATH': '/usr/bin:/bin', 'LANG': 'C', 'PERF_CONFIG': '/dev/null',
                                 'PERF_CONFIG_NOSYSTEM': '1', 'PERF_CONFIG_NOGLOBAL': '1'})
    if result.returncode:
        raise RuntimeError('build command failed: ' + repr(argv))
    return result.stdout.decode('utf-8', 'replace').strip()


def sha256(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def library_candidates(root):
    result = set()
    for path in root.rglob('*.so*'):
        if path.is_file():
            with path.open('rb') as stream:
                if stream.read(4) == b'\x7fELF':
                    result.add(path.resolve())
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--ops', type=Path, default=Path('/usr/local/apisix/ops'))
    parser.add_argument('--revision', default='unknown')
    parser.add_argument('--symbols-out', type=Path)
    parser.add_argument('--finalize', action='store_true')
    args = parser.parse_args()
    sys.path.insert(0, str(args.ops))
    from diag.elf import build_id
    from diag.support import collector_digest
    if args.finalize:
        path = args.ops / 'diag-build.json'
        manifest = json.loads(path.read_text())
        manifest['rpm_nevra'] = command(['/usr/bin/rpm', '-qa', '--qf', '%{NEVRA}\n']).splitlines()
        path.write_text(json.dumps(manifest, indent=2) + '\n')
        return
    if args.symbols_out:
        manifest = json.loads((args.ops / 'diag-build.json').read_text())
        args.symbols_out.mkdir(parents=True, exist_ok=False)
        for item in manifest['elf_files'] + manifest['lua_files']:
            source = Path(item['path'])
            if sha256(source) != item['sha256']:
                raise ValueError('image changed after manifest generation')
            target = args.symbols_out / source.as_posix().lstrip('/')
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, target)
        shutil.copyfile(args.ops / 'diag-build.json', args.symbols_out / 'diag-build.json')
        return
    if sys.version_info < (3, 9):
        raise RuntimeError('Python >= 3.9 required')
    nginx = Path('/usr/local/openresty/nginx/sbin/nginx')
    luajit = Path('/usr/local/openresty/luajit/bin/luajit')
    candidates = {nginx, luajit, Path('/usr/bin/perf')}
    for root in (Path('/usr/local/openresty'), Path('/usr/local/apisix/deps')):
        candidates.update(library_candidates(root))
    for binary in list(candidates):
        for path in re.findall(r'(/[^\s()]+)', command(['/usr/bin/ldd', str(binary)])):
            if Path(path).is_file():
                candidates.add(Path(path).resolve())
    elfs = []
    for path in sorted(candidates):
        sections = command(['/usr/bin/readelf', '-S', str(path)])
        elfs.append({'path': str(path), 'build_id': build_id(path), 'sha256': sha256(path),
                     'debug_info': '.debug_info' in sections,
                     'external_debug': 'not_provided'})
    lua = [{'path': str(path), 'sha256': sha256(path)} for path in
           sorted(Path('/usr/local/apisix').rglob('*.lua')) if path.is_file()]
    manifest = {'schema_version': 1, 'source_revision': args.revision,
                'architecture': platform.machine(), 'python_version': platform.python_version(),
                'perf_version': command(['/usr/bin/perf', 'version']),
                'apisix_rpm': command(['/usr/bin/rpm', '-q', 'apisix']),
                'openresty_version': command([str(nginx), '-V']),
                'luajit_version': command([str(luajit), '-v']),
                'rpm_nevra': command(['/usr/bin/rpm', '-qa', '--qf', '%{NEVRA}\n']).splitlines(),
                'elf_files': elfs, 'lua_files': lua, 'budget_version': 1,
                'collector_digest': collector_digest(args.ops),
                'image_digest': 'unavailable; record externally',
                'debug_limitations': 'Embedded debug_info is inventoried; separate vendor debug packages not provided.'}
    (args.ops / 'diag-build.json').write_text(json.dumps(manifest, indent=2) + '\n')


if __name__ == '__main__':
    main()
