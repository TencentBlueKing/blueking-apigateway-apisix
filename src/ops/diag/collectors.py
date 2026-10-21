"""Read-only discovery and mode scheduling."""
from dataclasses import asdict
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import platform
import sys
import time

from . import cgroup
from .elf import build_id
from .model import Result
from .process import discover, identity, process_snapshot
from .runtime import LimitReached, Session, identity_unchanged, read_bounded, run_owned, write_private
from .support import perf_argv, validated


def counter_delta(before, after, same_identity):
    if not same_identity or before is None or after is None or after < before:
        return None
    return after - before


def cpu_delta(before, after, hz, elapsed_seconds):
    same = before.get('starttime') is not None and before.get('starttime') == after.get('starttime')
    user = counter_delta(before.get('utime'), after.get('utime'), same)
    system = counter_delta(before.get('stime'), after.get('stime'), same)
    valid = user is not None and system is not None and elapsed_seconds > 0 and hz > 0
    scale = 100 / hz / elapsed_seconds if valid else None
    return {'utime_ticks': user, 'stime_ticks': system,
            'cpu_percent_one_core': (user + system) * scale if valid else None,
            'user_percent_one_core': user * scale if valid else None,
            'system_percent_one_core': system * scale if valid else None,
            'user_fraction': user / (user + system) if valid and user + system else None,
            'system_fraction': system / (user + system) if valid and user + system else None,
            'reset_or_unavailable': not valid, 'elapsed_seconds': elapsed_seconds}



OPS = Path(__file__).resolve().parent.parent


def tree_delta(before, after):
    """Only integer counters; resets and missing values remain null."""
    if isinstance(before, dict) and isinstance(after, dict):
        return {k: tree_delta(before.get(k), after.get(k)) for k in set(before) | set(after)}
    if type(before) is int and type(after) is int:
        return counter_delta(before, after, True)
    return None


def network_snapshot(proc, read):
    values, unavailable = {}, {}
    for name in ('dev', 'snmp', 'netstat'):
        result = read(proc / 'net' / name)
        if result.status != 'ok':
            unavailable[name] = result.reason or result.status
            continue
        lines = result.data['text'].splitlines()
        fields = {}
        try:
            if name == 'dev':
                for line in lines[2:]:
                    device, counters = line.split(':', 1)
                    numbers = [int(x) for x in counters.split()]
                    fields[device.strip()] = {'rx_bytes': numbers[0], 'rx_packets': numbers[1],
                                              'rx_errors': numbers[2], 'rx_drops': numbers[3],
                                              'tx_bytes': numbers[8], 'tx_packets': numbers[9],
                                              'tx_errors': numbers[10], 'tx_drops': numbers[11]}
            else:
                for offset in range(0, len(lines) - 1, 2):
                    keys, numbers = lines[offset].split(), lines[offset + 1].split()
                    if keys[0] != numbers[0] or len(keys) != len(numbers):
                        raise ValueError('invalid counters')
                    fields[keys[0].rstrip(':')] = {k: int(v) for k, v in zip(keys[1:], numbers[1:])}
            values[name] = fields
        except (ValueError, IndexError):
            unavailable[name] = 'malformed'
    psi = read(proc / 'pressure/io')
    return {'scope': 'pod-netns', 'values': values, 'unavailable': unavailable,
            'host_io_psi': {'scope': 'host-visible', 'status': psi.status,
                            'text': psi.data.get('text'), 'reason': psi.reason}}


def cg_counters(snapshot):
    # Preserve hierarchy identity in keys so moved cgroups cannot produce false deltas.
    return {level['path']: {k: v for k, v in level['values'].items()
            if k in ('cpu.stat', 'cpuacct.usage', 'cpuacct.stat', 'memory.events',
                     'memory.events.local', 'memory.failcnt', 'io.stat',
                     'blkio.throttle.io_service_bytes', 'blkio.throttle.io_serviced')}
            for group in snapshot['groups'] for level in group['levels']}


