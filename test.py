"""Synthetic read history and full-CLI sequence comparisons for dots."""
from pathlib import Path
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
import time

def put(root, name, content):
    p = root / '.dots' / name
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(content)


def issue(title, status='open', priority=2, date='2026-01-01T00:00:00Z',
          description='', blocks=(), extra=''):
    rows = ['---', 'title: ' + title, 'status: ' + status,
            'priority: ' + str(priority), 'created-at: ' + date]
    if blocks:
        rows += ['blocks:'] + ['  - ' + b for b in blocks]
    if extra:
        rows.append(extra)
    return '\n'.join(rows) + '\n---\n\n' + description + '\n'


def seed(root, kind):
    if kind == 'uninitialized':
        return
    (root / '.dots').mkdir(parents=True)
    if kind != 'missing-archive':
        (root / '.dots/archive').mkdir()
    if kind == 'empty':
        return
    put(root, 'alpha.md', issue('Alpha login', priority=1, blocks=['beta'],
                              description='Auth implementation'))
    put(root, 'beta.md', issue('Beta backend', 'active', 0))
    put(root, 'delta.md', issue('Closed root', 'done', 4,
                              extra='closed-at: 2026-02-03T00:00:00Z\nclose-reason: Merged auth patch'))
    put(root, 'epsilon.md', issue('Ready with done dependency', priority=3, blocks=['delta']))
    put(root, 'gamma.md', issue('Ready with missing dependency', priority=2, blocks=['missing']))
    put(root, 'project/project.md', issue('Project parent', priority=5))
    put(root, 'project/child.md', issue('Nested child', priority=2, date='2026-01-02T00:00:00Z'))
    put(root, 'project/deeper/leaf.md', issue('Deep leaf', priority=6))
    put(root, 'quote.md', issue('"Quotes: \\"hello\\" \\t café"', priority=7,
                              date='"\\"2026-01-05T00:00:00Z\\""',
                              description='  two lines\nsecond line  ',
                              extra='issue-type: feature\nassignee: alice\nunknown: ignored'))
    if kind != 'missing-archive':
        put(root, 'archive/old.md', issue('Archived AUTH task', 'closed', 0,
                                        extra='closed-at: 2026-02-04T00:00:00Z\nclose-reason: Old fix'))
        put(root, 'archive/tree/tree.md', issue('Archive parent', 'closed', 2))
        put(root, 'archive/tree/sub.md', issue('Archive child', 'done', 3))
    put(root, 'defaults.md', '---\ntitle: Defaults\ncreated-at: 2026-01-03T00:00:00Z\n---\n')
    put(root, 'config', 'prefix: bench\n')
    if kind == 'malformed':
        put(root, 'bad.md', 'not frontmatter\n')
        put(root, 'badstatus.md', issue('Bad status', 'mystery'))
        put(root, 'badpriority.md', issue('Bad priority', priority='banana'))
        put(root, 'badblock.md', issue('Bad dependency', blocks=['../outside']))
        put(root, 'missingtitle.md', '---\ncreated-at: 2026-01-01\n---\n')
    if kind == 'ambiguous':
        put(root, 'alphabet.md', issue('Another alpha'))
    if kind == 'symlinks':
        (root / '.dots/link.md').symlink_to(root / '.dots/alpha.md')
        (root / '.dots/linkdir').symlink_to(root / '.dots/project', target_is_directory=True)
    if kind == 'scalar':
        put(root, 'scalar.md', issue('"A\\nB\\rC\\tD\\\\E\\qF"', priority='"-8"',
                                   extra='closed-at: "\\"2026-03-01\\""\nclose-reason: "Why: \\"yes\\""'))
    if kind == 'unterminated-timestamp':
        put(root, 'unterminated.md', issue('Literal unterminated timestamp', date='"2026-01-01'))
    if kind == 'nested-archive':
        put(root, 'project/archive/hidden.md', issue('Hidden nested archive'))
    if kind == 'priority-underscore':
        put(root, 'number.md', issue('Underscore priority', priority='0_2'))
    if kind == 'priority-leading-zero':
        put(root, 'number.md', issue('Long leading zeros', priority='0'*80+'2'))
    if kind == 'priority-underscore-run':
        put(root, 'number.md', issue('Repeated underscores', priority='0__2'))
    if kind == 'closing-crlf':
        put(root, 'delimiter.md', issue('Closing CRLF', description='Body').replace('\n---\n', '\n---\r\n'))
    if kind == 'closing-tail':
        put(root, 'delimiter.md', issue('Closing prefix', description='Body').replace('\n---\n', '\n---tail\n'))


