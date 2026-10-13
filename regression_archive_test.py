#!/usr/bin/env python3
"""Archive transitions and failure atomicity in disposable Dots stores."""

import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


BINARY = Path(sys.argv.pop(1)).resolve() if len(sys.argv) > 1 else Path('bin/dot').resolve()


def issue(title, status='open'):
    return (f'---\ntitle: {title}\nstatus: {status}\npriority: 2\n'
            'created-at: 2026-01-01T00:00:00Z\n---\n\n').encode()


class ArchiveRegression(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='dots-archive-regression-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.dots = self.root / '.dots'
        (self.dots / 'archive').mkdir(parents=True)

    def run_dot(self, *args):
        return subprocess.run([str(BINARY), *args], cwd=self.root,
                              capture_output=True, timeout=8,
                              env=dict(os.environ, NO_COLOR='1'))

    def ok(self, *args):
        result = self.run_dot(*args)
        self.assertEqual((result.returncode, result.stderr), (0, b''), result.stdout)
        return result

    def test_close_then_reopen_moves_single_issue_to_active_storage(self):
        active = self.dots / 'a.md'
        archived = self.dots / 'archive/a.md'
        active.write_bytes(issue('A'))

        self.ok('close', 'a', '--reason', 'finished')
        self.assertFalse(active.exists())
        self.assertIn(b'status: closed', archived.read_bytes())
        self.ok('on', 'a')

        self.assertFalse(archived.exists())
        reopened = active.read_bytes()
        self.assertIn(b'status: active', reopened)
        self.assertNotIn(b'closed-at:', reopened)
        self.assertNotIn(b'close-reason:', reopened)
        self.assertIn(b'"id":"a"', self.ok('ls', '--json').stdout)

    def test_parent_and_child_cache_rebase_on_close_and_reopen(self):
        parent = self.dots / 'p'
        parent.mkdir()
        (parent / 'p.md').write_bytes(issue('Parent'))
        (parent / 'child.md').write_bytes(issue('Child', 'closed'))

        self.ok('close', 'p')
        self.assertFalse(parent.exists())
        archived = self.dots / 'archive/p'
        self.assertTrue((archived / 'child.md').exists())
        self.ok('on', 'p', 'child')

        self.assertFalse(archived.exists())
        self.assertIn(b'status: active', (parent / 'p.md').read_bytes())
        self.assertIn(b'status: active', (parent / 'child.md').read_bytes())

    def test_multi_id_close_and_reopen(self):
        for name in ('a', 'b'):
            (self.dots / f'{name}.md').write_bytes(issue(name))

        self.ok('off', 'a', 'b')
        for name in ('a', 'b'):
            self.assertFalse((self.dots / f'{name}.md').exists())
            self.assertIn(b'status: closed', (self.dots / 'archive' / f'{name}.md').read_bytes())
        self.ok('on', 'a', 'b')
        for name in ('a', 'b'):
            self.assertFalse((self.dots / 'archive' / f'{name}.md').exists())
            self.assertIn(b'status: active', (self.dots / f'{name}.md').read_bytes())

    def test_later_close_failure_preserves_the_failing_id(self):
        (self.dots / 'a.md').write_bytes(issue('A'))
        original = issue('B')
        (self.dots / 'b.md').write_bytes(original)
        collision = self.dots / 'archive/b.md'
        collision.mkdir()
        sentinel = collision / 'sentinel.txt'
        sentinel.write_bytes(b'untouched')

        result = self.run_dot('off', 'a', 'b')

        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b'status: closed', (self.dots / 'archive/a.md').read_bytes())
        self.assertEqual((self.dots / 'b.md').read_bytes(), original)
        self.assertEqual(sentinel.read_bytes(), b'untouched')

    def test_later_reopen_failure_preserves_the_failing_id(self):
        (self.dots / 'archive/a.md').write_bytes(issue('A', 'closed'))
        original = issue('B', 'closed')
        (self.dots / 'archive/b.md').write_bytes(original)
        collision = self.dots / 'b.md'
        collision.mkdir()
        sentinel = collision / 'sentinel.txt'
        sentinel.write_bytes(b'untouched')

        result = self.run_dot('on', 'a', 'b')

        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b'status: active', (self.dots / 'a.md').read_bytes())
        self.assertEqual((self.dots / 'archive/b.md').read_bytes(), original)
        self.assertEqual(sentinel.read_bytes(), b'untouched')

    def test_failed_archive_move_preserves_parent_and_child_bytes(self):
        parent = self.dots / 'p'
        parent.mkdir()
        parent_bytes = issue('Parent')
        child_bytes = issue('Child', 'closed')
        (parent / 'p.md').write_bytes(parent_bytes)
        (parent / 'child.md').write_bytes(child_bytes)
        collision = self.dots / 'archive/p'
        collision.mkdir()
        sentinel = collision / 'sentinel.txt'
        sentinel.write_bytes(b'untouched')

        result = self.run_dot('close', 'p')

        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((parent / 'p.md').read_bytes(), parent_bytes)
        self.assertEqual((parent / 'child.md').read_bytes(), child_bytes)
        self.assertEqual(sentinel.read_bytes(), b'untouched')

    def test_failed_close_write_rolls_parent_folder_back(self):
        parent = self.dots / 'p'
        parent.mkdir()
        original = issue('Parent')
        (parent / 'p.md').write_bytes(original)
        parent.chmod(0o555)
        self.addCleanup(parent.chmod, 0o755)

        result = self.run_dot('close', 'p')

        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((parent / 'p.md').read_bytes(), original)
        self.assertFalse((self.dots / 'archive/p').exists())

    def test_failed_reopen_write_rolls_parent_folder_back(self):
        archived = self.dots / 'archive/p'
        archived.mkdir()
        original = issue('Parent', 'closed')
        (archived / 'p.md').write_bytes(original)
        archived.chmod(0o555)
        self.addCleanup(archived.chmod, 0o755)

        result = self.run_dot('on', 'p')

        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((archived / 'p.md').read_bytes(), original)
        self.assertFalse((self.dots / 'p').exists())

    def test_archive_symlink_is_rejected_without_external_writes(self):
        original = issue('A')
        (self.dots / 'a.md').write_bytes(original)
        external = self.root / 'external'
        external.mkdir()
        sentinel = external / 'sentinel.txt'
        sentinel.write_bytes(b'untouched')
        (self.dots / 'archive').rmdir()
        (self.dots / 'archive').symlink_to(external, target_is_directory=True)

        result = self.run_dot('close', 'a')

        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b'Unsafe archive symlink', result.stderr)
        self.assertEqual((self.dots / 'a.md').read_bytes(), original)
        self.assertEqual(sentinel.read_bytes(), b'untouched')
        self.assertEqual(sorted(p.name for p in external.iterdir()), ['sentinel.txt'])
        self.assertTrue((self.dots / 'archive').is_symlink())

    def test_reopen_rejects_archive_symlink_without_external_writes(self):
        external = self.root / 'external'
        external.mkdir()
        original = issue('A', 'closed')
        (external / 'a.md').write_bytes(original)
        (self.dots / 'archive').rmdir()
        (self.dots / 'archive').symlink_to(external, target_is_directory=True)

        result = self.run_dot('on', 'a')

        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b'Unsafe archive symlink', result.stderr)
        self.assertEqual((external / 'a.md').read_bytes(), original)
        self.assertFalse((self.dots / 'a.md').exists())
        self.assertTrue((self.dots / 'archive').is_symlink())


if __name__ == '__main__':
    unittest.main()
