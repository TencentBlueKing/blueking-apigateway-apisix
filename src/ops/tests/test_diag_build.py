import importlib.util
from pathlib import Path
import tempfile
import unittest
from test_diag_support import elf_fixture

spec = importlib.util.spec_from_file_location('build_diag', Path(__file__).resolve().parents[2] / 'build/bin/build-diag-manifest.py')
build_diag = importlib.util.module_from_spec(spec)
spec.loader.exec_module(build_diag)


class BuildTests(unittest.TestCase):
    def test_library_candidates_exclude_html_matching_so_glob(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'posix.sys.socket.html').write_text('documentation')
            (root / 'libreal.so.1').write_bytes(elf_fixture())
            candidates = build_diag.library_candidates(root)
            self.assertEqual(candidates, {root / 'libreal.so.1'})
