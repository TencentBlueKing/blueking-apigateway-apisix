from pathlib import Path
import tempfile
import unittest
from diag.offline import parse_hotspots, validate_symbols
from test_diag_support import elf_fixture


class OfflineTests(unittest.TestCase):
    def test_counts_and_periods_have_different_denominators(self):
        text = '# header\n75.00;300;1;nginx;[.] spin_lock\n25.00;100;3;[unknown];[.] 0x12\n'
        value = parse_hotspots(text)
        self.assertEqual(value.get('sample_count'), 4)
        self.assertEqual(value['period_total'], 400)
        self.assertEqual(value['unresolved_sample_fraction'], .75)
        self.assertEqual(value['rows'][0]['sample_fraction'], .25)
        self.assertEqual(value['rows'][0]['period_fraction'], .75)
        self.assertIsNone(value['lost_samples'])

    def test_empty_or_malformed_report_is_not_a_success(self):
        for text in ('', '# no samples\n', 'malformed;report\n'):
            self.assertEqual(parse_hotspots(text).get('status'), 'unavailable')

    def test_mismatched_build_ids_and_symbol_symlinks_are_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'bin').mkdir()
            elf = root / 'bin/nginx'
            elf.write_bytes(elf_fixture())
            items = [{'path': '/bin/nginx', 'build_id': '1234abcd'}]
            self.assertEqual(len(validate_symbols(items, root)), 1)
            for bad in [[{'path': '/bin/nginx', 'build_id': 'deadbeef'}],
                        [{'path': '/../../etc/passwd', 'build_id': '1234abcd'}]]:
                with self.assertRaises(ValueError):
                    validate_symbols(bad, root)
            elf.unlink()
            elf.symlink_to('/bin/sh')
            with self.assertRaises(ValueError):
                validate_symbols(items, root)
