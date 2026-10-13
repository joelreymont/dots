#!/usr/bin/env python3
"""Archive transitions and failure atomicity in disposable Dots stores."""

import os
import resource
import signal
from pathlib import Path
import shutil
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

    def test_direct_archived_child_reopens_parent_and_preserves_siblings(self):
        archived = self.dots / 'archive/p'
        archived.mkdir()
        (archived / 'p.md').write_bytes(issue('Parent', 'closed'))
        (archived / 'c.md').write_bytes(issue('Child', 'closed'))
        sibling = issue('Sibling', 'closed').replace(b'---\n\n', b'blocks:\n  - c\n---\n\n')
        (archived / 's.md').write_bytes(sibling)

        self.ok('on', 'c')

        active = self.dots / 'p'
        self.assertFalse(archived.exists())
        self.assertIn(b'status: open', (active / 'p.md').read_bytes())
        self.assertIn(b'status: active', (active / 'c.md').read_bytes())
        self.assertEqual((active / 's.md').read_bytes(), sibling)

    def test_nested_archived_child_reopens_each_closed_ancestor(self):
        archived = self.dots / 'archive/container'
        (archived / 'p').mkdir(parents=True)
        (archived / 'container.md').write_bytes(issue('Container', 'closed'))
        (archived / 'p/p.md').write_bytes(issue('Parent', 'closed'))
        (archived / 'p/leaf.md').write_bytes(issue('Child', 'closed'))
        sibling = issue('Sibling', 'closed')
        (archived / 'p/s.md').write_bytes(sibling)
        outer_sibling = issue('Outer sibling', 'closed')
        (archived / 'outer.md').write_bytes(outer_sibling)

        self.ok('on', 'leaf')

        active = self.dots / 'container'
        self.assertFalse(archived.exists())
        self.assertIn(b'status: open', (active / 'container.md').read_bytes())
        self.assertIn(b'status: open', (active / 'p/p.md').read_bytes())
        self.assertIn(b'status: active', (active / 'p/leaf.md').read_bytes())
        self.assertEqual((active / 'p/s.md').read_bytes(), sibling)
        self.assertEqual((active / 'outer.md').read_bytes(), outer_sibling)

    def test_nested_archived_parent_preserves_its_folder(self):
        archived = self.dots / 'archive/container/p'
        archived.mkdir(parents=True)
        (archived / 'p.md').write_bytes(issue('Parent', 'closed'))
        child = issue('Child', 'closed')
        (archived / 'c.md').write_bytes(child)

        self.ok('on', 'p')

        self.assertFalse((self.dots / 'archive/container/p').exists())
        self.assertIn(b'status: active', (self.dots / 'container/p/p.md').read_bytes())
        self.assertEqual((self.dots / 'container/p/c.md').read_bytes(), child)
        self.assertFalse((self.dots / 'p.md').exists())

    def test_nested_parent_round_trips_beside_active_container(self):
        container = self.dots / 'container'
        parent = container / 'p'
        parent.mkdir(parents=True)
        container_bytes = issue('Container')
        closed_child = issue('Child', 'closed')
        (container / 'container.md').write_bytes(container_bytes)
        (parent / 'p.md').write_bytes(issue('Parent'))
        (parent / 'c.md').write_bytes(closed_child)

        for _ in range(2):
            self.ok('close', 'p')
            self.assertFalse(parent.exists())
            self.assertTrue((self.dots / 'archive/container/p/p.md').exists())
            self.assertEqual((container / 'container.md').read_bytes(), container_bytes)
            self.ok('on', 'p')
            self.assertFalse((self.dots / 'archive/container/p').exists())
            self.assertIn(b'status: active', (parent / 'p.md').read_bytes())
            self.assertEqual((parent / 'c.md').read_bytes(), closed_child)
            self.assertEqual((container / 'container.md').read_bytes(), container_bytes)

    def test_nested_archived_child_reopens_beside_active_container(self):
        container = self.dots / 'container'
        container.mkdir()
        active_parent = issue('Container')
        active_sibling = issue('Active sibling')
        (container / 'container.md').write_bytes(active_parent)
        (container / 'other.md').write_bytes(active_sibling)
        archived = self.dots / 'archive/container/p'
        archived.mkdir(parents=True)
        (archived / 'p.md').write_bytes(issue('Parent', 'closed'))
        (archived / 'leaf.md').write_bytes(issue('Leaf', 'closed'))
        archived_sibling = issue('Archived sibling', 'closed')
        (archived / 's.md').write_bytes(archived_sibling)

        self.ok('on', 'leaf')

        self.assertFalse(archived.exists())
        self.assertIn(b'status: open', (container / 'p/p.md').read_bytes())
        self.assertIn(b'status: active', (container / 'p/leaf.md').read_bytes())
        self.assertEqual((container / 'p/s.md').read_bytes(), archived_sibling)
        self.assertEqual((container / 'container.md').read_bytes(), active_parent)
        self.assertEqual((container / 'other.md').read_bytes(), active_sibling)

    def test_archived_nonclosed_ancestor_moves_with_child_unchanged(self):
        for status in ('open', 'active'):
            with self.subTest(status=status):
                archived = self.dots / 'archive/container/p'
                archived.mkdir(parents=True, exist_ok=True)
                ancestor = issue('Container', status)
                (archived.parent / 'container.md').write_bytes(ancestor)
                (archived / 'p.md').write_bytes(issue('Parent', 'closed'))
                (archived / 'leaf.md').write_bytes(issue('Leaf', 'closed'))

                self.ok('on', 'leaf')

                active = self.dots / 'container'
                self.assertFalse(archived.parent.exists())
                self.assertEqual((active / 'container.md').read_bytes(), ancestor)
                self.assertIn(b'status: open', (active / 'p/p.md').read_bytes())
                self.assertIn(b'status: active', (active / 'p/leaf.md').read_bytes())
                shutil.rmtree(self.dots)
                (self.dots / 'archive').mkdir(parents=True)

    def test_nested_reopen_creates_missing_parent_and_rolls_it_back_on_failure(self):
        archived = self.dots / 'archive/container/p'
        archived.mkdir(parents=True)
        parent = issue('Parent', 'closed')
        (archived / 'p.md').write_bytes(parent)
        archived.chmod(0o555)
        self.addCleanup(archived.chmod, 0o755)

        result = self.run_dot('on', 'p')

        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((archived / 'p.md').read_bytes(), parent)
        self.assertFalse((self.dots / 'container').exists())

    def test_post_move_write_failure_removes_created_active_parent(self):
        archived = self.dots / 'archive/container/p'
        archived.mkdir(parents=True)
        parent = issue('Parent', 'closed')
        child = issue('Child', 'closed')
        (archived / 'p.md').write_bytes(parent)
        (archived / 'c.md').write_bytes(child)
        before = sorted(str(p.relative_to(self.dots)) for p in self.dots.rglob('*'))

        def fail_writes():
            signal.signal(signal.SIGXFSZ, signal.SIG_IGN)
            resource.setrlimit(resource.RLIMIT_FSIZE, (0, 0))

        result = subprocess.run([str(BINARY), 'on', 'p'], cwd=self.root,
                                capture_output=True, timeout=8,
                                env=dict(os.environ, NO_COLOR='1'),
                                preexec_fn=fail_writes)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b'I/O error', result.stderr)
        self.assertEqual((archived / 'p.md').read_bytes(), parent)
        self.assertEqual((archived / 'c.md').read_bytes(), child)
        self.assertFalse((self.dots / 'container').exists())
        self.assertEqual(sorted(str(p.relative_to(self.dots)) for p in self.dots.rglob('*')),
                         before)

    def test_nested_reopen_rejects_symlinked_active_parent(self):
        archived = self.dots / 'archive/container/p'
        archived.mkdir(parents=True)
        parent = issue('Parent', 'closed')
        (archived / 'p.md').write_bytes(parent)
        external = self.root / 'external'
        external.mkdir()
        sentinel = external / 'sentinel.txt'
        sentinel.write_bytes(b'untouched')
        (self.dots / 'container').symlink_to(external, target_is_directory=True)

        result = self.run_dot('on', 'p')

        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b'Unsafe active symlink', result.stderr)
        self.assertEqual((archived / 'p.md').read_bytes(), parent)
        self.assertEqual(sentinel.read_bytes(), b'untouched')
        self.assertEqual(sorted(p.name for p in external.iterdir()), ['sentinel.txt'])

    def test_nested_parent_refuses_close_while_child_is_open(self):
        folder = self.dots / 'container/p'
        folder.mkdir(parents=True)
        parent = issue('Parent')
        child = issue('Child')
        (folder / 'p.md').write_bytes(parent)
        (folder / 'leaf.md').write_bytes(child)

        result = self.run_dot('close', 'p')

        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b'children are not all closed', result.stderr)
        self.assertEqual((folder / 'p.md').read_bytes(), parent)
        self.assertEqual((folder / 'leaf.md').read_bytes(), child)
        self.assertFalse((self.dots / 'archive/container').exists())

    def test_container_refuses_close_with_open_nested_descendant(self):
        container = self.dots / 'container'
        nested = container / 'p'
        nested.mkdir(parents=True)
        parent = issue('Container')
        closed_nested_parent = issue('Nested parent', 'closed')
        open_leaf = issue('Open leaf')
        (container / 'container.md').write_bytes(parent)
        (nested / 'p.md').write_bytes(closed_nested_parent)
        (nested / 'leaf.md').write_bytes(open_leaf)

        result = self.run_dot('close', 'container')

        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b'children are not all closed', result.stderr)
        self.assertEqual((container / 'container.md').read_bytes(), parent)
        self.assertEqual((nested / 'p.md').read_bytes(), closed_nested_parent)
        self.assertEqual((nested / 'leaf.md').read_bytes(), open_leaf)
        self.assertFalse((self.dots / 'archive/container').exists())

    def test_container_refuses_close_with_malformed_nested_descendant(self):
        container = self.dots / 'container'
        nested = container / 'p'
        nested.mkdir(parents=True)
        parent = issue('Container')
        malformed = b'not frontmatter\n'
        (container / 'container.md').write_bytes(parent)
        (nested / 'leaf.md').write_bytes(malformed)

        result = self.run_dot('close', 'container')

        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((container / 'container.md').read_bytes(), parent)
        self.assertEqual((nested / 'leaf.md').read_bytes(), malformed)
        self.assertFalse((self.dots / 'archive/container').exists())

    def test_container_with_closed_nested_descendants_round_trips(self):
        container = self.dots / 'container'
        nested = container / 'p'
        nested.mkdir(parents=True)
        nested_parent = issue('Nested parent', 'closed')
        nested_child = issue('Nested child', 'closed')
        (container / 'container.md').write_bytes(issue('Container'))
        (nested / 'p.md').write_bytes(nested_parent)
        (nested / 'leaf.md').write_bytes(nested_child)

        self.ok('close', 'container')
        self.assertFalse(container.exists())
        archived = self.dots / 'archive/container'
        self.assertEqual((archived / 'p/p.md').read_bytes(), nested_parent)
        self.assertEqual((archived / 'p/leaf.md').read_bytes(), nested_child)
        self.ok('on', 'container')
        self.assertFalse(archived.exists())
        self.assertIn(b'status: active', (container / 'container.md').read_bytes())
        self.assertEqual((nested / 'p.md').read_bytes(), nested_parent)
        self.assertEqual((nested / 'leaf.md').read_bytes(), nested_child)

    def test_orphan_ancestor_folder_moves_without_new_parent_task(self):
        archived = self.dots / 'archive/container/p'
        archived.mkdir(parents=True)
        (archived / 'p.md').write_bytes(issue('Parent', 'closed'))

        self.ok('on', 'p')

        self.assertIn(b'status: active', (self.dots / 'container/p/p.md').read_bytes())
        self.assertFalse((self.dots / 'container/container.md').exists())

    def test_malformed_ancestor_refuses_child_reopen_without_changes(self):
        archived = self.dots / 'archive/p'
        archived.mkdir()
        malformed = b'not frontmatter\n'
        child = issue('Child', 'closed')
        (archived / 'p.md').write_bytes(malformed)
        (archived / 'c.md').write_bytes(child)

        result = self.run_dot('on', 'c')

        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((archived / 'p.md').read_bytes(), malformed)
        self.assertEqual((archived / 'c.md').read_bytes(), child)
        self.assertFalse((self.dots / 'p').exists())

    def test_readonly_ancestor_rolls_back_child_reopen(self):
        archived = self.dots / 'archive/p'
        archived.mkdir()
        parent = issue('Parent', 'closed')
        child = issue('Child', 'closed')
        (archived / 'p.md').write_bytes(parent)
        (archived / 'c.md').write_bytes(child)
        archived.chmod(0o555)
        self.addCleanup(archived.chmod, 0o755)

        result = self.run_dot('on', 'c')

        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((archived / 'p.md').read_bytes(), parent)
        self.assertEqual((archived / 'c.md').read_bytes(), child)
        self.assertFalse((self.dots / 'p').exists())

    def test_competing_active_and_archive_folders_refuse_without_merging(self):
        active = self.dots / 'p'
        active.mkdir()
        active_child = issue('Active child')
        (active / 'existing.md').write_bytes(active_child)
        archived = self.dots / 'archive/p'
        archived.mkdir()
        parent = issue('Parent', 'closed')
        child = issue('Child', 'closed')
        (archived / 'p.md').write_bytes(parent)
        (archived / 'c.md').write_bytes(child)

        result = self.run_dot('on', 'p')

        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b'Issue already exists', result.stderr)
        self.assertEqual((active / 'existing.md').read_bytes(), active_child)
        self.assertEqual((archived / 'p.md').read_bytes(), parent)
        self.assertEqual((archived / 'c.md').read_bytes(), child)

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
