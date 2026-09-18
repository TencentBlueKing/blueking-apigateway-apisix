"""Bounded procfs discovery; cmdline is used for roles and never serialized."""
from dataclasses import asdict
import os
from pathlib import Path
import shlex

from .model import Identity
from .runtime import identity_unchanged
from .cgroup import numeric_fields

STATUS_FIELDS = {'VmRSS', 'RssAnon', 'RssFile', 'RssShmem', 'VmSwap', 'Threads',
                 'voluntary_ctxt_switches', 'nonvoluntary_ctxt_switches'}
IO_FIELDS = {'rchar', 'wchar', 'syscr', 'syscw', 'read_bytes', 'write_bytes', 'cancelled_write_bytes'}
NGINX_EXE = '/usr/local/openresty/nginx/sbin/nginx'


def parse_stat(text):
    fields = text[text.rfind(')') + 2:].split()
    return {name: int(fields[index]) for name, index in
            [('ppid', 1), ('minflt', 7), ('majflt', 9), ('utime', 11),
             ('stime', 12), ('starttime', 19), ('rss_pages', 21)]}


def identity(pid, read, proc=Path('/proc')):
    try:
        base = proc / str(pid)
        raw = read(base / 'stat')
        cg = read(base / 'cgroup')
        if raw.status != 'ok' or cg.status != 'ok':
            return None
        value = parse_stat(raw.data['text'])
        exe = os.readlink(str(base / 'exe'))
        info = os.stat(base / 'exe')
        return Identity(pid, value['starttime'], exe, cg.data['text'], info.st_dev, info.st_ino)
    except (OSError, ValueError, IndexError):
        return None


def process_snapshot(target, read, proc=Path('/proc'), include_io=False):
    base = proc / str(target.pid)
    if not identity_unchanged(target, identity(target.pid, read, proc)):
        return {'status': 'skipped', 'reason': 'identity_changed', 'identity': asdict(target)}
    values = {'identity': asdict(target), 'scope': 'process', 'status': 'ok', 'unavailable': {}}
    for name in ('stat', 'status', *(['io'] if include_io else [])):
        raw = read(base / name)
        if raw.status != 'ok':
            values['unavailable'][name] = raw.reason or raw.status
            continue
        try:
            fields = parse_stat(raw.data['text']) if name == 'stat' else numeric_fields(raw.data['text'])
            if name == 'status':
                fields = {k: v for k, v in fields.items() if k in STATUS_FIELDS}
            if name == 'io':
                fields = {k: v for k, v in fields.items() if k in IO_FIELDS}
            values['status_fields' if name == 'status' else name] = fields
        except (ValueError, IndexError):
            values['unavailable'][name] = 'malformed'
    if not identity_unchanged(target, identity(target.pid, read, proc)):
        return {'status': 'skipped', 'reason': 'identity_changed', 'identity': asdict(target)}
    if values['unavailable']:
        values['status'] = 'skipped'
    return values


def discover(read, budget, proc=Path('/proc'), expected_exe=NGINX_EXE):
    self_cgroup = read(proc / 'self/cgroup')
    if self_cgroup.status != 'ok':
        return [], {'status': 'skipped', 'reason': 'self_cgroup_unavailable', 'processes': []}
    pids = []
    with os.scandir(proc) as entries:
        for entry in entries:
            if entry.name.isdigit():
                pids.append(int(entry.name))
                if len(pids) > budget.max_pids:
                    return [], {'status': 'truncated', 'reason': 'pid_limit', 'processes': []}
    candidates, processes, unavailable = [], [], []
    for pid in sorted(pids):
        target = identity(pid, read, proc)
        if not target:
            unavailable.append({'pid': pid, 'reason': 'identity_unavailable_or_exited'})
            continue
        values = process_snapshot(target, read, proc)
        # Other processes retain allowed resource fields, not executable or cgroup paths.
        processes.append({'pid': pid, 'starttime_ticks': target.starttime_ticks,
                          'scope': 'process', 'stat': values.get('stat'), 'status': values.get('status')})
        if target.exe != expected_exe or target.cgroup != self_cgroup.data['text']:
            continue
        role = read(proc / str(pid) / 'cmdline', 4096)
        if role.status != 'ok':
            continue
        command = role.data['text'].replace('\0', ' ').strip()
        if command.startswith('nginx: master process '):
            try:
                words = shlex.split(command[len('nginx: master process '):])
                prefix = words[words.index('-p') + 1].rstrip('/')
                if prefix != '/usr/local/apisix':
                    continue
            except (ValueError, IndexError):
                continue
            name = 'master'
        elif command == 'nginx: worker process':
            name = 'worker'
        else:
            continue
        if identity_unchanged(target, identity(pid, read, proc)):
            candidates.append((name, target, values.get('stat', {}).get('ppid')))
    masters = [target for name, target, _ in candidates if name == 'master']
    if len(masters) != 1:
        return [], {'status': 'skipped', 'reason': 'master_not_unique', 'processes': processes, 'unavailable': unavailable}
    master = masters[0]
    workers = [target for name, target, ppid in candidates if name == 'worker' and
               ppid == master.pid and (target.exe_device, target.exe_inode) == (master.exe_device, master.exe_inode)]
    if len(workers) > budget.max_workers:
        return [], {'status': 'truncated', 'reason': 'worker_limit', 'processes': processes, 'unavailable': unavailable}
    return workers, {'status': 'ok' if workers else 'skipped',
                     'reason': None if workers else 'no_workers', 'master': asdict(master),
                     'workers': [asdict(w) for w in workers], 'processes': processes, 'unavailable': unavailable}
