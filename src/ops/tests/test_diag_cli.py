import contextlib
import io
from pathlib import Path
import subprocess
import sys
import unittest
from diag.cli import main


class CLITests(unittest.TestCase):
    def test_help_and_invalid_arguments_never_start_collection(self):
        for args, code in [([], 64), (['--cpu', '--memory'], 64), (['--help'], 0),
                           (['--cpu', '--duration', '100'], 64), (['--cp'], 64)]:
            with self.subTest(args=args), contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(main(args), code)

    def test_help_works_from_unrelated_working_directory(self):
        path = Path(__file__).resolve().parents[1] / 'apisix-diag'
        p = subprocess.run([sys.executable, str(path), '--help'], cwd='/', capture_output=True)
        self.assertEqual(p.returncode, 0)
        self.assertIn(b'--cpu', p.stdout)

    def test_interrupt_retains_a_verifiable_partial_bundle(self):
        import os
        import signal
        import tempfile
        import time
        from diag.report import verify_bundle
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            output = root / 'evidence'
            control = root / 'control'
            script = ('import sys; from pathlib import Path; import diag.cli as cli; '
                      'from diag.runtime import ControlLock; '
                      'cli.ControlLock=lambda: ControlLock(Path(sys.argv[2])); '
                      'sys.exit(cli.main(["--memory", "--output-dir",sys.argv[1]]))')
            env = dict(os.environ, PYTHONPATH=str(Path(__file__).resolve().parents[1]))
            process = subprocess.Popen([sys.executable, '-c', script, str(output), str(control)],
                                       env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
            try:
                deadline = time.monotonic() + 5
                while not list(output.glob('run-*/raw/baseline.json')) and time.monotonic() < deadline:
                    if process.poll() is not None:
                        break
                    time.sleep(.02)
                self.assertIsNone(process.poll())
                process.send_signal(signal.SIGINT)
                process.wait(timeout=5)
                self.assertEqual(process.returncode, 130)
                run = next(output.glob('run-*'))
                self.assertEqual(verify_bundle(run)['status'], 'interrupted')
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait()
                process.stderr.close()

    def test_copy_command_quotes_custom_output_directory(self):
        import shlex
        import tempfile
        from unittest.mock import patch
        from diag.model import Result
        from diag.runtime import ControlLock
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            output = root / 'evidence with spaces'
            stdout = io.StringIO()
            with patch('diag.cli.ControlLock', side_effect=lambda: ControlLock(root / 'control')), \
                    patch('diag.cli.collect', return_value=[Result('baseline', 'ok')]), \
                    patch('diag.cli.os.nice'), contextlib.redirect_stdout(stdout):
                self.assertEqual(main(['--io', '--output-dir', str(output)]), 0)
            run = next(output.glob('run-*'))
            line = next(line for line in stdout.getvalue().splitlines() if line.startswith('Copy once'))
            argv = shlex.split(line.split(': ', 1)[1])
            self.assertEqual(argv[-2], 'POD:' + str(run))
