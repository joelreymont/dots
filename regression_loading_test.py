"""Differential regressions for mutation commands reading only needed issues."""
from pathlib import Path
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile

from test import issue, normalize_full, put

FILE_CAP = 1048576
BIG = b'x' * (FILE_CAP + 1)

# With random pinned, both binaries draw this suffix, so add's new id is known
# before the run and a case can place a task under it.
PINNED = '5eed1d00'
PINNED_ID = 'case-task-' + PINNED
PINNED_BYTES = ', '.join(f'0x{byte:02x}' for byte in bytes.fromhex(PINNED))
PIN_FILL = f'''#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <sys/types.h>
static const unsigned char pinned[] = {{{PINNED_BYTES}}};
static void pin_fill(void *buf, size_t len) {{
    for (size_t i = 0; i < len; i++) ((unsigned char *)buf)[i] = pinned[i % sizeof pinned];
}}
'''
# Both binaries draw from arc4random_buf on macOS; on Linux the reference uses
# getrandom where glibc predates arc4random_buf.
PIN_DARWIN = '''__attribute__((used)) static struct { const void *replacement; const void *replacee; }
    interpose __attribute__((section("__DATA,__interpose"))) =
    { (const void *)(uintptr_t)&pin_fill, (const void *)(uintptr_t)&arc4random_buf };
'''
PIN_LINUX = '''void arc4random_buf(void *buf, size_t len) { pin_fill(buf, len); }
ssize_t getrandom(void *buf, size_t len, unsigned int flags) {
    (void)flags;
    pin_fill(buf, len);
    return (ssize_t)len;
}
'''


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


def run_case(zig, habu, name, setup, commands, expect, env=None):
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
                                      env=dict(os.environ, NO_COLOR='1', **(env or {})),
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
            rc, out, err, _ = observed[1]
            if expect[step] == 'ok' and rc != 0:
                raise AssertionError(f'{name} step {step} {argv}: {err}')
            if expect[step] == 'pinned' and (rc != 0 or out != PINNED_ID + '\n'):
                raise AssertionError(f'{name} step {step} {argv}: expected {PINNED_ID}, '
                                     f'got {rc} {out!r} {err!r}')
            if expect[step] == 'exists' and (rc == 0 or err != 'Issue already exists\n'):
                raise AssertionError(f'{name} step {step} {argv}: expected a duplicate, '
                                     f'got {rc} {out!r} {err!r}')
            if expect[step] == 'too-long' and (rc == 0 or 'StreamTooLong' not in err):
                raise AssertionError(f'{name} step {step} {argv}: expected StreamTooLong, got {err}')
            if expect[step] == 'not-found' and (rc == 0 or err != 'Issue not found\n'):
                raise AssertionError(f'{name} step {step} {argv}: expected missing moved child, got {err}')
    print(f'PASS {name}', flush=True)


def pin_random(tmp):
    """Build the library that pins random in both binaries and answer the
    environment that loads it; None without a C compiler."""
    if sys.platform not in ('darwin', 'linux') or not shutil.which('cc'):
        return None
    source = Path(tmp) / 'pin.c'
    if sys.platform == 'darwin':
        library = Path(tmp) / 'pin.dylib'
        body, preload = PIN_DARWIN, 'DYLD_INSERT_LIBRARIES'
        command = ['cc', '-dynamiclib', '-o', str(library), str(source)]
    else:
        library = Path(tmp) / 'pin.so'
        body, preload = PIN_LINUX, 'LD_PRELOAD'
        command = ['cc', '-shared', '-fPIC', '-o', str(library), str(source)]
    source.write_text(PIN_FILL + body)
    subprocess.run(command, check=True, capture_output=True, timeout=30)
    return {preload: str(library)}


def taken_store(*names, link=False, folder=False):
    """A store with a task under the pinned id at each of names; link adds a
    symlinked directory holding one and folder an empty folder named after it."""
    def setup(root):
        put(root, 'config', 'prefix=case\n')
        (root / '.dots' / 'archive').mkdir()
        put(root, 'a.md', issue('A'))
        for name in names:
            put(root, name.format(id=PINNED_ID), issue('Taken'))
        if link:
            (root / 'outside').mkdir()
            (root / 'outside' / f'{PINNED_ID}.md').write_text(issue('Taken'))
            (root / '.dots' / 'linked').symlink_to('../outside')
        if folder:
            (root / '.dots' / PINNED_ID).mkdir()
    return setup


def nested(levels):
    return '/'.join(f'd{level}' for level in range(1, levels + 1)) + '/{id}.md'


def pinned_cases():
    """The new id is taken only where the reference looks: its file and folder
    at the top and in the archive, then active directories other than any named
    archive, ten levels down and never through a symlink."""
    cases = []
    for where, setup in (('top', taken_store('{id}.md')),
                         ('folder', taken_store('{id}/{id}.md')),
                         ('archive', taken_store('archive/{id}.md')),
                         ('archive-folder', taken_store('archive/{id}/{id}.md')),
                         ('active-child', taken_store('p/p.md', 'p/{id}.md')),
                         ('depth-10', taken_store(nested(10)))):
        cases.append((f'pinned-taken-{where}', setup, [(['add', 'Task'], None)], ['exists']))
    for where, setup in (('archived-child', taken_store('archive/p/p.md', 'archive/p/{id}.md')),
                         ('nested-archive', taken_store('x/archive/{id}.md')),
                         ('symlinked-dir', taken_store(link=True)),
                         ('depth-11', taken_store(nested(11))),
                         ('empty-folder', taken_store(folder=True))):
        for cmd in (['add', 'Task'], ['add', 'Task', '-P', 'a']):
            cases.append((f'pinned-free-{where}-{len(cmd)}', setup, [(cmd, None)], ['pinned']))
    return cases


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
    with tempfile.TemporaryDirectory(prefix='dots-loading-pin-') as tmp:
        pin = pin_random(tmp)
        if pin is None:
            print('SKIP pinned-id cases: no C compiler', flush=True)
        else:
            cases += [case + (pin,) for case in pinned_cases()]
        for case in cases:
            run_case(zig, habu, *case)
    print(f'{len(cases)} loading regressions passed')


if __name__ == '__main__':
    main()