CASES = [
    ('list-text', ['ls']), ('list-alias', ['list']),
    ('list-json', ['ls', '--json']), ('list-open', ['ls', '--status', 'open', '--json']),
    ('list-active', ['ls', '--status', 'active']),
    ('list-done', ['ls', '--status', 'done', '--json']),
    ('list-closed-alias', ['ls', '--status', 'closed', '--json']),
    ('ready-text', ['ready']), ('ready-json', ['ready', '--json']),
    ('default-ready-json', []), ('show-root', ['show', 'alpha']),
    ('show-prefix', ['show', 'bet']), ('show-nested', ['show', 'chi']),
    ('show-deep', ['show', 'leaf']), ('show-archived', ['show', 'old']),
    ('show-archive-nested', ['show', 'tree']), ('show-quoted', ['show', 'quote']),
    ('show-defaults', ['show', 'defaults']), ('show-closed', ['show', 'delta']),
    ('find-title-and-body', ['find', 'AUTH']), ('find-description', ['find', 'IMPLEMENTATION']),
    ('find-reason', ['find', 'patch']), ('find-created', ['find', '2026-01-05']),
    ('find-closed', ['find', '2026-02-04']), ('find-empty', ['find', '']),
    ('find-none', ['find', 'no-match-in-fixture']),
    ('find-help', ['find', '--help']), ('find-no-query', ['find']),
    ('show-missing', ['show', 'absent']), ('show-no-id', ['show']),
    ('invalid-status', ['ls', '--status', 'mystery']),
    ('missing-status-value', ['ls', '--status']),
    ('help', ['--help']), ('unsupported-command', ['add', 'Should not write']),
    ('empty-list', ['ls', '--json'], 'empty'), ('empty-ready', ['ready', '--json'], 'empty'),
    ('malformed-list-skips', ['ls', '--json'], 'malformed'),
    ('malformed-ready-skips', ['ready', '--json'], 'malformed'),
    ('malformed-show', ['show', 'bad'], 'malformed'),
    ('malformed-status-show', ['show', 'badstatus'], 'malformed'),
    ('malformed-priority-show', ['show', 'badpriority'], 'malformed'),
    ('malformed-block-show', ['show', 'badblock'], 'malformed'),
    ('ambiguous-prefix', ['show', 'alph'], 'ambiguous'),
    ('symlink-list-skips', ['ls', '--json'], 'symlinks'),
    ('symlink-show-skips', ['show', 'link'], 'symlinks'),
    ('quoted-scalar-show', ['show', 'scalar'], 'scalar'),
    ('quoted-scalar-json', ['ls', '--json'], 'scalar'),
    ('uninitialized-list', ['ls', '--json'], 'uninitialized'),
    ('missing-archive-created', ['ls', '--json'], 'missing-archive'),
    ('unterminated-timestamp', ['ls', '--json'], 'unterminated-timestamp'),
    ('nested-archive-list', ['ls', '--json'], 'nested-archive'),
    ('nested-archive-find', ['find', 'Hidden'], 'nested-archive'),
    ('ready-ignores-status', ['ready', '--status', 'mystery', '--json']),
    ('find-trailing-help', ['find', 'Auth', '--help']),
    ('priority-underscore', ['show', 'number'], 'priority-underscore'),
    ('priority-leading-zero', ['show', 'number'], 'priority-leading-zero'),
    ('priority-underscore-run', ['show', 'number'], 'priority-underscore-run'),
    ('closing-crlf', ['show', 'delimiter'], 'closing-crlf'),
    ('closing-tail', ['show', 'delimiter'], 'closing-tail'),
]


