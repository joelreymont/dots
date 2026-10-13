"""Differential regressions for mutation commands reading only needed issues."""
from pathlib import Path
import hashlib
import json
import os
import subprocess
import sys
import tempfile

from test import issue, normalize_full, put

FILE_CAP = 1048576
BIG = b'x' * (FILE_CAP + 1)


def seed(root, extra, place='active'):
    names = {name for name, _ in extra}
    if 'a/a.md' not in names:
        put(root, 'a.md', issue('A'))
    if 'b/b.md' not in names:
        put(root, 'b.md', issue('B'))
    for name, content in extra:
        if isinstance(content, bytes):
            path = root / '.dots' / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(content)
        else:
            put(root, name, content)
    if place:
        name = 'archive/z.md' if place == 'archive' else 'z.md'
        path = root / '.dots' / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(BIG)


def snapshot(root, ids):
    rows = {}
    for path in sorted((root / '.dots').rglob('*')):
        name = normalize_full(str(path.relative_to(root)), ids)
        if path.is_dir():
            rows[name] = ['directory']
        elif path.stat().st_size > FILE_CAP:
            rows[name] = ['oversized', hashlib.sha256(path.read_bytes()).hexdigest()]
        else:
            rows[name] = ['file', normalize_full(path.read_text(), ids)]
    return rows


def run_case(zig, habu, name, setup, commands, expect):
    with tempfile.TemporaryDirectory(prefix='dots-loading-') as tmp:
        roots = [Path(tmp) / side / 'store' for side in ('zig', 'habu')]
        for root in roots:
            root.mkdir(parents=True)
            setup(root)
        ids = [{}, {}]
        for step, (argv, saved) in enumerate(commands):
            observed = []
            for side, (binary, root) in enumerate(zip((zig, habu), roots)):
                proc = subprocess.run([binary, *argv], cwd=root,
                                      env=dict(os.environ, NO_COLOR='1'),
                                      capture_output=True, timeout=10)
                out = proc.stdout.decode(errors='replace')
                err = proc.stderr.decode(errors='replace')
                if saved and proc.returncode == 0:
                    ids[side][saved] = json.loads(out)['id'] if '--json' in argv else out.strip()
                observed.append((proc.returncode,
                                 normalize_full(out, ids[side]),
                                 normalize_full(err, ids[side]),
                                 snapshot(root, ids[side])))
            if observed[0] != observed[1]:
                raise AssertionError(f'{name} step {step} {argv}: Zig/Habu differ\n'
                                     f'Zig: {observed[0][:3]}\nHabu: {observed[1][:3]}')
            rc, _, err, _ = observed[1]
            if expect[step] == 'ok' and rc != 0:
                raise AssertionError(f'{name} step {step} {argv}: {err}')
            if expect[step] == 'too-long' and (rc == 0 or 'StreamTooLong' not in err):
                raise AssertionError(f'{name} step {step} {argv}: expected StreamTooLong, got {err}')
            if expect[step] == 'not-found' and (rc == 0 or err != 'Issue not found\n'):
                raise AssertionError(f'{name} step {step} {argv}: expected missing moved child, got {err}')
    print(f'PASS {name}', flush=True)


def main():
    if len(sys.argv) != 3:
        raise SystemExit('usage: regression_loading_test.py ZIG HABU')
    zig, habu = [str(Path(arg).resolve()) for arg in sys.argv[1:]]
    cases = []
    for place in ('active', 'archive'):
        for cmd in (['add', 'Task'], ['add', 'Child', '-P', 'a', '-a', 'b'],
                    ['on', 'a'], ['off', 'a'], ['update', 'a', '--status', 'active'],
                    ['close', 'a'], ['on', 'a', 'b'], ['off', 'a', 'b']):
            cases.append((f'{place}-{cmd[0]}-{len(cmd)}',
                          lambda root, p=place: seed(root, [], p),
                          [(cmd, 'created' if cmd[0] == 'add' else None)], ['ok']))
    for cmd in (['add', 'Child', '-P', 'z'], ['add', 'Dependent', '-a', 'z']):
        cases.append((f'oversized-add-reference-{cmd[2]}',
                      lambda root: seed(root, [], 'active'),
                      [(cmd, 'created')], ['ok']))
    for cmd in (['on', 'z'], ['off', 'z'], ['update', 'z', '--status', 'active'],
                ['close', 'z']):
        cases.append((f'oversized-target-{cmd[0]}',
                      lambda root: seed(root, [], 'active'), [(cmd, None)], ['too-long']))
    for cmd in (['off', 'a'], ['close', 'a'], ['update', 'a', '--status', 'closed']):
        cases.append((f'oversized-child-{cmd[0]}',
                      lambda root: seed(root, [('a/a.md', issue('A')),
                                               ('a/child.md', BIG)], None),
                      [(cmd, None)], ['too-long']))
    cases.append(('unrelated-child-on',
                  lambda root: seed(root, [('b/b.md', issue('B')),
                                           ('b/child.md', BIG)], None),
                  [(['on', 'a'], None)], ['ok']))
    cases.append(('whole-store-still-reads',
                  lambda root: seed(root, [], 'active'),
                  [(['ls', '--json'], None)], ['too-long']))
    cases.append(('status-after-parent-move',
                  lambda root: seed(root, [('a/a.md', issue('A')),
                                           ('a/child.md', issue('Child', 'closed'))], 'archive'),
                  [(['off', 'a', 'child'], None)], ['not-found']))
    cases.append(('status-child-before-parent',
                  lambda root: seed(root, [('a/a.md', issue('A')),
                                           ('a/child.md', issue('Child', 'closed'))], 'archive'),
                  [(['off', 'child', 'a'], None)], ['ok']))
    for folder in ('other/a', 'archive/other/a'):
        for state, content in (('open', issue('Unrelated', 'open')),
                               ('closed', issue('Unrelated', 'closed')),
                               ('oversized', BIG)):
            for cmd in (['off', 'a'], ['close', 'a'],
                        ['update', 'a', '--status', 'closed']):
                cases.append((f'unrelated-parent-name-{folder}-{state}-{cmd[0]}',
                              lambda root, f=folder, c=content: seed(
                                  root, [('a/a.md', issue('A')),
                                         (f + '/old.md', c)], None),
                              [(cmd, None)], ['ok']))
    for case in cases:
        run_case(zig, habu, *case)
    print(f'{len(cases)} loading regressions passed')


if __name__ == '__main__':
    main()
