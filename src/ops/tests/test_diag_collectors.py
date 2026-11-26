import unittest
from diag.collectors import counter_delta, cpu_delta
from diag.cgroup import resolve_cgroups


class DeltaTests(unittest.TestCase):
    def test_reset_and_identity_change_are_unknown(self):
        self.assertIsNone(counter_delta(100, 90, True))
        self.assertIsNone(counter_delta(100, 110, False))
        self.assertIsNone(counter_delta(None, 110, True))
        self.assertEqual(counter_delta(100, 110, True), 10)

    def test_one_cpu_means_100_percent(self):
        value = cpu_delta({'utime': 100, 'stime': 20, 'starttime': 7},
                          {'utime': 250, 'stime': 70, 'starttime': 7}, 100, 2.0)
        self.assertEqual(value.get('cpu_percent_one_core'), 100.0)
        self.assertEqual(value['user_percent_one_core'], 75.0)

    def test_no_rate_for_zero_time_missing_fields_or_reused_pid(self):
        for before, after, elapsed in [({}, {}, 2),
                ({'starttime': 7, 'utime': 1, 'stime': 1},
                 {'starttime': 8, 'utime': 20, 'stime': 2}, 2),
                ({'starttime': 7, 'utime': 1, 'stime': 1},
                 {'starttime': 7, 'utime': 20, 'stime': 2}, 0)]:
            value = cpu_delta(before, after, 100, elapsed)
            self.assertIn('cpu_percent_one_core', value)
            self.assertIsNone(value['cpu_percent_one_core'])


class CgroupTests(unittest.TestCase):
    def test_v2_subtree_mount(self):
        groups = resolve_cgroups('29 23 0:26 /pod /sys/fs/cgroup rw - cgroup2 cgroup rw\n',
                                 '0::/pod/container\n')
        self.assertEqual(len(groups), 1)
        self.assertEqual(groups[0]['path'], '/sys/fs/cgroup/container')
        self.assertTrue(groups[0]['hidden_ancestors'])

    def test_namespace_root_and_escapes(self):
        groups = resolve_cgroups('29 23 0:26 /pod\\040a /sys/fs/cgroup rw - cgroup2 cgroup rw\n',
                                 '0::/\n')
        self.assertEqual(len(groups), 1)
        self.assertEqual(groups[0]['path'], '/sys/fs/cgroup')
        self.assertTrue(groups[0]['hidden_ancestors'])

    def test_hybrid_and_controller_mounts(self):
        mounts = ('29 23 0:26 / /sys/fs/cgroup/unified rw - cgroup2 cgroup rw\n'
                  '30 23 0:27 / /sys/fs/cgroup/cpu,cpuacct rw - cgroup cgroup rw,cpu,cpuacct\n'
                  '31 23 0:28 / /sys/fs/cgroup/memory rw - cgroup cgroup rw,memory\n')
        groups = resolve_cgroups(mounts, '0::/x\n2:cpu,cpuacct:/x\n3:memory:/x\n')
        self.assertEqual(len(groups), 3)
        self.assertEqual(groups[1]['controllers'], ['cpu', 'cpuacct'])

    def test_reject_unresolvable_and_path_traversal(self):
        mount = '29 23 0:26 /pod /sys/fs/cgroup rw - cgroup2 cgroup rw\n'
        self.assertEqual(resolve_cgroups(mount, '0::/different/child\n'), [])
        self.assertEqual(resolve_cgroups(mount, '0::/../../etc\n'), [])


class SchedulingTests(unittest.TestCase):
    def test_no_target_still_has_explainable_base_and_mode_results(self):
        import tempfile
        from pathlib import Path
        from diag.collectors import collect
        from diag.model import Budget
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            proc = root / 'proc'
            (proc / 'self').mkdir(parents=True)
            (proc / 'self/cgroup').write_text('0::/\n')
            (proc / 'self/mountinfo').write_text('')
            out = root / 'out'
            out.mkdir(mode=0o700)
            results = collect('cpu', out, Budget(20), proc=proc, pause=lambda _: None)
            self.assertIn('baseline', [r.name for r in results])
            perf = next((r for r in results if r.name == 'cpu.perf'), None)
            self.assertIsNotNone(perf)
            self.assertEqual(perf.status, 'skipped')
            self.assertTrue((out / 'raw/baseline.json').exists())