def security_context(proc, read):
    status = read(proc / 'self/status').data.get('text', '')
    fields = {}
    for line in status.splitlines():
        key, _, value = line.partition(':')
        if key in ('Seccomp', 'CapEff'):
            fields[key] = value.strip()
    paranoid = read(proc / 'sys/kernel/perf_event_paranoid').data.get('text', '').strip()
    return {'seccomp': int(fields['Seccomp']) if fields.get('Seccomp', '').isdigit() else None,
            'cap_eff': fields.get('CapEff'),
            'perf_event_paranoid': int(paranoid) if paranoid.lstrip('-').isdigit() else None}


def load_json(path, read, limit=65536):
    result = read(path, limit)
    if result.status != 'ok':
        return {}, result.reason or result.status
    try:
        value = json.loads(result.data['text'])
        return (value, None) if isinstance(value, dict) else ({}, 'invalid_json_object')
    except ValueError:
        return {}, 'invalid_json'


class Collector:
    def __init__(self, mode, output_dir, budget, proc=Path('/proc'), pause=None,
                 started=None, executor=run_owned, ops=OPS):
        self.mode, self.proc, self.ops = mode, proc, ops
        self.session = Session(output_dir, budget, started)
        self.pause = pause or self.session.pause
        self.executor = executor
        self.results = []
        self.workers = []
        self.groups = []
        self.build = {}
        self.matrix = {}
        self.initial_oom = {}
        self.security = {}

    def add(self, name, status='ok', reason=None, data=None, evidence=None, started=None):
        values = dict(data or {})
        values.update(finished_at_utc=datetime.now(timezone.utc).isoformat(),
                      monotonic_end=time.monotonic(),
                      monotonic_start=started if started is not None else time.monotonic())
        result = Result(name, status, reason, values, evidence or [])
        self.results.append(result)
        return result

    def cgroups(self):
        return cgroup.snapshot(self.groups, self.session.read)

    def snapshot(self, io=False):
        return {'monotonic': time.monotonic(), 'cgroup': self.cgroups(),
                'workers': {str(w.pid): process_snapshot(w, self.session.read, self.proc, io)
                            for w in self.workers}}

    def baseline(self):
        started = time.monotonic()
        mount = self.session.read(self.proc / 'self/mountinfo')
        member = self.session.read(self.proc / 'self/cgroup')
        if mount.status == member.status == 'ok':
            self.groups = cgroup.resolve_cgroups(mount.data['text'], member.data['text'])
        self.workers, discovery = discover(self.session.read, self.session.budget, self.proc)
        self.build, missing_build = load_json(self.ops / 'diag-build.json', self.session.read, 1024 * 1024)
        self.matrix, _ = load_json(self.ops / 'diag-supported.json', self.session.read)
        self.security = security_context(self.proc, self.session.read)
        groups = self.cgroups()
        self.initial_oom = self.oom_counts(groups)
        data = {'scope': 'container-cgroup and process', 'discovery': discovery, 'cgroup': groups,
                'architecture': platform.machine(), 'kernel': platform.release(),
                'page_size_bytes': os.sysconf('SC_PAGE_SIZE'), 'clk_tck': os.sysconf('SC_CLK_TCK'),
                'security': self.security, 'build_unavailable': missing_build,
                'source_status': {'mountinfo': mount.status, 'cgroup': member.status}}
        evidence = [self.session.save('raw/baseline.json', data)]
        if self.build:
            evidence.append(self.session.save('build/diag-build.json', self.build))
        complete = discovery['status'] == 'ok' and bool(self.groups) and not missing_build
        self.add('baseline', 'ok' if complete else 'skipped',
                 None if complete else 'discovery_or_build_unavailable',
                 {'scope': data['scope'], 'sources': ['proc/self/mountinfo', 'proc/self/cgroup', 'proc/PID/{stat,status,cmdline,exe,cgroup}', 'ops/diag-build.json'],
                  'worker_count': len(self.workers), 'discovery_status': discovery['status']}, evidence, started)

    @staticmethod
    def oom_counts(data):
        return {level['path'] + ':' + key: value for group in data['groups']
                for level in group['levels']
                for key, value in level['values'].get('memory.events',
                    level['values'].get('memory.oom_control', {})).items()
                if key in ('oom', 'oom_kill')}

    def headroom(self):
        data = self.cgroups()
        host = cgroup.numeric_fields(self.session.read(self.proc / 'meminfo').data.get('text', ''))
        available = host.get('MemAvailable')
        available = available * 1024 if available is not None else None
        stat = os.statvfs(self.session.output_dir)
        reason = cgroup.safety_reason(data, available, stat.f_bavail * stat.f_frsize)
        if any(v > self.initial_oom.get(k, v) for k, v in self.oom_counts(data).items()):
            reason = 'oom_counter_increased'
        return reason

    def context(self, target):
        return {'target_build_id': build_id(Path(target.exe)),
                'collector_digest': self.build.get('collector_digest'),
                'architecture': platform.machine(), 'kernel': platform.release(),
                'perf_version': self.build.get('perf_version'), 'budget_version': 1,
                'security': self.security}

    def extra_reason(self, target, feature):
        self.session.check()
        if not identity_unchanged(target, identity(target.pid, self.session.read, self.proc)):
            return 'identity_changed'
        if not validated(self.matrix, self.context(target), feature):
            return 'combination_not_validated'
        if self.session.deadline - time.monotonic() < (11 if feature == 'perf_ip' else 2.5):
            return 'insufficient_deadline'
        return self.headroom()

    def guard(self, target):
        last = [0.0]
        def check():
            if time.monotonic() - last[0] < .5:
                return None
            last[0] = time.monotonic()
            try:
                self.session.check()
                if not identity_unchanged(target, identity(target.pid, self.session.read, self.proc)):
                    return 'identity_changed'
                return self.headroom()
            except LimitReached as exc:
                return str(exc)
        return check

    def cpu(self):
        started = time.monotonic()
        before = self.snapshot()
        self.pause(2)
        after = self.snapshot()
        elapsed = after['monotonic'] - before['monotonic']
        evidence = [self.session.save('raw/cpu-before.json', before),
                    self.session.save('raw/cpu-after.json', after)]
        deltas = {}
        selected, highest = None, 0
        for worker in self.workers:
            key = str(worker.pid)
            b, a = before['workers'][key], after['workers'][key]
            stable = b.get('identity') == a.get('identity') and b.get('stat') and a.get('stat')
            value = cpu_delta(b.get('stat', {}) if stable else {}, a.get('stat', {}),
                              os.sysconf('SC_CLK_TCK'), elapsed)
            quota = after['cgroup']['effective_cpu_cores']
            rate = value['cpu_percent_one_core']
            value['cpu_percent_container_quota'] = rate / quota if rate is not None and quota else None
            deltas[key] = value
            ticks = (value['utime_ticks'] or 0) + (value['stime_ticks'] or 0)
            if rate is not None and ticks > highest:
                selected, highest = worker, ticks
        data = {'scope': 'process and container-cgroup', 'units': 'ticks; percent of one logical CPU',
                'workers': deltas, 'elapsed_seconds': elapsed,
                'cgroup_counter_deltas': tree_delta(cg_counters(before['cgroup']), cg_counters(after['cgroup']))}
        complete = (bool(deltas) and all(v['cpu_percent_one_core'] is not None for v in deltas.values())
                    and mode_sources_available(before['cgroup'], 'cpu')
                    and mode_sources_available(after['cgroup'], 'cpu'))
        self.add('cpu.delta', 'ok' if complete else 'skipped',
                 None if complete else 'counter_reset_or_missing_sources', data, evidence, started)
        if selected is None:
            self.add('cpu.perf', 'skipped', 'no_active_stable_worker', {'scope': 'process'})
            return
        reason = self.extra_reason(selected, 'perf_ip')
        if reason:
            self.add('cpu.perf', 'skipped', reason, {'target': asdict(selected), 'scope': 'process'})
            return
        if not Path('/usr/bin/perf').is_file():
            self.add('cpu.perf', 'skipped', 'perf_unavailable')
            return
        maps = self.session.read(self.proc / str(selected.pid) / 'maps', 256 * 1024)
        cpu_dir = self.session.output_dir / 'cpu'
        cpu_dir.mkdir(mode=0o700, exist_ok=True)
        write_private(cpu_dir / 'maps.txt', maps.data.get('text', '').encode())
        identities = [{'path': selected.exe, 'build_id': build_id(Path(selected.exe))}]
        paths = set([selected.exe])
        for line in maps.data.get('text', '').splitlines():
            parts = line.split(None, 5)
            if len(parts) == 6 and parts[5].startswith('/') and parts[5] not in paths:
                if len(paths) >= 17:
                    break
                paths.add(parts[5])
                identities.append({'path': parts[5], 'build_id': build_id(Path(parts[5]))})
        self.session.save('cpu/elf-identities.json', {'files': identities, 'maps_status': maps.status,
                                                     'limit': 16, 'scope': 'process'})
        path = cpu_dir / 'perf.data'
        result = self.executor(perf_argv(selected.pid, path, self.session.budget),
                               self.session.budget.perf_seconds + .5, cpu_dir,
                               self.session.budget, guard=self.guard(selected))
        if (not identity_unchanged(selected, identity(selected.pid, self.session.read, self.proc))
                or result.reason == 'identity_changed'):
            if path.exists():
                path.unlink()  # do not retain samples from a reused PID
            result.status, result.reason = 'interrupted', 'identity_changed_samples_discarded'
        if path.exists() and (path.stat().st_size == 0 or path.stat().st_size >= self.session.budget.max_perf_bytes):
            result.status, result.reason = 'truncated', 'empty_or_limited_perf_file'
        # Native data always needs offline validation of sample count/lost records.
        if result.status == 'ok':
            result.status, result.reason = 'skipped', 'recorded_requires_offline_validation'
        if (cpu_dir / 'stderr.txt').exists():
            (cpu_dir / 'stderr.txt').rename(cpu_dir / 'perf.stderr.txt')
        result.data.update(target=asdict(selected), scope='process', event='cpu-clock:u',
                           perf_version=self.build.get('perf_version'), sample_count=None,
                           lost_samples=None, native_recording_created=path.exists())
        self.add('cpu.perf', result.status, result.reason, result.data,
                 ['cpu/' + p.name for p in cpu_dir.iterdir() if p.is_file()], started)
        if not result.data.get('reaped'):
            raise LimitReached('child_not_reaped')

    def smaps(self, target, phase):
        name = 'memory.smaps.' + phase
        reason = self.extra_reason(target, 'smaps_rollup')
        if reason:
            self.add(name, 'skipped', reason, {'scope': 'process', 'target': asdict(target)})
            return
        output = self.session.output_dir / ('smaps-' + phase)
        output.mkdir(mode=0o700)
        result = self.executor([sys.executable, '-I', str(Path(__file__).with_name('smaps.py')),
                                str(self.proc / str(target.pid) / 'smaps_rollup')],
                               2, output, self.session.budget, guard=self.guard(target))
        stable = identity_unchanged(target, identity(target.pid, self.session.read, self.proc))
        fields, reason = load_json(output / 'stdout.txt', self.session.read) if stable else ({}, 'identity_changed')
        result.data.update(scope='process', target=asdict(target), fields_kib=fields)
        if reason:
            result.status, result.reason = 'skipped', reason
        self.add(name, result.status, result.reason, result.data,
                 [str(p.relative_to(self.session.output_dir)) for p in output.iterdir()])
        if not result.data.get('reaped'):
            raise LimitReached('child_not_reaped')

    def memory_io(self):
        memory, io = self.mode in ('memory', 'all'), self.mode in ('io', 'all')
        started = time.monotonic()
        before = self.snapshot(io)
        network_before = network_snapshot(self.proc, self.session.read) if io else None
        target = None
        if memory and self.workers:
            for worker in self.workers:
                values = before['workers'][str(worker.pid)]
                fields = values.get('status_fields')
                if isinstance(fields, dict) and fields.get('VmRSS') is not None:
                    if target is None or fields['VmRSS'] > before['workers'][str(target.pid)]['status_fields']['VmRSS']:
                        target = worker
            if target:
                self.smaps(target, 'before')
        if memory and target is None:
            self.add('memory.smaps.before', 'skipped', 'no_worker_rss')
        # Shared window: any bounded smaps time is part of the ten seconds.
        self.pause(max(0, 10 - (time.monotonic() - before['monotonic'])))
        after = self.snapshot(io)
        network_after = network_snapshot(self.proc, self.session.read) if io else None
        if memory and target:
            self.smaps(target, 'after')
        elapsed = after['monotonic'] - before['monotonic']
        for name, enabled in [('memory', memory), ('io', io)]:
            if not enabled:
                continue
            b, a = dict(before), dict(after)
            if name == 'io':
                b['network'], a['network'] = network_before, network_after
            evidence = [self.session.save('raw/' + name + '-before.json', b),
                        self.session.save('raw/' + name + '-after.json', a)]
            changes = {}
            missing = (not self.workers or not mode_sources_available(before['cgroup'], name)
                       or not mode_sources_available(after['cgroup'], name))
            for worker in self.workers:
                key = str(worker.pid)
                wb, wa = before['workers'][key], after['workers'][key]
                stable = wb.get('identity') == wa.get('identity') and 'stat' in wb and 'stat' in wa
                if name == 'io':
                    changes[key] = tree_delta(wb.get('io', {}), wa.get('io', {})) if stable else None
                    missing = missing or 'io' not in wb or 'io' not in wa
                else:
                    bs, ass = wb.get('status_fields'), wa.get('status_fields')
                    changes[key] = {'rss_change_kib': ass['VmRSS'] - bs['VmRSS']
                        if stable and isinstance(bs, dict) and isinstance(ass, dict) and 'VmRSS' in bs and 'VmRSS' in ass else None,
                        'minor_faults': counter_delta(wb.get('stat', {}).get('minflt'), wa.get('stat', {}).get('minflt'), stable),
                        'major_faults': counter_delta(wb.get('stat', {}).get('majflt'), wa.get('stat', {}).get('majflt'), stable)}
                    missing = missing or changes[key]['rss_change_kib'] is None
            data = {'scope': 'process and container-cgroup' + (' and pod-netns' if io else ''),
                    'elapsed_seconds': elapsed, 'workers': changes,
                    'cgroup_counter_deltas': tree_delta(cg_counters(before['cgroup']), cg_counters(after['cgroup']))}
            if name == 'memory':
                data['container_memory_before'] = memory_summary(before['cgroup'])
                data['container_memory_after'] = memory_summary(after['cgroup'])
            if name == 'io':
                data['network_counter_deltas'] = tree_delta(network_before['values'], network_after['values'])
                missing = missing or bool(network_before['unavailable'] or network_after['unavailable'])
            self.add(name + '.delta', 'skipped' if missing else 'ok',
                     'missing_sources' if missing else None, data, evidence, started)

    def run(self):
        try:
            self.baseline()
            if self.mode in ('cpu', 'all'):
                self.cpu()
            if self.mode in ('memory', 'io', 'all'):
                self.memory_io()
        except LimitReached as exc:
            self.add('collection', 'timeout' if str(exc) == 'deadline' else 'truncated', str(exc))
        except KeyboardInterrupt:
            self.add('collection', 'interrupted', 'user_interrupt')
        return self.results


