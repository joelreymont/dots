#!/usr/bin/env python3
"""Exercise real read/write failures without touching a live task store."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent
BINARY = Path(sys.argv.pop(1)).resolve() if len(sys.argv) > 1 else ROOT / 'bin/dot'
WRITE_ERROR = b'Unexpected internal error (code: WriteFailed)\n'


class IORegression(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='dots-io-regression-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / '.dots/archive').mkdir(parents=True)

    def broken_pipe(self, *args):
        read_fd, write_fd = os.pipe()
        os.close(read_fd)
        try:
            return subprocess.run([str(BINARY), *args], cwd=self.root,
                                  stdout=write_fd, stderr=subprocess.PIPE, timeout=10)
        finally:
            os.close(write_fd)

    def test_closed_pipe_reports_error_for_help(self):
        result = self.broken_pipe('help')
        self.assertEqual((result.returncode, result.stderr), (1, WRITE_ERROR))

    def test_closed_pipe_after_add_leaves_one_complete_task(self):
        result = self.broken_pipe('add', 'Output failure task')
        self.assertEqual((result.returncode, result.stderr), (1, WRITE_ERROR))
        files = list((self.root / '.dots').glob('*.md'))
        self.assertEqual(len(files), 1)
        self.assertIn(b'title: Output failure task\n', files[0].read_bytes())
        self.assertTrue(files[0].read_bytes().endswith(b'---\n'))
        self.assertEqual(sorted(p.name for p in (self.root / '.dots').iterdir()),
                         sorted(['archive', 'config', files[0].name]))

    def test_closed_stdout_does_not_fail_a_silent_mutation(self):
        task = self.root / '.dots/a.md'
        task.write_text('---\ntitle: A\nstatus: open\npriority: 2\n'
                        'created-at: 2026-01-01T00:00:00Z\n---\n')
        result = subprocess.run([str(BINARY), 'on', 'a'], cwd=self.root,
                                stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
                                preexec_fn=lambda: os.close(1), timeout=10)
        self.assertEqual((result.returncode, result.stderr), (0, b''))
        self.assertIn(b'status: active\n', task.read_bytes())

    def test_read_only_stdout_reports_write_error(self):
        with open(os.devnull, 'rb') as output:
            result = subprocess.run([str(BINARY), 'help'], cwd=self.root,
                                    stdout=output, stderr=subprocess.PIPE, timeout=10)
        self.assertEqual((result.returncode, result.stderr), (1, WRITE_ERROR))

    def test_large_json_output_survives_small_pipe_reads(self):
        title = 'x' * 100_000
        (self.root / '.dots/a.md').write_text(
            f'---\ntitle: {title}\nstatus: open\npriority: 2\n'
            'created-at: 2026-01-01T00:00:00Z\n---\n\n')
        with subprocess.Popen([str(BINARY), 'ls', '--json'], cwd=self.root,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE) as child:
            chunks = []
            while chunk := child.stdout.read(127):
                chunks.append(chunk)
            stderr = child.stderr.read()
            self.assertEqual((child.wait(timeout=10), stderr), (0, b''))
        rows = json.loads(b''.join(chunks))
        self.assertEqual(len(rows), 1)
        self.assertEqual((rows[0]['id'], rows[0]['title']), ('a', title))

    def test_reader_closes_after_partial_json_output(self):
        title = 'x' * 500_000
        (self.root / '.dots/a.md').write_text(
            f'---\ntitle: {title}\nstatus: open\npriority: 2\n'
            'created-at: 2026-01-01T00:00:00Z\n---\n\n')
        with subprocess.Popen([str(BINARY), 'ls', '--json'], cwd=self.root,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE) as child:
            self.assertEqual(len(child.stdout.read(128)), 128)
            child.stdout.close()
            stderr = child.stderr.read()
            self.assertEqual((child.wait(timeout=10), stderr), (1, WRITE_ERROR))

    def test_failed_read_is_not_eof(self):
        # The CLI imports only regular files, which offer no deterministic read
        # failure, so the probe loads main.f and runs IMPORT-JSONL, the import
        # path after that check, on a directory: its open succeeds, its read fails.
        (self.root / 'import.jsonl').mkdir()
        script = self.root / 'read-probe.f'
        script.write_text(f'require {ROOT / "main.f"}\npackage DOT-READ\n'
                          ': PROBE ( -- ) s" import.jsonl" IMPORT-JSONL ;\n'
                          'PROBE\n;package\n')
        result = subprocess.run(['hb', '--load', str(script)],
                                cwd=self.root, capture_output=True, timeout=10)
        self.assertEqual((result.returncode, result.stdout, result.stderr),
                         (1, b'', b'I/O error\n'))


if __name__ == '__main__':
    unittest.main()
