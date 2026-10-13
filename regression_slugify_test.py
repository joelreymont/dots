#!/usr/bin/env python3
"""Slugify regression for archived descendants and cross-store dependencies."""
import os
from pathlib import Path
import re
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

    def run_dot(self):
        return subprocess.run([str(BINARY), 'slugify'], cwd=self.root,
                              capture_output=True, timeout=60,
                              env=dict(os.environ, NO_COLOR='1'))

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


if __name__ == '__main__':
    unittest.main()
