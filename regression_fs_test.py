#!/usr/bin/env python3
"""Filesystem regressions in disposable stores; accepts a dot binary path."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

BINARY = Path(sys.argv.pop(1)).resolve() if len(sys.argv) > 1 else Path('bin/dot').resolve()
ISSUE = ('---\ntitle: A\nstatus: open\npriority: 2\n'
         'created-at: 2026-01-01T00:00:00Z\n---\n\n')


class FilesystemRegression(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='dots-fs-regression-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.dots = self.root / '.dots'
        self.dots.mkdir()

    def run_dot(self, *args):
        return subprocess.run([str(BINARY), *args], cwd=self.root,
                              capture_output=True, timeout=8,
                              env=dict(os.environ, NO_COLOR='1'))

    def test_purge_unlinks_archive_symlink_without_traversing(self):
        external = self.root / 'external'
        external.mkdir()
        sentinel = external / 'sentinel.txt'
        sentinel.write_text('untouched')
        (self.dots / 'archive').symlink_to(external, target_is_directory=True)

        result = self.run_dot('purge')

        self.assertEqual((result.returncode, result.stdout, result.stderr),
                         (0, b'Archive purged\n', b''))
        self.assertEqual(sentinel.read_text(), 'untouched')
        self.assertTrue((self.dots / 'archive').is_dir())
        self.assertFalse((self.dots / 'archive').is_symlink())
        self.assertEqual(list((self.dots / 'archive').iterdir()), [])

    def test_fix_skips_orphan_symlink_and_linked_issue(self):
        (self.dots / 'archive').mkdir()
        external = self.root / 'external'
        external.mkdir()
        issue = external / 'x.md'
        issue.write_text(ISSUE)
        (self.dots / 'orphan').symlink_to(external, target_is_directory=True)

        result = self.run_dot('fix')

        self.assertEqual((result.returncode, result.stdout, result.stderr),
                         (0, b'No fixes needed\n', b''))
        self.assertEqual(issue.read_text(), ISSUE)
        self.assertTrue((self.dots / 'orphan').is_symlink())
        self.assertFalse((self.dots / 'x.md').exists())

    def test_fix_skips_symlink_child(self):
        (self.dots / 'archive').mkdir()
        external = self.root / 'external.md'
        external.write_text(ISSUE)
        orphan = self.dots / 'orphan'
        orphan.mkdir()
        (orphan / 'x.md').symlink_to(external)

        result = self.run_dot('fix')

        self.assertEqual((result.returncode, result.stdout, result.stderr),
                         (0, b'Fixed 1 orphan parent(s), moved 0 file(s)\n', b''))
        self.assertEqual(external.read_text(), ISSUE)
        self.assertTrue((orphan / 'x.md').is_symlink())
        self.assertFalse((self.dots / 'x.md').exists())

    def test_read_only_store_reports_permission_denied(self):
        (self.dots / 'archive').mkdir()
        issue = self.dots / 'a.md'
        issue.write_text(ISSUE)
        self.dots.chmod(0o555)
        try:
            result = self.run_dot('update', 'a', '--status', 'done')
        finally:
            self.dots.chmod(0o755)

        self.assertEqual((result.returncode, result.stdout, result.stderr),
                         (1, b'', b'Permission denied\n'))
        self.assertEqual(issue.read_text(), ISSUE)
        self.assertEqual(sorted(x.name for x in self.dots.iterdir()), ['a.md', 'archive'])

    def test_archive_directory_collision_reports_error(self):
        archive = self.dots / 'archive' / 'a'
        archive.mkdir(parents=True)
        sentinel = archive / 'sentinel.txt'
        sentinel.write_text('untouched')
        active = self.dots / 'a'
        active.mkdir()
        (active / 'a.md').write_text(ISSUE)

        result = self.run_dot('close', 'a')

        self.assertEqual((result.returncode, result.stdout, result.stderr),
                         (1, b'', b'Unexpected internal error (code: DirNotEmpty)\n'))
        self.assertEqual(sentinel.read_text(), 'untouched')
        self.assertTrue((active / 'a.md').is_file())


if __name__ == '__main__':
    unittest.main()
