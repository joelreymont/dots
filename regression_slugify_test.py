#!/usr/bin/env python3
"""Slugify regression for archived descendants and cross-store dependencies."""
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

BINARY = Path(sys.argv.pop(1)).resolve() if len(sys.argv) > 1 else Path('bin/dot').resolve()
DATE = '2026-01-01T00:00:00Z'


def issue(title, marker, *, status='open', blocks=()):
    lines = ['---', f'title: {title}', f'status: {status}', 'priority: 2',
             f'created-at: {DATE}']
    if blocks:
        lines += ['blocks:'] + [f'  - {block}' for block in blocks]
    return '\n'.join(lines) + f'\n---\n\n{marker}\n'


class SlugifyRegression(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix='dots-slugify-regression-')
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.dots = self.root / '.dots'
        self.dots.mkdir()
        (self.dots / 'archive').mkdir()
        (self.dots / 'config').write_text('prefix=case\n')

    def put(self, path, content):
        target = self.dots / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content)

    def run_dot(self, *args, env=None):
        return subprocess.run([str(BINARY), *(args or ('slugify',))], cwd=self.root,
                              capture_output=True, timeout=60,
                              env=dict(os.environ, NO_COLOR='1', **(env or {})))

    def tree(self):
        return {str(path.relative_to(self.dots)): path.read_bytes()
                for path in self.dots.rglob('*.md')}

    def test_archived_folders_children_and_all_dependency_rewrites(self):
        old = {
            'active': 'active-aaaabbbb',
            'parent': 'parent-bbbbcccc',
            'child': 'child-ccccdddd',
            'archived_parent': 'archived-ddddeeee',
            'archived_child': 'archived-child-eeeeffff',
            'archived_simple': 'archived-simple-ffff0000',
        }
        new = {
            'active': 'case-active-task-aaaabbbb',
            'parent': 'case-parent-task-bbbbcccc',
            'child': 'case-child-task-ccccdddd',
            'archived_parent': 'case-archived-parent-ddddeeee',
            'archived_child': 'case-archived-child-eeeeffff',
            'archived_simple': 'case-archived-simple-ffff0000',
        }
        self.put(f"{old['active']}.md", issue('Active task', 'marker-active',
                 blocks=(old['archived_child'],)))
        self.put(f"{old['parent']}/{old['parent']}.md",
                 issue('Parent task', 'marker-parent', blocks=(old['active'],)))
        self.put(f"{old['parent']}/{old['child']}.md",
                 issue('Child task', 'marker-child', blocks=(old['parent'],)))
        self.put(f"archive/{old['archived_parent']}/{old['archived_parent']}.md",
                 issue('Archived parent', 'marker-archived-parent', status='closed',
                       blocks=(old['child'],)))
        self.put(f"archive/{old['archived_parent']}/{old['archived_child']}.md",
                 issue('Archived child', 'marker-archived-child', status='closed',
                       blocks=(old['active'], old['parent'])))
        self.put(f"archive/{old['archived_simple']}.md",
                 issue('Archived simple', 'marker-archived-simple', status='closed',
                       blocks=(old['archived_parent'],)))
        before = self.tree()
        self.assertEqual(len(before), len(old))

        result = self.run_dot()
        self.assertEqual((result.returncode, result.stderr), (0, b''),
                         (result.stdout, result.stderr))
        lines = result.stdout.decode().splitlines()
        self.assertEqual(lines[-1], f'Slugified {len(old)} issue(s)')
        self.assertEqual(set(lines[:-1]),
                         {f'{old[key]} -> {new[key]}' for key in old})

        after = self.tree()
        expected_paths = {
            f"{new['active']}.md": ('marker-active', (new['archived_child'],)),
            f"{new['parent']}/{new['parent']}.md":
                ('marker-parent', (new['active'],)),
            f"{new['parent']}/{new['child']}.md":
                ('marker-child', (new['parent'],)),
            f"archive/{new['archived_parent']}/{new['archived_parent']}.md":
                ('marker-archived-parent', (new['child'],)),
            f"archive/{new['archived_parent']}/{new['archived_child']}.md":
                ('marker-archived-child', (new['active'], new['parent'])),
            f"archive/{new['archived_simple']}.md":
                ('marker-archived-simple', (new['archived_parent'],)),
        }
        self.assertEqual(set(after), set(expected_paths))
        for path, (marker, blocks) in expected_paths.items():
            content = after[path].decode()
            self.assertIn(marker, content)
            self.assertIn(f'created-at: "{DATE}"', content)
            self.assertEqual(tuple(re.findall(r'^  - (.+)$', content, re.M)), blocks)
            self.assertEqual('archive/' in path,
                             'status: closed\n' in content)
        for content in after.values():
            for old_id in old.values():
                self.assertNotIn(f'  - {old_id}\n'.encode(), content)

        second = self.run_dot()
        self.assertEqual((second.returncode, second.stdout, second.stderr),
                         (0, b'Slugified 0 issue(s)\n', b''))
        self.assertEqual(self.tree(), after)


    def test_archive_symlink_refused_before_any_write(self):
        external = self.root / 'external'
        external.mkdir()
        sentinel = external / 'old-12345678.md'
        sentinel.write_text(issue('External task', 'external-marker'))
        (self.dots / 'archive').rmdir()
        (self.dots / 'archive').symlink_to(external, target_is_directory=True)
        self.put('old-abcdef12.md', issue('Local task', 'local-marker'))
        before_local = (self.dots / 'old-abcdef12.md').read_bytes()
        before_external = sentinel.read_bytes()

        result = self.run_dot()
        self.assertEqual((result.returncode, result.stdout, result.stderr),
                         (1, b'', b'Unsafe archive symlink\n'))
        self.assertEqual((self.dots / 'old-abcdef12.md').read_bytes(), before_local)
        self.assertEqual(sentinel.read_bytes(), before_external)
        self.assertEqual(sorted(p.name for p in external.iterdir()), [sentinel.name])

    def test_unwritable_dependency_does_not_strand_reference(self):
        original = self.dots / 'old-12345678.md'
        dependent = self.dots / 'archive' / 'dependent-22222222.md'
        original.write_text(issue('Target', 'target-marker'))
        dependent.write_text(issue('Dependent', 'dependent-marker', status='closed',
                                   blocks=('old-12345678',)))
        before = self.tree()
        archive = self.dots / 'archive'
        archive.chmod(0o555)
        try:
            result = self.run_dot()
        finally:
            archive.chmod(0o755)
        self.assertEqual((result.returncode, result.stdout, result.stderr),
                         (1, b'', b'Permission denied\n'))
        self.assertEqual(self.tree(), before)
        self.assertFalse(list(self.dots.rglob('*.tmp-*')))

    def test_failed_commit_rename_rolls_back_every_file(self):
        if sys.platform not in ('darwin', 'linux') or not shutil.which('cc'):
            self.skipTest('rename interposition requires a C compiler')
        original = self.dots / 'old-12345678.md'
        dependent = self.dots / 'archive' / 'dependent-22222222.md'
        original.write_text(issue('Target', 'target-marker'))
        dependent.write_text(issue('Dependent', 'dependent-marker', status='closed',
                                   blocks=('old-12345678',)))
        before = self.tree()
        marker = self.root / 'intercepted'
        source = self.root / 'interpose.c'
        library = self.root / ('interpose.dylib' if sys.platform == 'darwin'
                               else 'interpose.so')
        header = '''#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
static int should_fail(const char *dst) {
    if (!strstr(dst, "case-target-12345678.md")) return 0;
    const char *path = getenv("DOTS_TEST_RENAME_MARKER");
    if (path) {
        int fd = open(path, O_CREAT | O_WRONLY | O_TRUNC, 0600);
        if (fd >= 0) {
            const char *state = access(".dots/old-12345678.md", F_OK) == -1
                ? "moved" : "present";
            write(fd, state, strlen(state));
            close(fd);
        }
    }
    errno = EACCES;
    return 1;
}
'''
        if sys.platform == 'darwin':
            body = '''#include <stdio.h>
#include <stdint.h>
static int fail_renamex(const char *src, const char *dst, unsigned int flags) {
    if (should_fail(dst)) return -1;
    return renamex_np(src, dst, flags);
}
__attribute__((used)) static struct { const void *replacement; const void *replacee; }
    interpose __attribute__((section("__DATA,__interpose"))) =
    { (const void *)(uintptr_t)&fail_renamex, (const void *)(uintptr_t)&renamex_np };
'''
            command = ['cc', '-dynamiclib', '-o', str(library), str(source)]
            preload = 'DYLD_INSERT_LIBRARIES'
        else:
            body = '''#define _GNU_SOURCE
#include <dlfcn.h>
int renameat2(int olddirfd, const char *src, int newdirfd,
              const char *dst, unsigned int flags) {
    if (should_fail(dst)) return -1;
    int (*next)(int, const char *, int, const char *, unsigned int) =
        dlsym(RTLD_NEXT, "renameat2");
    return next(olddirfd, src, newdirfd, dst, flags);
}
'''
            command = ['cc', '-shared', '-fPIC', '-o', str(library),
                       str(source), '-ldl']
            preload = 'LD_PRELOAD'
        source.write_text(header + body)
        subprocess.run(command, check=True, capture_output=True, timeout=30)

        result = self.run_dot(env={preload: str(library),
                                   'DOTS_TEST_RENAME_MARKER': str(marker)})
        self.assertEqual(marker.read_text(), 'moved', result.stderr)
        self.assertEqual((result.returncode, result.stdout, result.stderr),
                         (1, b'', b'Permission denied\n'))
        self.assertEqual(self.tree(), before)
        self.assertFalse(list(self.dots.rglob('*.tmp-*')))

    def test_occupied_destinations_never_overwritten(self):
        for kind in ('file', 'symlink', 'dangling-symlink', 'directory'):
            with self.subTest(kind=kind):
                source = self.dots / 'old-12345678.md'
                target = self.dots / 'case-target-12345678.md'
                source.write_text(issue('Target', 'source-marker'))
                external = self.root / 'external.txt'
                external.write_text('outside-marker')
                if kind == 'file':
                    target.write_text('occupied-file')
                elif kind == 'symlink':
                    target.symlink_to(external)
                elif kind == 'dangling-symlink':
                    target.symlink_to(self.root / 'missing.txt')
                else:
                    target.mkdir()
                    (target / 'sentinel').write_text('occupied-dir')
                before = source.read_bytes()
                result = self.run_dot()
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, b'Slugified 0 issue(s)\n')
                self.assertIn(b'Skipping old-12345678:', result.stderr)
                self.assertEqual(source.read_bytes(), before)
                self.assertEqual(external.read_text(), 'outside-marker')
                if kind == 'file':
                    self.assertEqual(target.read_text(), 'occupied-file')
                    target.unlink()
                elif kind.endswith('symlink'):
                    self.assertTrue(target.is_symlink())
                    target.unlink()
                else:
                    self.assertEqual((target / 'sentinel').read_text(), 'occupied-dir')
                    (target / 'sentinel').unlink()
                    target.rmdir()
                source.unlink()
                self.assertFalse(list(self.dots.rglob('*.tmp-*')))

    def test_duplicate_ids_keep_both_blockers(self):
        old = 'same-12345678'
        first = 'case-first-target-12345678'
        second = 'case-second-target-12345678'
        dependent = 'case-dependent-22222222'
        self.put(f'{old}.md', issue('First target', 'first-marker'))
        self.put(f'nested/{old}.md', issue('Second target', 'second-marker'))
        self.put('dependent-22222222.md', issue('Dependent', 'dependent-marker',
                                                blocks=(old,)))
        result = self.run_dot()
        self.assertEqual((result.returncode, result.stderr), (0, b''), result.stdout)
        blocks = re.findall(r'^  - (.+)$',
                            (self.dots / f'{dependent}.md').read_text(), re.M)
        self.assertEqual(set(blocks), {first, second})
        self.assertEqual(len(blocks), 2)
        self.assertNotIn(dependent.encode(), self.run_dot('ready').stdout)
        self.assertEqual(self.run_dot('off', first).returncode, 0)
        self.assertNotIn(dependent.encode(), self.run_dot('ready').stdout)
        self.assertEqual(self.run_dot('off', second).returncode, 0)
        self.assertIn(dependent.encode(), self.run_dot('ready').stdout)

    def test_duplicate_id_spanning_archive_keeps_both_references(self):
        old = 'same-12345678'
        active = 'case-active-target-12345678'
        archived = 'case-archived-target-12345678'
        dependent = 'case-dependent-22222222'
        self.put(f'{old}.md', issue('Active target', 'active-marker'))
        self.put(f'archive/{old}.md',
                 issue('Archived target', 'archived-marker', status='closed'))
        self.put('dependent-22222222.md', issue('Dependent', 'dependent-marker',
                                                blocks=(old,)))
        before = self.tree()

        result = self.run_dot()
        self.assertEqual((result.returncode, result.stderr), (0, b''), result.stdout)
        after = self.tree()
        self.assertEqual(len(after), len(before))
        self.assertIn(f'{active}.md', after)
        self.assertIn(f'archive/{archived}.md', after)
        self.assertIn(f'{dependent}.md', after)
        blocks = re.findall(r'^  - (.+)$', after[f'{dependent}.md'].decode(), re.M)
        self.assertEqual(set(blocks), {active, archived})
        self.assertEqual(len(blocks), 2)
        self.assertEqual(self.run_dot().stdout, b'Slugified 0 issue(s)\n')


if __name__ == '__main__':
    unittest.main()
