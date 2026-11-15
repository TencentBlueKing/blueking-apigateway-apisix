import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from diag.model import Budget, Identity
from diag.runtime import ControlLock, identity_unchanged, private_directory, read_bounded, run_owned


class RuntimeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)

    def test_bounded_read_reports_truncation_and_missing(self):
        p = self.root / 'data'
        p.write_text('abcdef')
        result = read_bounded(p, 4)
        self.assertIsNotNone(result)
        self.assertEqual(result.status, 'truncated')
        self.assertEqual(result.data['text'], 'abcd')
        self.assertEqual(read_bounded(self.root / 'missing', 4).status, 'skipped')

    def test_private_directory_rejects_symlinks_and_world_writable(self):
        target = self.root / 'target'
        target.mkdir()
        link = self.root / 'link'
        link.symlink_to(target)
        with self.assertRaises(OSError):
            private_directory(link / 'nested')
        target.chmod(0o777)
        with self.assertRaises(OSError):
            private_directory(target)

    def test_lock_and_cooldown_survive_different_output_paths(self):
        control = self.root / 'control'
        with ControlLock(control):
            with self.assertRaises(BlockingIOError):
                with ControlLock(control):
                    pass
        with self.assertRaises(BlockingIOError):
            with ControlLock(control):
                pass

    def test_identity_checks_all_fields(self):
        a = Identity(1, 10, '/nginx', '0::/pod', 1, 2)
        self.assertTrue(identity_unchanged(a, a))
        self.assertFalse(identity_unchanged(a, Identity(1, 11, '/nginx', '0::/pod', 1, 2)))
        self.assertFalse(identity_unchanged(a, Identity(1, 10, '/other', '0::/pod', 1, 2)))
        self.assertFalse(identity_unchanged(a, None))

    def test_timeout_only_stops_owned_child(self):
        canary = subprocess.Popen(['/bin/sleep', '30'])
        self.addCleanup(lambda: (canary.terminate(), canary.wait()))
        result = run_owned(['/bin/sleep', '30'], .2, self.root, Budget(20))
        self.assertIsNotNone(result)
        self.assertEqual(result.status, 'timeout')
        self.assertTrue(result.data['reaped'])
        self.assertIsNone(canary.poll())

    def test_stream_output_has_a_hard_cap(self):
        result = run_owned([sys.executable, '-c', 'import os; os.write(1,b"x"*200000)'],
                           3, self.root, Budget(20))
        self.assertIsNotNone(result)
        self.assertEqual(result.status, 'truncated')
        self.assertLessEqual((self.root / 'stdout.txt').stat().st_size, 65536)

    def test_parent_sigkill_does_not_leave_recorder_running(self):
        import json
        import time
        env = dict(os.environ, PYTHONPATH=str(Path(__file__).resolve().parents[1]))
        script = ('from diag.runtime import run_owned; from diag.model import Budget; from pathlib import Path; '
                  'import sys; run_owned(["/bin/sleep","30"],3,Path(sys.argv[1]),Budget(20))')
        parent = subprocess.Popen([sys.executable, '-c', script, str(self.root)], env=env)
        try:
            deadline = time.monotonic() + 3
            while not (self.root / 'stdout.txt').exists() and time.monotonic() < deadline:
                time.sleep(.02)
            self.assertTrue((self.root / 'stdout.txt').exists())
            parent.kill()
            parent.wait(timeout=2)
            deadline = time.monotonic() + 5
            while not (self.root / 'runner.json').exists() and time.monotonic() < deadline:
                time.sleep(.05)
            value = json.loads((self.root / 'runner.json').read_text())
            self.assertTrue(value['reaped'])
            self.assertFalse(Path('/proc/%d' % value['child_pid']).exists())
        finally:
            if parent.poll() is None:
                parent.kill()
                parent.wait()

    def test_guard_stops_child_and_records_reason(self):
        result = run_owned(['/bin/sleep', '30'], 3, self.root, Budget(20), guard=lambda: 'oom_counter_increased')
        self.assertEqual(result.status, 'interrupted')
        self.assertEqual(result.reason, 'oom_counter_increased')
        self.assertTrue(result.data['reaped'])

    def test_child_address_space_cpu_and_file_limits_are_applied(self):
        import json
        script = ('import resource,json; '
                  'print(json.dumps([resource.getrlimit(x) for x in '
                  '[resource.RLIMIT_AS,resource.RLIMIT_CPU,resource.RLIMIT_FSIZE]]))')
        result = run_owned([sys.executable, '-c', script], 3, self.root, Budget(20))
        self.assertEqual(result.status, 'ok')
        self.assertEqual(json.loads((self.root / 'stdout.txt').read_text()),
                         [[268435456,268435456], [3,4], [16777216,16777216]])

    def test_regular_reads_refuse_symlinks_and_fifos(self):
        link = self.root / 'link'
        link.symlink_to('/etc/passwd')
        self.assertEqual(read_bounded(link, 100).status, 'skipped')
        fifo = self.root / 'fifo'
        os.mkfifo(fifo)
        self.assertEqual(read_bounded(fifo, 100).status, 'skipped')