class ProcessTests(unittest.TestCase):
    def setUp(self):
        import tempfile
        from pathlib import Path
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.proc = self.root / 'proc'
        (self.proc / 'self').mkdir(parents=True)
        (self.proc / 'self/cgroup').write_text('0::/pod\n')
        self.exe = self.root / 'nginx'
        self.exe.write_bytes(b'fixture')

    def process(self, pid, role, ppid=1, start=7, cgroup='0::/pod\n'):
        base = self.proc / str(pid)
        base.mkdir(exist_ok=True)
        fields = ['0'] * 24
        fields[0], fields[1], fields[11], fields[12], fields[19], fields[21] = 'S', str(ppid), '100', '20', str(start), '30'
        (base / 'stat').write_text(str(pid) + ' (nginx worker) ' + ' '.join(fields))
        (base / 'status').write_text('Name:\tprivate-name\nVmRSS:\t120 kB\nRssAnon:\t60 kB\n')
        (base / 'cmdline').write_bytes(role.encode() + b'\0private-argument')
        if role == 'nginx: worker process':
            (base / 'cmdline').write_bytes(role.encode() + b'\0')
        (base / 'cgroup').write_text(cgroup)
        (base / 'io').write_text('rchar: 100\nwchar: 200\n')
        if not (base / 'exe').is_symlink():
            (base / 'exe').symlink_to(self.exe)

    def discover(self, budget=None):
        from diag.model import Budget
        from diag.process import discover
        from diag.runtime import read_bounded
        return discover(lambda path, limit=65536: read_bounded(path, limit), budget or Budget(20),
                        self.proc, str(self.exe))

    def test_worker_parent_cgroup_and_role_are_required(self):
        self.process(10, 'nginx: master process /nginx -p /usr/local/apisix -c conf/nginx.conf')
        self.process(11, 'nginx: worker process', 10)
        self.process(12, 'nginx: cache manager process', 10)
        self.process(13, 'nginx: worker process', 99)
        self.process(14, 'nginx: worker process', 10, cgroup='0::/sidecar\n')
        workers, detail = self.discover()
        self.assertEqual([w.pid for w in workers], [11])
        self.assertNotIn('private-argument', str(detail))
        self.assertNotIn('private-name', str(detail))

    def test_multiple_masters_and_process_limit_do_not_guess(self):
        from diag.model import Budget
        for pid in (10, 20):
            self.process(pid, 'nginx: master process /nginx -p /usr/local/apisix')
            self.process(pid + 1, 'nginx: worker process', pid)
        self.assertEqual(self.discover()[0], [])
        self.assertEqual(self.discover()[1]['reason'], 'master_not_unique')
        self.assertEqual(self.discover(Budget(20, max_pids=2))[1]['reason'], 'pid_limit')

    def test_pid_reuse_discards_snapshot(self):
        from diag.process import identity, process_snapshot
        from diag.runtime import read_bounded
        read = lambda path, limit=65536: read_bounded(path, limit)
        self.process(11, 'nginx: worker process', 10)
        target = identity(11, read, self.proc)
        self.process(11, 'nginx: worker process', 10, start=8)
        value = process_snapshot(target, read, self.proc)
        self.assertEqual(value['reason'], 'identity_changed')
        self.assertNotIn('stat', value)

    def test_status_fields_and_io_remain_structured(self):
        from diag.process import identity, process_snapshot
        from diag.runtime import read_bounded
        read = lambda path, limit=65536: read_bounded(path, limit)
        self.process(11, 'nginx: worker process', 10)
        value = process_snapshot(identity(11, read, self.proc), read, self.proc, True)
        self.assertEqual(value['status'], 'ok')
        self.assertEqual(value['status_fields']['VmRSS'], 120)
        self.assertEqual(value['io']['rchar'], 100)


class HierarchyTests(unittest.TestCase):
    def test_visible_parent_limit_and_parent_usage_control_headroom(self):
        from diag.cgroup import snapshot, safety_reason
        from diag.model import Result
        groups = [{'version': 2, 'controllers': [], 'path': '/cg/child', 'mount': '/cg',
                   'root': '/', 'hidden_ancestors': True}]
        fixtures = {'/cg/child/memory.max': str(2*1024**3), '/cg/child/memory.current': str(100*1024**2),
                    '/cg/memory.max': str(1024**3), '/cg/memory.current': str(900*1024**2),
                    '/cg/child/cpu.max': '400000 100000', '/cg/cpu.max': '200000 100000'}
        def read(path):
            return Result(str(path), 'ok', data={'text': fixtures[str(path)]}) if str(path) in fixtures else Result(str(path), 'skipped', 'missing')
        value = snapshot(groups, read)
        self.assertEqual(value['effective_cpu_cores'], 2)
        self.assertEqual(value['effective_memory_limit_bytes'], 1024**3)
        self.assertEqual(value['memory_headroom_bytes'], 124*1024**2)
        self.assertEqual(safety_reason(value, 1024**3, 1024**3), 'cgroup_memory_headroom')
        self.assertEqual(safety_reason(value, 1024**3, 1024), 'disk_headroom')

    def test_v1_unlimited_sentinel_and_unknown_memory(self):
        from diag.cgroup import parse_value, safety_reason
        self.assertIsNone(parse_value('memory.limit_in_bytes', '9223372036854771712'))
        self.assertEqual(safety_reason({'memory_known': False}, 1024**3, 1024**3), 'memory_limit_unknown')