def collect(mode, output_dir, budget, **kwargs):
    return Collector(mode, output_dir, budget, **kwargs).run()


def mode_sources_available(snapshot, mode):
    for group in snapshot['groups']:
        if not group.get('levels'):
            continue
        values = group['levels'][0]['values']
        if mode == 'cpu' and ('cpu.stat' in values or 'cpuacct.usage' in values):
            return True
        if mode == 'memory' and 'memory.stat' in values and ('memory.current' in values or 'memory.usage_in_bytes' in values):
            return True
        if mode == 'io' and ('io.stat' in values or 'blkio.throttle.io_service_bytes' in values):
            return True
    return False


def memory_summary(snapshot):
    result = []
    categories = {'anon', 'file', 'shmem', 'slab', 'sock', 'kernel',
                  'rss', 'cache', 'total_rss', 'total_cache', 'total_shmem'}
    for group in snapshot['groups']:
        if not group.get('levels'):
            continue
        leaf = group['levels'][0]
        values = leaf['values']
        if 'memory.stat' in values:
            result.append({'path': leaf['path'], 'scope': 'container-cgroup', 'unit': 'bytes',
                           'current_bytes': values.get('memory.current', values.get('memory.usage_in_bytes')),
                           'categories': {k: v for k, v in values['memory.stat'].items() if k in categories},
                           'limitation': 'Categories overlap; do not sum them.'})
    return result