def snapshot(root):
    return {str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest()
            for p in root.rglob('*') if p.is_file() and not p.is_symlink()}


def canonical_stdout(argv, data):
    if argv and argv[0] == 'find' and len(argv) > 1 and argv[1] not in ('--help', '-h'):
        # Upstream search retains unspecified filesystem enumeration order within
        # the open and closed partitions. Preserve and validate that partition.
        lines = data.splitlines()
        is_closed = lambda line: b'] x ' in line
        closed_seen = False
        for line in lines:
            if is_closed(line):
                closed_seen = True
            elif closed_seen:
                raise AssertionError('find printed an open entry after a closed entry')
        return sorted(lines)
    return data


def main():
    binaries = [str(Path(s).resolve()) for s in sys.argv[1:]]
    if len(binaries) != 2:
        raise SystemExit('usage: compare-dots.py ZIG HABU')
    run = Path(tempfile.mkdtemp(prefix='parity-'))
    results = []
    env = dict(os.environ, NO_COLOR='1')
    for row in CASES:
        name, argv = row[:2]
        root = run / name
        root.mkdir()
        kind = row[2] if len(row) > 2 else 'normal'
        observed = []
        errors = []
        for idx, binary in enumerate(binaries):
            cwd = root / str(idx)
            cwd.mkdir()
            seed(cwd, kind)
            before = snapshot(cwd)
            try:
                p = subprocess.run([binary, *argv], cwd=cwd, env=env,
                                   capture_output=True, timeout=5)
                observed.append({'exit':p.returncode, 'stdout':p.stdout.decode(errors='replace'),
                                 'stderr':p.stderr.decode(errors='replace')})
            except subprocess.TimeoutExpired:
                observed.append({'exit':-124,'stdout':'','stderr':'Harness timeout after 5 seconds'})
                errors.append('command timed out')
            if snapshot(cwd) != before:
                errors.append('fixture file changed')
            if kind in ('uninitialized','missing-archive') and not (cwd/'.dots/archive').is_dir():
                errors.append('Storage.open did not create .dots/archive')
        a, b = observed
        try:
            same = (a['exit'] == b['exit'] and a['stderr'] == b['stderr'] and
                    canonical_stdout(argv, a['stdout'].encode()) ==
                    canonical_stdout(argv, b['stdout'].encode()))
            if not same:
                errors.append('behavior differs')
            if name in ('ready-json', 'default-ready-json'):
                expected = ['gamma','child','defaults','epsilon','project','leaf','quote']
                for actual in observed:
                    ids = [i['id'] for i in json.loads(actual['stdout'])]
                    if ids != expected:
                        errors.append('ready result violates fixture expectation: ' + repr(ids))
            if name == 'list-json':
                for actual in observed:
                    ids = [i['id'] for i in json.loads(actual['stdout'])]
                    if 'delta' in ids or 'old' in ids or 'alpha' not in ids or 'child' not in ids:
                        errors.append('list visibility violates fixture expectation')
        except (AssertionError, ValueError, TypeError) as exc:
            errors.append(str(exc))
        results.append({'name':name,'argv':argv,'passed':not errors,'errors':errors,'outputs':observed})
        print(('PASS ' if not errors else 'FAIL ') + name, flush=True)
    report = {'binaries':binaries,'passed':sum(r['passed'] for r in results),
              'total':len(results),'cases':results}
    (run/'results.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps({'passed':report['passed'],'total':report['total'],'run_dir':str(run)}))
    raise SystemExit(0 if report['passed']==report['total'] else 1)


FULL_SEQUENCES = [
    ('cli-matrix', 'empty', [
        (['help'], None), (['-h'], None), (['--help', 'ignored'], None),
        (['--version', 'ignored'], None), (['-v', 'ignored'], None),
        (['hook'], None), (['find'], None), (['find', '-h'], None),
        (['tree', '-h'], None), (['ls', '--status'], None),
        (['ls', '--status', 'mystery'], None),
        (['list', '--json', '--unknown'], None),
        (['ready', '--json', '--unknown'], None),
        (['init', '--from-jsonl', 'absent.jsonl'], None),
        (['fix', 'ignored'], None), (['slugify', 'ignored'], None),
        (['purge', 'ignored'], None),
    ]),
    ('basic', 'empty', [
        (['init'], None),
        (['add', 'First task', '-d', 'Line one', '-p', '1'], 'A'),
        (['create', 'Second task', '-p', '8', '--json'], 'B'),
        (['ls', '--json'], None), (['ready'], None), (['show', '@A'], None),
        (['on', '@A'], None), (['update', '@B', '--status', 'active'], None),
        (['off', '@A', '-r', 'finished'], None), (['show', '@A'], None),
        (['ls', '--status', 'done', '--json'], None),
        (['on', '@A'], None), (['rm', '@B'], None), (['ls'], None),
    ]),
    ('hierarchy', 'empty', [
        (['add', 'Parent task'], 'P'), (['add', 'Blocker task'], 'B'),
        (['add', 'Child task', '-P', '@P', '-a', '@B'], 'C'),
        (['tree'], None), (['tree', '@P'], None), (['off', '@P'], None),
        (['off', '@C', '-r', 'child done'], None), (['off', '@B'], None),
        (['tree', '@P'], None), (['close', '@P', '--reason', 'all done'], None),
        (['show', '@P'], None), (['show', '@C'], None),
        (['rm', '@P'], None), (['ls', '--json'], None),
    ]),
    # Nested C and G keep their children in top-level folders named after them.
    # Zig's fix, and archiving P while C exists, strand those folders: not run.
    ('grandchild', 'empty', [
        (['init'], None), (['add', 'Parent task'], 'P'),
        (['add', 'Child task', '-P', '@P'], 'C'),
        (['add', 'Grandchild task', '-P', '@C'], 'G'),
        (['add', 'Leaf task', '-P', '@G'], 'L'),
        (['tree'], None), (['tree', '@C'], None), (['tree', '@G'], None),
        (['ready'], None), (['show', '@C'], None), (['ls', '--json'], None),
        (['off', '@C', '-r', 'early'], None), (['done', '@C'], None),
        (['close', '@C', '--reason', 'early'], None),
        (['update', '@C', '--status', 'done'], None),
        (['off', '@P'], None), (['off', '@G'], None),
        (['off', '@L', '-r', 'leaf done'], None), (['off', '@G'], None),
        (['tree', '@C'], None), (['update', '@C', '--status', 'done'], None),
        (['tree', '@P'], None), (['show', '@C'], None),
        (['on', '@C'], None), (['close', '@C', '--reason', 'child done'], None),
        (['on', '@C'], None), (['done', '@C', '-r', 'again'], None),
        (['on', '@L'], None), (['on', '@C'], None), (['off', '@C'], None),
        (['tree'], None), (['tree', '@G'], None), (['ready'], None),
        (['slugify'], None), (['rm', '@C'], None), (['tree'], None),
        (['ls', '--json'], None), (['show', '@G'], None), (['tree', '@G'], None),
        (['off', '@P'], None), (['on', '@G'], None), (['tree'], None),
        (['purge'], None), (['show', '@P'], None),
    ]),
    # add -P puts children of archived P and Q in the active .dots/<id>/.
    # Reopening P meets that folder as a competing destination, asserted in
    # regression_archive_test.py. Fix runs once P is gone: beside an archived
    # parent it would detach the children.
    ('archived-parent', 'empty', [
        (['init'], None), (['add', 'Parent task'], 'P'),
        (['add', 'Child task', '-P', '@P'], 'C'),
        (['off', '@C'], None), (['off', '@P'], None),
        (['add', 'Extra task', '-P', '@P'], 'X'),
        (['add', 'Waiting task', '-a', '@X'], 'W'),
        (['tree'], None), (['tree', '@P'], None), (['show', '@P'], None),
        (['ready'], None), (['ls'], None),
        (['off', '@P'], None), (['close', '@P', '--reason', 'early'], None),
        (['update', '@P', '--status', 'done'], None),
        (['on', '@X'], None), (['off', '@P'], None),
        (['off', '@X', '-r', 'extra done'], None),
        (['tree'], None), (['tree', '@P'], None), (['show', '@P'], None),
        (['ready'], None), (['ls'], None),
        (['off', '@P'], None), (['close', '@P', '--reason', 'all done'], None),
        (['update', '@P', '--status', 'done'], None), (['show', '@P'], None),
        (['on', '@X'], None), (['slugify'], None), (['rm', '@P'], None),
        (['ready'], None), (['fix'], None), (['tree'], None),
        (['rm', '@X'], None), (['ready'], None),
        (['add', 'Plain task'], 'Q'), (['off', '@Q'], None),
        (['add', 'Late task', '-P', '@Q'], 'Y'), (['off', '@Q'], None),
        (['on', '@Q'], None), (['tree'], None), (['off', '@Q'], None),
        (['off', '@Y'], None), (['off', '@Q'], None), (['purge'], None),
        (['ls', '--json'], None),
    ]),
    # Reopening Q puts its file beside the active .dots/<q>/ holding Y.
    # Removing Q deletes only that file: Y and W's dependency on it remain.
    ('reopened-parent', 'empty', [
        (['add', 'Plain task'], 'Q'), (['off', '@Q'], None),
        (['add', 'Late task', '-P', '@Q'], 'Y'), (['on', '@Q'], None),
        (['add', 'Waiting task', '-a', '@Y'], 'W'), (['rm', '@Q'], None),
    ]),
    ('aliases', 'empty', [
        (['Quick title'], 'Q'), (['it', '@Q'], None),
        (['done', '@Q', '-r', 'shipped'], None), (['delete', '@Q'], None),
        (['--version'], None), (['-v'], None), (['hook'], None),
    ]),
    ('option-matrix', 'empty', [
        (['add', 'Priority high', '-p', '99', '-d', 'Some body', '--json'], 'A'),
        (['create', 'Priority low', '-p', '-100'], 'B'),
        (['add', 'Empty detail', '-d', '', '-p', '+4', '--ignored'], 'C'),
        (['ls', '--status', 'open', '--json'], None),
        (['off', '@A', '@B', '-r', 'batch'], None),
        (['show', '@A'], None), (['show', '@B'], None),
        (['on', '@A', '@B'], None),
        (['update', '@C', '--status', 'done'], None),
        (['close', '@C', '--reason', ''], None),
        (['rm', '@A', '@B'], None),
        (['ls', '--status', 'closed', '--json'], None),
    ]),
    ('invalid', 'empty', [
        (['add'], None), (['add', '-p', 'bogus', 'Title'], None),
        (['add', 'Title', '-P', 'absent'], None),
        (['add', 'Title', '-a', 'absent'], None),
        (['add', 'Title', '-P', 'same', '-a', 'same'], None),
        (['on'], None), (['off'], None), (['rm'], None),
        (['update'], None), (['close'], None),
        (['tree', 'too', 'many'], None), (['tree', '--help'], None),
        (['update', 'absent', '--status', 'mystery'], None),
    ]),
    ('repair', 'orphan', [
        (['ls'], None), (['fix'], None), (['ls'], None),
        (['fix'], None), (['show', 'child'], None),
    ]),
    ('purge', 'archive', [
        (['ls', '--status', 'done', '--json'], None),
        (['purge'], None), (['find', 'Old'], None),
        (['purge', 'ignored'], None),
    ]),
    ('slugify', 'slugify', [
        (['slugify'], None), (['ls', '--json'], None),
        (['show', 'bench-normal-title'], None),
    ]),
    ('jsonl', 'jsonl', [
        (['init', '--from-jsonl', 'import.jsonl'], None),
        (['ls', '--json'], None), (['find', 'Imported'], None),
        (['show', 'import-a'], None),
    ]),
    ('capacity', 'capacity', [
        (['ls', '--json'], None), (['show', 'item-299'], None),
        (['ready', '--json'], None),
    ]),
    ('ties', 'ties', [(['ls', '--json'], None)]),
    ('tree-shapes', 'tree-shapes', [
        (['tree'], None), (['tree', 'lead'], None), (['tree', 'kid'], None),
        (['tree', 'shut'], None), (['tree', 'broken'], None),
        (['tree', 'twin'], None), (['tree', 'waif'], None),
    ]),
]


def seed_full(root, kind):
    if kind == 'empty':
        return
    (root / '.dots' / 'archive').mkdir(parents=True)
    if kind == 'orphan':
        put(root, 'orphan/child.md', issue('Orphan child'))
    elif kind == 'archive':
        put(root, 'archive/old.md', issue('Old archived', 'closed'))
        put(root, 'live.md', issue('Live task'))
    elif kind == 'slugify':
        put(root, 'config', 'prefix=bench\n')
        put(root, 'legacy-12345678.md', issue('Normal title'))
        put(root, 'dependent-87654321.md', issue('Dependent', priority=3,
                                               blocks=['legacy-12345678']))
    elif kind == 'jsonl':
        rows = [
            {'id':'import-a','title':'Imported root','status':'open','priority':2,
             'issue_type':'task','created_at':'2026-01-01T00:00:00Z'},
            {'id':'import-b','title':'Imported done','status':'done','priority':1,
             'issue_type':'task','created_at':'2026-01-02T00:00:00Z',
             'dependencies':[{'depends_on_id':'import-a','type':'blocks'}]},
        ]
        (root / 'import.jsonl').write_text(''.join(json.dumps(x)+'\n' for x in rows))
    elif kind == 'capacity':
        for i in range(300):
            created = f'2026-01-01T{i // 3600:02}:{i // 60 % 60:02}:{i % 60:02}Z'
            put(root, f'item-{i:03}.md', issue(f'Item {i}', priority=i % 10, date=created,
                                           description='x' * 70000 if i == 299 else ''))
    elif kind == 'ties':
        # Equal priority and created-at: listing keeps load order, as the
        # reference's stable std.mem.sort does.
        for name in 'bdac':
            put(root, f'tie-{name}.md', issue('Tie ' + name))
        put(root, 'first.md', issue('First', priority=1))
    elif kind == 'tree-shapes':
        # Children in ORDER, closed and malformed children, a deep leaf whose
        # parent file is missing, two roots sharing ID twin and so one child
        # list, and roots whose parent file is missing or malformed.
        put(root, 'lead/lead.md', issue('Lead parent', priority=1))
        put(root, 'lead/kid.md', issue('Open kid', priority=3))
        put(root, 'lead/shut.md', issue('Closed kid', 'done', 0))
        put(root, 'lead/broken.md', 'not frontmatter\n')
        put(root, 'lead/deeper/leaf.md', issue('Deep leaf'))
        put(root, 'twin.md', issue('Twin file'))
        put(root, 'twin/twin.md', issue('Twin folder'))
        put(root, 'twin/pair.md', issue('Pair under twin'))
        put(root, 'stray/waif.md', issue('Waif without parent file'))
        put(root, 'bent/bent.md', 'not frontmatter\n')
        put(root, 'bent/sprout.md', issue('Sprout under malformed parent'))


GENERATED_TIME = re.compile(r'\b\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}(?P<offset>[+-]\d{2}:\d{2})\b')


def normalize_full(value, ids):
    for symbol, actual in sorted(ids.items(), key=lambda pair: len(pair[1]), reverse=True):
        if re.search(r'-[0-9a-f]{8}$', actual):
            value = value.replace(actual, actual[:-8] + '<random:' + symbol + '>')
    return GENERATED_TIME.sub(lambda m: '<generated-time>' + m['offset'], value)


def local_offset():
    """The local UTC offset as a generated timestamp prints it, as +03:00."""
    offset = time.strftime('%z')
    return offset[:3] + ':' + offset[3:]


def corrected_steps():
    """Steps where Habu reads the nested layout and the Zig reference does not.
    Each maps (sequence, step) to Zig's observed and Habu's (exit, stdout,
    stderr); the stores must still match. An archived child is a task, and a
    deep child whose parent file is missing is an orphan root."""
    child = 'hierarchy-child-task-<random:C>'
    stamp = '<generated-time>' + local_offset()
    lead = '[lead] ○ Lead parent\n  └─ [shut] ✓ Closed kid\n  └─ [kid] ○ Open kid\n'
    rest = ('[twin] ○ Twin file\n  └─ [pair] ○ Pair under twin\n'
            '[waif] ○ Waif without parent file\n'
            '[twin] ○ Twin folder\n  └─ [pair] ○ Pair under twin\n'
            '[sprout] ○ Sprout under malformed parent\n')
    return {
        ('hierarchy', 11): (
            (1, '', f'Issue not found: {child}\n'),
            (0, f'ID:       {child}\nTitle:    Child task\nStatus:   done\nPriority: 2\n'
                f'Created:  {stamp}\nClosed:   {stamp}\nReason:   child done\n', '')),
        ('tree-shapes', 0): (
            (0, lead + rest, ''),
            (0, lead + '[leaf] ○ Deep leaf\n' + rest, '')),
    }


def tree_snapshot(root, ids):
    result = {}
    if (root / '.dots').is_dir():
        result['.dots'] = ['directory']
    for path in sorted((root / '.dots').rglob('*')):
        rel = normalize_full(str(path.relative_to(root)), ids)
        if path.is_symlink():
            result[rel] = ['symlink', normalize_full(os.readlink(path), ids)]
        elif path.is_dir():
            result[rel] = ['directory']
        elif path.is_fifo():
            result[rel] = ['fifo']
        else:
            result[rel] = ['file', normalize_full(path.read_bytes().decode('utf-8', errors='replace'), ids)]
    return result


def full_main():
    if len(sys.argv) != 4:
        raise SystemExit('usage: test.py --full ZIG-FULL HABU')
    binaries = [str(Path(s).resolve()) for s in sys.argv[2:]]
    run = Path(tempfile.mkdtemp(prefix='full-parity-'))
    env = dict(os.environ, NO_COLOR='1')
    corrected = corrected_steps()
    report = []
    for name, kind, commands in FULL_SEQUENCES:
        roots = [run / label / name for label in ('zig', 'habu')]
        ids = [{}, {}]
        for root in roots:
            root.mkdir(parents=True)
            seed_full(root, kind)
        for step, (argv, save) in enumerate(commands):
            observations = []
            for side, (binary, root) in enumerate(zip(binaries, roots)):
                concrete = [re.sub(r'@([A-Z])', lambda m: ids[side].get(m[1], m[0]), arg)
                            for arg in argv]
                proc = subprocess.run([binary, *concrete], cwd=root, env=env,
                                      capture_output=True, timeout=10)
                out = proc.stdout.decode('utf-8', errors='replace')
                err = proc.stderr.decode('utf-8', errors='replace')
                if save and proc.returncode == 0 and out.strip():
                    token = json.loads(out)['id'] if '--json' in argv else out.strip().splitlines()[0]
                    ids[side][save] = token
                observations.append({
                    'exit': proc.returncode,
                    'stdout': normalize_full(out, ids[side]),
                    'stderr': normalize_full(err, ids[side]),
                    'tree': tree_snapshot(root, ids[side]),
                })
            if (argv and argv[0] == 'on' and
                    observations[0]['exit'] == observations[1]['exit'] == 0):
                # Historical Zig reopens the record but leaves its path in
                # archive. Rebase only the named, successfully reopened roots
                # in the disposable reference copy, then compare everything.
                for token in argv[1:]:
                    ref_id = ids[0].get(token[1:], token) if token.startswith('@') else token
                    new_id = ids[1].get(token[1:], token) if token.startswith('@') else token
                    for suffix in ('', '.md'):
                        old = roots[0] / '.dots/archive' / (ref_id + suffix)
                        new = roots[1] / '.dots' / (new_id + suffix)
                        target = roots[0] / '.dots' / (ref_id + suffix)
                        if old.exists() and new.exists() and not target.exists():
                            old.rename(target)
                observations[0]['tree'] = tree_snapshot(roots[0], ids[0])
            if (name, step) in corrected:
                equal = (observations[0]['tree'] == observations[1]['tree'] and
                         all((side['exit'], side['stdout'], side['stderr']) == want
                             for side, want in zip(observations, corrected[name, step])))
            else:
                equal = observations[0] == observations[1]
            report.append({'sequence':name, 'step':step, 'argv':argv,
                           'passed':equal, 'observations':observations})
            print(('PASS ' if equal else 'FAIL ') + name + ':' + str(step) + ' ' + repr(argv), flush=True)
    # Reopening an archived root intentionally differs from the historical Zig
    # reference. Exercise that behavior on the Habu side with a concrete
    # storage and metadata contract, leaving every other comparison exact.
    for parent in (False, True):
        root = run / ('reopen-parent' if parent else 'reopen-root')
        root.mkdir()
        old = 'archive/p/p.md' if parent else 'archive/old.md'
        ident = 'p' if parent else 'old'
        put(root, old, issue('Archived root', 'closed', extra=
                            'closed-at: 2026-02-04T00:00:00Z\nclose-reason: Old fix'))
        if parent:
            put(root, 'archive/p/c.md', issue('Archived child', 'closed'))
            child_before = (root / '.dots/archive/p/c.md').read_bytes()
        proc = subprocess.run([binaries[1], 'on', ident], cwd=root, env=env,
                              capture_output=True, timeout=10)
        task = root / '.dots' / (f'{ident}/{ident}.md' if parent else 'old.md')
        content = task.read_text() if task.is_file() else ''
        errors = []
        if proc.returncode != 0: errors.append('reopen command failed')
        if proc.stdout or proc.stderr: errors.append('unexpected reopen output')
        if not task.is_file(): errors.append('reopened task missing from active storage')
        if (root / '.dots' / old).exists(): errors.append('old archive task remains')
        if '\nstatus: active\n' not in content: errors.append('active status not persisted')
        if 'closed-at:' in content or 'close-reason:' in content:
            errors.append('closed metadata not cleared')
        if parent and ((root / '.dots/p/c.md').read_bytes()
                       if (root / '.dots/p/c.md').is_file() else None) != child_before:
            errors.append('archived child not preserved during parent reopen')
        report.append({'sequence':'reopen-contract', 'step':int(parent),
                       'argv':['on', ident], 'passed':not errors,
                       'errors':errors, 'observations':[{'habu_exit':proc.returncode,
                           'stdout':proc.stdout.decode(errors='replace'),
                           'stderr':proc.stderr.decode(errors='replace'),
                           'tree':tree_snapshot(root, {})}]})
        print(('PASS ' if not errors else 'FAIL ') + 'reopen-contract:' + str(int(parent)), flush=True)
    result = {'binaries':binaries, 'passed':sum(x['passed'] for x in report),
              'total':len(report), 'steps':report}
    (run / 'full-results.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({'passed':result['passed'], 'total':result['total'], 'run_dir':str(run)}))
    raise SystemExit(0 if result['passed'] == result['total'] else 1)


if __name__ == '__main__':
    if len(sys.argv) > 1 and sys.argv[1] == '--full':
        full_main()
    else:
        main()
