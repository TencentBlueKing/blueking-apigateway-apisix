from pathlib import Path
import struct
import tempfile
import unittest
from diag.elf import build_id
from diag.model import Budget
from diag.support import perf_argv, validated


def elf_fixture(note_offset=120, note_size=20):
    ident = b'\x7fELF\x02\x01\x01' + b'\0' * 9
    header = ident + struct.pack('<HHIQQQIHHHHHH', 3, 62, 1, 0, 64, 0, 0, 64, 56, 1, 0, 0, 0)
    ph = struct.pack('<IIQQQQQQ', 4, 0, note_offset, 0, 0, note_size, note_size, 4)
    note = struct.pack('<III', 4, 4, 3) + b'GNU\0' + bytes.fromhex('1234abcd')
    return header + ph + note


class SupportTests(unittest.TestCase):
    def test_bounded_elf_identity_rejects_corrupt_offsets(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'elf'
            path.write_bytes(elf_fixture())
            self.assertEqual(build_id(path), '1234abcd')
            for raw in (b'not elf', elf_fixture(2**60), elf_fixture(note_size=2**30), elf_fixture()[:75]):
                path.write_bytes(raw)
                self.assertIsNone(build_id(path))

    def test_support_requires_exact_identity_and_boolean_feature(self):
        context = dict(target_build_id='1234abcd', collector_digest='a'*64, architecture='x86_64',
                       kernel='6.6.test', perf_version='perf version 6.6', budget_version=1,
                       security={'seccomp': 2, 'cap_eff': '00000000', 'perf_event_paranoid': 4})
        entry = dict(context, perf_ip_validated=True, smaps_rollup_validated=False,
                     report='diag-validation.md#test')
        self.assertTrue(validated({'schema_version': 1, 'entries': [entry]}, context, 'perf_ip'))
        self.assertFalse(validated({'schema_version': 1, 'entries': [entry]}, context, 'smaps_rollup'))
        self.assertFalse(validated({'schema_version': 1, 'entries': [entry]}, dict(context, kernel='other'), 'perf_ip'))
        for matrix in ({}, {'schema_version': 1, 'entries': []}, {'schema_version': 2, 'entries': [entry]},
                       {'schema_version': 1, 'entries': [dict(entry, perf_ip_validated='true')]},
                       {'schema_version': 1, 'entries': [dict(entry, report='')]}):
            self.assertFalse(validated(matrix, context, 'perf_ip'))

    def test_perf_argv_is_single_worker_user_ip_only(self):
        argv = perf_argv(123, Path('/private/perf.data'), Budget(20))
        self.assertEqual(argv, ['/usr/bin/perf', 'record', '-e', 'cpu-clock:u', '-F', '19',
                               '-p', '123', '--no-inherit', '-m', '64K', '--no-buildid',
                               '--no-buildid-cache', '-o', '/private/perf.data', '--', '/bin/sleep', '10'])

    def test_unknown_security_fields_never_validate(self):
        context = dict(target_build_id='1234abcd', collector_digest='a'*64, architecture='x86_64',
                       kernel='6.6.test', perf_version='perf version 6.6', budget_version=1,
                       security={'seccomp': None, 'cap_eff': None, 'perf_event_paranoid': None})
        entry = dict(context, perf_ip_validated=True, report='validation.md')
        self.assertFalse(validated({'schema_version': 1, 'entries': [entry]}, context, 'perf_ip'))
