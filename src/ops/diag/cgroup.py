"""Namespace-aware cgroup resolution. Missing counters remain unknown."""
from pathlib import Path, PurePosixPath
import re


def unescape(value):
    return re.sub(r'\\([0-7]{3})', lambda m: chr(int(m[1], 8)), value)


def resolve_cgroups(mountinfo, membership):
    memberships = []
    for line in membership.splitlines():
        parts = line.split(':', 2)
        if len(parts) == 3 and parts[2].startswith('/') and '..' not in PurePosixPath(parts[2]).parts:
            memberships.append((parts[1].split(',') if parts[1] else [], parts[2]))
    result = []
    for line in mountinfo.splitlines():
        try:
            left, right = line.split(' - ', 1)
            fields, options = left.split(), right.split()
            kind = options[0]
            if kind not in ('cgroup', 'cgroup2'):
                continue
            root, mount = unescape(fields[3]), unescape(fields[4])
            for controllers, member in memberships:
                if kind == 'cgroup2' and controllers:
                    continue
                if kind == 'cgroup' and (not controllers or not set(controllers).issubset(options[2].split(','))):
                    continue
                if member == '/':
                    relative = ''  # cgroup namespace root
                elif root == '/':
                    relative = member.lstrip('/')
                elif member == root:
                    relative = ''
                elif member.startswith(root.rstrip('/') + '/'):
                    relative = member[len(root):].lstrip('/')
                else:
                    continue
                result.append({'version': 2 if kind == 'cgroup2' else 1,
                               'controllers': controllers, 'mount': mount, 'root': root,
                               'path': str(PurePosixPath(mount) / relative),
                               # Even a namespace root mounted at '/' may hide host parents.
                               'hidden_ancestors': True})
        except (ValueError, IndexError):
            continue
    return result


def numeric_fields(text):
    data = {}
    for line in text.splitlines():
        words = line.replace(':', ' ').split()
        if len(words) >= 2:
            try:
                data[words[0]] = int(words[1])
            except ValueError:
                pass
    return data


def parse_value(name, text):
    if name in ('memory.stat', 'memory.events', 'memory.events.local', 'cpu.stat',
                'cpuacct.stat', 'memory.oom_control'):
        return numeric_fields(text)
    if name == 'cpu.max':
        words = text.split()
        return {'quota': None if words[0] == 'max' else int(words[0]), 'period': int(words[1])}
    if name in ('io.stat', 'blkio.throttle.io_service_bytes', 'blkio.throttle.io_serviced'):
        devices = {}
        for line in text.splitlines():
            words = line.split()
            if not words or not re.fullmatch(r'\d+:\d+', words[0]):
                continue
            fields = devices.setdefault(words[0], {})
            if name == 'io.stat':
                for word in words[1:]:
                    key, value = word.split('=', 1)
                    fields[key] = int(value)
            elif len(words) == 3:
                fields[words[1]] = int(words[2])
        return devices
    if name.endswith('.pressure'):
        return text.strip()
    if 'cpuset' in name:
        return text.strip()
    if text.strip() == 'max':
        return None
    value = int(text.strip())
    if name == 'memory.limit_in_bytes' and value >= (1 << 60):
        return None  # v1 unlimited sentinel, not an enormous finite budget
    return value


V2_FILES = ('cpu.max', 'cpu.stat', 'cpuset.cpus.effective', 'memory.current',
            'memory.max', 'memory.stat', 'memory.events', 'memory.events.local',
            'cpu.pressure', 'memory.pressure', 'io.pressure', 'io.stat')
V1_FILES = {
    'cpu': ('cpu.cfs_quota_us', 'cpu.cfs_period_us', 'cpu.stat'),
    'cpuacct': ('cpuacct.usage', 'cpuacct.stat'),
    'cpuset': ('cpuset.cpus', 'cpuset.effective_cpus'),
    'memory': ('memory.usage_in_bytes', 'memory.limit_in_bytes', 'memory.stat',
               'memory.failcnt', 'memory.oom_control', 'memory.use_hierarchy'),
    'blkio': ('blkio.throttle.io_service_bytes', 'blkio.throttle.io_serviced'),
}


def snapshot(groups, read):
    output = {'scope': 'container-cgroup', 'groups': [], 'effective_memory_limit_bytes': None,
              'memory_headroom_bytes': None, 'effective_cpu_cores': None,
              'hidden_ancestors': True, 'memory_known': False}
    limits, headrooms, quotas = [], [], []
    memory_known = False
    memory_incomplete = False
    for group in groups:
        path, mount = Path(group['path']), Path(group['mount'])
        names = V2_FILES if group['version'] == 2 else tuple(
            name for controller in group['controllers'] for name in V1_FILES.get(controller, ()))
        levels = []
        while True:
            values, unavailable = {}, {}
            for name in names:
                raw = read(path / name)
                if raw.status != 'ok':
                    unavailable[name] = raw.reason or raw.status
                    continue
                try:
                    values[name] = parse_value(name, raw.data['text'])
                except (ValueError, IndexError):
                    unavailable[name] = 'malformed'
            levels.append({'path': str(path), 'values': values, 'unavailable': unavailable})
            v2 = group['version'] == 2
            limit_key = 'memory.max' if v2 else 'memory.limit_in_bytes'
            current_key = 'memory.current' if v2 else 'memory.usage_in_bytes'
            has_memory = v2 or 'memory' in group['controllers']
            if has_memory:
                if limit_key in values and current_key in values:
                    memory_known = True
                    limit, current = values[limit_key], values[current_key]
                    if limit is not None:
                        limits.append(limit)
                        headrooms.append(limit - current)
                        # Store the safety margin per level; parent usage includes siblings.
                        levels[-1]['memory_safe_margin_bytes'] = limit - current - max(256 * 1024**2, limit * .05)
                elif path != mount or not v2:
                    memory_incomplete = True
            cpu_max = values.get('cpu.max', {})
            quota = cpu_max.get('quota') if v2 else values.get('cpu.cfs_quota_us')
            period = cpu_max.get('period') if v2 else values.get('cpu.cfs_period_us')
            if quota is not None and quota > 0 and period and period > 0:
                quotas.append(quota / period)
            if path == mount:
                break
            if len(levels) >= 32 or mount not in path.parents:
                memory_incomplete = True
                break
            path = path.parent
        output['groups'].append(dict(group, levels=levels))
    output.update(effective_memory_limit_bytes=min(limits) if limits else None,
                  memory_headroom_bytes=min(headrooms) if headrooms else None,
                  effective_cpu_cores=min(quotas) if quotas else None,
                  memory_known=memory_known and not memory_incomplete)
    return output


def safety_reason(data, host_available, disk_available):
    if disk_available < 128 * 1024**2:
        return 'disk_headroom'
    if not data['memory_known']:
        return 'memory_limit_unknown'
    if data['effective_memory_limit_bytes'] is None:
        if host_available is None or host_available < 512 * 1024**2 + 24 * 1024**2:
            return 'host_memory_headroom'
    else:
        # Charge worst-case tmpfs output even on disk; intentionally conservative.
        for group in data['groups']:
            for level in group['levels']:
                if level.get('memory_safe_margin_bytes', float('inf')) < 24 * 1024**2:
                    return 'cgroup_memory_headroom'
    return None
