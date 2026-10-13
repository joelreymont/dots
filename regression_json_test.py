#!/usr/bin/env python3
"""Focused Zig-compatible JSON regression cases on disposable stores."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile


BASE = {
    'id': 'a', 'title': 'A', 'status': 'open', 'priority': 1,
    'issue_type': 'task', 'created_at': '2026-01-01T00:00:00Z',
}


def command(binary, root, *args):
    return subprocess.run([binary, *args], cwd=root, capture_output=True, timeout=15)


def imported(binary, row):
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        (root / 'import.jsonl').write_text(json.dumps(row, ensure_ascii=True) + '\n')
        proc = command(binary, root, 'init', '--from-jsonl', 'import.jsonl')
        assert proc.returncode == 0, (row, proc.stderr)
        saved = (root / '.dots' / 'a.md').read_bytes()
        listed = command(binary, root, 'ls', '--json')
        assert listed.returncode == 0, listed.stderr
        return saved, json.loads(listed.stdout)[0]


def dependency_import(binary, dependency):
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        rows = [BASE, BASE | {
            'id': 'b', 'title': 'B', 'dependencies': [dependency],
        }]
        (root / 'import.jsonl').write_text(''.join(json.dumps(row) + '\n' for row in rows))
        proc = command(binary, root, 'init', '--from-jsonl', 'import.jsonl')
        files = {
            str(path.relative_to(root)): path.read_bytes()
            for path in (root / '.dots').rglob('*.md')
        }
        return proc, files


def cases(binary):
    saved, item = imported(binary, BASE | {'status': [], 'description': []})
    assert b'status: open\n' in saved
    assert item['status'] == 'open' and item['description'] is None

    saved, item = imported(binary, BASE | {
        'title': [65, 195, 169], 'description': [98, 111, 100, 121, 255],
    })
    assert b'title: A\xc3\xa9\n' in saved and b'body\xff\n' in saved
    assert item['title'] == 'Aé'
    assert item['description'] == [98, 111, 100, 121, 255]

    saved, item = imported(binary, BASE | {'title': [1.0, '65', 12, 255]})
    assert b'title: \x01A\x0c\xff\n' in saved
    assert item['title'] == [1, 65, 12, 255]

    saved, item = imported(binary, BASE | {
        'title': 'Aé', 'description': 'line "quoted" \\ slash 😀',
    })
    assert b'title: A\xc3\xa9\n' in saved
    assert item['title'] == 'Aé'
    assert item['description'] == 'line "quoted" \\ slash 😀'

    for value in (-1, 256, 1.5, True, {}, [1]):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'import.jsonl').write_text(json.dumps(BASE | {'title': [value]}) + '\n')
            proc = command(binary, root, 'init', '--from-jsonl', 'import.jsonl')
            assert proc.returncode != 0, value
            assert not (root / '.dots' / 'a.md').exists(), value

    for dependency in (
        {'depends_on_id': [97], 'type': 'blocks'},
        {'depends_on_id': 'a', 'type': [98, 108, 111, 99, 107, 115]},
        {'depends_on_id': [97.0], 'type': ['98', 108, 111, 99, 107, 115]},
    ):
        proc, files = dependency_import(binary, dependency)
        assert proc.returncode == 0, (dependency, proc.stderr)
        assert b'blocks:\n  - a\n' in files['.dots/b.md'], dependency

    proc, files = dependency_import(binary, {
        'depends_on_id': [97],
        'type': [112, 97, 114, 101, 110, 116, 45, 99, 104, 105, 108, 100],
    })
    assert proc.returncode == 0, proc.stderr
    assert '.dots/a/b.md' in files and '.dots/a/a.md' in files

    for dependency in (
        {'depends_on_id': [256], 'type': 'blocks'},
        {'depends_on_id': [-1], 'type': 'blocks'},
        {'depends_on_id': [97], 'type': [1.5]},
        {'depends_on_id': [97], 'type': [True]},
        {'depends_on_id': [97], 'type': [[98]]},
    ):
        proc, files = dependency_import(binary, dependency)
        assert proc.returncode != 0, dependency
        assert '.dots/b.md' not in files, dependency

    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        dots = root / '.dots'
        dots.mkdir()
        (dots / 'a.md').write_bytes(
            b'---\ntitle: A\nstatus: open\npriority: 1\n'
            b'created-at: 2026-01-01T00:00:00Z\n---\n\nbody\xff\n'
        )
        proc = command(binary, root, 'ls', '--json')
        assert proc.returncode == 0, proc.stderr
        assert json.loads(proc.stdout)[0]['description'] == [98, 111, 100, 121, 255]


if __name__ == '__main__':
    if len(sys.argv) != 2:
        raise SystemExit('usage: regression_json_test.py DOT_BINARY')
    cases(str(Path(sys.argv[1]).resolve()))
    print('JSON regressions passed')
