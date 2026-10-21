import json
from pathlib import Path
import tempfile
import unittest
from diag.model import Result
from diag.report import write_bundle, verify_bundle


class ReportTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)

    def make_bundle(self):
        return write_bundle([Result('cpu.perf', 'skipped', 'permission_denied')], self.root,
                            {'mode': 'cpu', 'elapsed_seconds': 2.3, 'started_at_utc': '2026-01-01T00:00:00Z'})

    def test_missing_native_samples_cannot_be_complete(self):
        path = self.make_bundle()
        self.assertTrue(path.exists())
        manifest = verify_bundle(self.root)
        self.assertEqual(manifest['status'], 'partial')
        self.assertEqual(manifest['privacy'], 'private')
        self.assertIn('CPU 原生采样未完成', (self.root / 'summary.md').read_text())

    def test_tamper_is_rejected(self):
        self.make_bundle()
        (self.root / 'summary.md').write_text('tampered')
        with self.assertRaises(ValueError):
            verify_bundle(self.root)

    def test_path_traversal_symlinks_and_unlisted_files_are_rejected(self):
        self.make_bundle()
        checksums = self.root / 'checksums.sha256'
        self.assertTrue(checksums.exists())
        original = checksums.read_text()
        for name in ('../outside', '/etc/passwd', 'cpu/../../outside'):
            checksums.write_text(original + '0'*64 + '  ' + name + '\n')
            with self.assertRaises(ValueError):
                verify_bundle(self.root)
        checksums.write_text(original)
        (self.root / 'cpu').symlink_to('/tmp', target_is_directory=True)
        with self.assertRaises(ValueError):
            verify_bundle(self.root)

    def test_complete_is_only_used_when_every_collector_succeeded(self):
        write_bundle([Result('io.delta', 'ok')], self.root, {'mode': 'io'})
        self.assertEqual(verify_bundle(self.root)['status'], 'complete')
        self.assertEqual((self.root / 'manifest.json').stat().st_mode & 0o777, 0o600)

    def test_unknown_schema_is_rejected_even_with_updated_checksum(self):
        from diag.report import digest_file
        self.make_bundle()
        path = self.root / 'manifest.json'
        value = json.loads(path.read_text())
        value['schema_version'] = 999
        path.write_text(json.dumps(value))
        checksums = self.root / 'checksums.sha256'
        checksums.write_text('\n'.join(digest_file(path) + '  manifest.json' if line.endswith('  manifest.json') else line
                                       for line in checksums.read_text().splitlines()) + '\n')
        with self.assertRaisesRegex(ValueError, 'unsupported schema'):
            verify_bundle(self.root)

    def test_offline_analysis_leaves_original_checksums_unchanged(self):
        from diag.offline import analyze
        self.make_bundle()
        checksums = (self.root / 'checksums.sha256').read_bytes()
        path = analyze(self.root)
        self.addCleanup(lambda: __import__('shutil').rmtree(path.parent))
        self.assertTrue(path.is_file())
        self.assertEqual((self.root / 'checksums.sha256').read_bytes(), checksums)
        self.assertEqual(verify_bundle(self.root)['status'], 'partial')

    def test_human_analysis_uses_anonymous_workers_and_cgroups(self):
        from diag.offline import analyze
        result = Result('memory.delta', 'ok', data={
            'workers': {'98765': {'rss_change_kib': 3}},
            'cgroup_counter_deltas': {'/private-pod-identity': {'memory.events': {'oom': 0}}},
            'finished_at_utc': '2026-private-timestamp'})
        write_bundle([result], self.root, {'mode': 'memory'})
        path = analyze(self.root)
        self.addCleanup(lambda: __import__('shutil').rmtree(path.parent))
        text = path.read_text()
        self.assertNotIn('98765', text)
        self.assertNotIn('/private-pod-identity', text)
        self.assertNotIn('2026-private-timestamp', text)
        self.assertIn('worker-1', text)
        self.assertIn('cgroup-1', text)
