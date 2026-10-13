#!/usr/bin/env python3
"""Concurrent writers on disposable Dots stores; accepts a dot binary path."""

from concurrent.futures import ThreadPoolExecutor
import fcntl
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest


BINARY = Path(sys.argv.pop(1)).resolve() if len(sys.argv) > 1 else Path('bin/dot').resolve()
ISSUE = ('---\ntitle: A\nstatus: open\npriority: 2\n'
         'created-at: 2026-01-01T00:00:00Z\n---\n\n')


class ConcurrencyRegression(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='dots-concurrency-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.dots = self.root / '.dots'
        (self.dots / 'archive').mkdir(parents=True)

    def run_dot(self, *args):
        return subprocess.run([str(BINARY), *args], cwd=self.root,
                              capture_output=True, timeout=15,
                              env=dict(os.environ, NO_COLOR='1'))

    def assert_clean(self):
        self.assertEqual([p for p in self.dots.rglob('*') if '.tmp-' in p.name], [])

    def assert_ok(self, results):
        self.assertEqual([(p.returncode, p.stderr) for p in results],
                         [(0, b'')] * len(results))

    def test_writer_waits_before_loading_issue(self):
        active = self.dots / 'a.md'
        active.write_text(ISSUE)
        fd = os.open(self.root, os.O_RDONLY)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX)
            proc = subprocess.Popen([str(BINARY), 'update', 'a', '--status', 'done'],
                                    cwd=self.root, stdout=subprocess.PIPE,
                                    stderr=subprocess.PIPE)
            try:
                # The writer must wait on the held directory lock. Change the
                # source while it waits to also prove it has not loaded state.
                time.sleep(0.2)
                self.assertIsNone(proc.poll())
                active.write_text(ISSUE.replace('title: A', 'title: Changed'))
                fcntl.flock(fd, fcntl.LOCK_UN)
                stdout, stderr = proc.communicate(timeout=15)
            finally:
                if proc.poll() is None:
                    proc.kill()
                proc.communicate()
        finally:
            os.close(fd)
        self.assertEqual((proc.returncode, stderr), (0, b''), stdout)
        self.assertFalse(active.exists())
        self.assertIn('title: Changed', (self.dots / 'archive/a.md').read_text())
        self.assert_clean()

    def test_same_issue_updates_keep_one_location(self):
        active = self.dots / 'a.md'
        archived = self.dots / 'archive/a.md'
        active.write_text(ISSUE)
        for _ in range(4):
            with ThreadPoolExecutor(max_workers=6) as pool:
                results = list(pool.map(
                    lambda i: self.run_dot('update', 'a', '--status',
                                           'done' if i % 2 else 'open'),
                    range(18)))
            self.assert_ok(results)
            self.assertEqual(int(active.exists()) + int(archived.exists()), 1)
            only = active if active.exists() else archived
            self.assertIn('title: A', only.read_text())
            self.assert_clean()

    def test_distinct_adds_and_closes_are_not_lost(self):
        (self.dots / 'a.md').write_text(ISSUE)
        (self.dots / 'b.md').write_text(ISSUE.replace('title: A', 'title: B'))
        with ThreadPoolExecutor(max_workers=6) as pool:
            results = list(pool.map(lambda i: self.run_dot('add', f'Concurrent {i}'),
                                    range(24)))
        self.assert_ok(results)
        self.assertEqual(len({p.stdout.strip() for p in results}), 24)
        issue_files = list(self.dots.rglob('*.md'))
        self.assertEqual(len(issue_files), 26)
        for i in range(24):
            self.assertEqual(sum(f'title: Concurrent {i}\n' in p.read_text()
                                 for p in issue_files), 1)

        with ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(lambda issue_id: self.run_dot('close', issue_id),
                                    ('a', 'b')))
        self.assert_ok(results)
        for issue_id in ('a', 'b'):
            self.assertFalse((self.dots / f'{issue_id}.md').exists())
            self.assertTrue((self.dots / 'archive' / f'{issue_id}.md').exists())
        self.assert_clean()

    def test_concurrent_init_without_existing_store(self):
        (self.dots / 'archive').rmdir()
        self.dots.rmdir()
        with ThreadPoolExecutor(max_workers=6) as pool:
            results = list(pool.map(lambda _: self.run_dot('init'), range(12)))
        self.assert_ok(results)
        self.assertTrue((self.dots / 'archive').is_dir())
        self.assert_clean()


if __name__ == '__main__':
    unittest.main()
