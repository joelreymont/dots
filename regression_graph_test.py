#!/usr/bin/env python3
"""Graph parity regressions against the adapted Zig reference, in temporary stores."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

from test import issue, put, tree_snapshot


DATE = '2026-01-01T00:00:00Z'


def row(id, title, *, status='open', dependencies=()):
    return {
        'id': id, 'title': title, 'status': status, 'priority': 2,
        'issue_type': 'task', 'created_at': DATE,
        'dependencies': list(dependencies),
    }


def write_jsonl(root, name, rows):
    (root / name).write_text(''.join(json.dumps(item) + '\n' for item in rows))


def run(binary, root, args):
    proc = subprocess.run([binary, *args], cwd=root, capture_output=True,
                          timeout=30, env=dict(os.environ, NO_COLOR='1'))
    return proc.returncode, proc.stdout, proc.stderr, tree_snapshot(root, {})


def compare(name, binaries, setup, commands, check):
    with tempfile.TemporaryDirectory(prefix='dot-graph-') as tmp:
        results = []
        for side, binary in zip(('zig', 'habu'), binaries):
            root = Path(tmp) / side / 'site'
            root.mkdir(parents=True)
            setup(root)
            steps = [run(binary, root, args) for args in commands]
            results.append((root, steps))
        (zig_root, zig_steps), (habu_root, habu_steps) = results
        check(zig_root, zig_steps)
        check(habu_root, habu_steps)
        if zig_steps != habu_steps:
            for step, (zig, habu) in enumerate(zip(zig_steps, habu_steps), 1):
                if zig != habu:
                    raise AssertionError(f'{name}, step {step}:\nZig: {zig!r}\nHabu: {habu!r}')
        print(f'{name}: ok')


def tree_setup(root):
    put(root, 'outer/outer.md', issue('Outer'))
    put(root, 'outer/p.md', issue('P nested under Outer'))
    put(root, 'p/c.md', issue('Child should remain visible'))


def tree_check(root, steps):
    rc, out, err, _ = steps[-1]
    assert (rc, err) == (0, b''), (rc, err)
    assert b'[c] ' in out and b'Child should remain visible' in out, out


def newline_setup(root):
    put(root, 'a.md', issue('A'))
    put(root, 'b.md', issue('B'))
    write_jsonl(root, 'newline.jsonl', [
        row('c', 'C', dependencies=[
            {'depends_on_id': 'a\nb', 'type': 'blocks'},
            {'depends_on_id': '', 'type': 'blocks'},
            {'depends_on_id': 'a', 'type': 'blocks'},
            {'depends_on_id': 'a', 'type': 'blocks'},
        ]),
        row('c', 'Duplicate C', dependencies=[
            {'depends_on_id': 'a\nb', 'type': 'blocks'},
        ]),
    ])


def newline_check(root, steps):
    rc, out, err, tree = steps[-1]
    assert rc == 0 and out == b'Imported 1 issues from newline.jsonl\n', (rc, out)
    assert err == b'Warning: skipped 2 dependencies due to errors\n', err
    content = tree['.dots/c.md'][1]
    assert content.count('  - a\n') == 1 and '  - b\n' not in content, content


def archived_setup(root):
    write_jsonl(root, 'parent.jsonl', [row('p', 'P', status='closed')])
    write_jsonl(root, 'children.jsonl', [
        row('c', 'C', dependencies=[{'depends_on_id': 'p', 'type': 'parent-child'}]),
        row('b', 'B', dependencies=[{'depends_on_id': 'p', 'type': 'blocks'}]),
    ])


def archived_check(root, steps):
    assert '.dots/archive/p.md' in steps[0][3], steps[0][3]
    rc, out, err, tree = steps[-1]
    assert rc == 0 and b'Imported 2 issues' in out and err == b'', (rc, out, err)
    assert '  - p\n' in tree['.dots/b.md'][1], tree['.dots/b.md']
    assert '.dots/archive/p.md' in tree, tree


def nested_setup(root):
    write_jsonl(root, 'parent.jsonl', [
        row('q', 'Q'),
        row('p', 'P', dependencies=[{'depends_on_id': 'q', 'type': 'parent-child'}]),
    ])
    write_jsonl(root, 'children.jsonl', [
        row('c', 'C', dependencies=[{'depends_on_id': 'p', 'type': 'parent-child'}]),
        row('b', 'B', dependencies=[{'depends_on_id': 'p', 'type': 'blocks'}]),
    ])


def nested_check(root, steps):
    assert '.dots/q/p.md' in steps[0][3], steps[0][3]
    rc, out, err, tree = steps[-1]
    assert rc == 0 and b'Imported 2 issues' in out and err == b'', (rc, out, err)
    assert '  - p\n' in tree['.dots/b.md'][1], tree['.dots/b.md']
    assert '.dots/q/p.md' in tree, tree


def main():
    if len(sys.argv) != 3:
        raise SystemExit('usage: regression_graph_test.py ZIG-FULL HABU')
    binaries = tuple(str(Path(arg).resolve()) for arg in sys.argv[1:])
    compare('orphan with same ID elsewhere', binaries, tree_setup, [('tree',)], tree_check)
    compare('newline dependency ID', binaries, newline_setup,
            [('init', '--from-jsonl', 'newline.jsonl')], newline_check)
    compare('archived parent cache', binaries, archived_setup,
            [('init', '--from-jsonl', 'parent.jsonl'),
             ('init', '--from-jsonl', 'children.jsonl')], archived_check)
    compare('nested parent cache', binaries, nested_setup,
            [('init', '--from-jsonl', 'parent.jsonl'),
             ('init', '--from-jsonl', 'children.jsonl')], nested_check)


if __name__ == '__main__':
    main()
