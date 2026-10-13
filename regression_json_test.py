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