class PerfCollectionTests(unittest.TestCase):
    def test_validated_attempt_records_denial_without_retry(self):
        import tempfile
        from pathlib import Path
        from unittest.mock import patch
        from diag.collectors import Collector
        from diag.model import Budget, Identity, Result
        from test_diag_support import elf_fixture
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            elf = root / 'nginx'
            elf.write_bytes(elf_fixture())
            output = root / 'out'
            output.mkdir(mode=0o700)
            calls = []
            def executor(argv, timeout, directory, budget, guard):
                calls.append(argv)
                (directory / 'stderr.txt').write_text('Operation not permitted')
                return Result('owned-child', 'failed', 'nonzero_exit', {'returncode': 255, 'reaped': True})
            collector = Collector('cpu', output, Budget(20), pause=lambda _: None, executor=executor)
            target = Identity(123, 7, str(elf), '0::/pod', 1, 2)
            collector.workers = [target]
            collector.security = {'seccomp': 2, 'cap_eff': '00000000', 'perf_event_paranoid': 4}
            collector.build = {'collector_digest': 'a'*64, 'perf_version': 'perf version test'}
            context = collector.context(target)
            collector.matrix = {'schema_version': 1, 'entries': [dict(context, perf_ip_validated=True, report='test')]}
            def snapshot(t, ticks):
                from dataclasses import asdict
                return {'monotonic': t, 'cgroup': {'groups': [], 'effective_cpu_cores': 2},
                        'workers': {'123': {'identity': asdict(target),
                                           'stat': {'starttime': 7, 'utime': ticks, 'stime': 0}}}}
            with patch.object(collector, 'snapshot', side_effect=[snapshot(1, 100), snapshot(3, 200)]), \
                    patch.object(collector, 'headroom', return_value=None), \
                    patch('diag.collectors.identity', return_value=target), \
                    patch('diag.collectors.Path.is_file', return_value=True):
                collector.cpu()
            self.assertEqual(len(calls), 1)
            self.assertIn('cpu-clock:u', calls[0])
            self.assertNotIn('-g', calls[0])
            self.assertEqual(collector.results[-1].status, 'failed')
            self.assertEqual(collector.results[-1].data['returncode'], 255)
            self.assertEqual(collector.results[0].data['workers']['123']['cpu_percent_container_quota'], 25.0)

    def test_unknown_combination_does_not_launch_any_executor(self):
        import tempfile
        from pathlib import Path
        from diag.collectors import Collector
        from diag.model import Budget, Identity
        from unittest.mock import patch
        with tempfile.TemporaryDirectory() as tmp:
            target = Identity(123, 7, '/nginx', '0::/pod')
            collector = Collector('cpu', Path(tmp), Budget(20))
            with patch('diag.collectors.identity', return_value=target):
                self.assertEqual(collector.extra_reason(target, 'perf_ip'), 'combination_not_validated')
                self.assertEqual(collector.extra_reason(target, 'smaps_rollup'), 'combination_not_validated')


class MissingControllerTests(unittest.TestCase):
    def test_available_group_does_not_mean_io_controller_available(self):
        from diag.collectors import mode_sources_available
        value = {'groups': [{'levels': [{'values': {'memory.current': 100, 'memory.stat': {'anon': 90}}}]}]}
        self.assertFalse(mode_sources_available(value, 'io'))
        self.assertFalse(mode_sources_available(value, 'cpu'))
        self.assertTrue(mode_sources_available(value, 'memory'))
        value['groups'][0]['levels'][0]['values']['io.stat'] = {}
        self.assertTrue(mode_sources_available(value, 'io'))


class MemorySummaryTests(unittest.TestCase):
    def test_memory_categories_are_not_summed_and_missing_stays_unknown(self):
        from diag.collectors import memory_summary
        value = {'groups': [{'levels': [{'path': '/cg', 'values': {
            'memory.current': 150, 'memory.stat': {'anon': 100, 'file': 50, 'shmem': 20, 'pgfault': 9}}}]}]}
        rows = memory_summary(value)
        self.assertEqual(rows[0]['current_bytes'], 150)
        self.assertEqual(rows[0]['categories'], {'anon': 100, 'file': 50, 'shmem': 20})
        del value['groups'][0]['levels'][0]['values']['memory.current']
        self.assertIsNone(memory_summary(value)[0]['current_bytes'])
