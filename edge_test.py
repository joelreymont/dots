#!/usr/bin/env python3
"""Synthetic full-CLI edge comparisons; never opens a real task store."""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

from test import issue, normalize_full, put, tree_snapshot


def seed(root, case):
    if case == 'newline-name':
        put(root, 'odd\nname.md', issue('Odd name'))
    elif case == 'large-directory':
        for i in range(630):
            put(root, f'item-{i:04}-' + 'x' * 104 + '.md',
                issue(f'Item {i}', date=f'2026-01-01T00:{i // 60:02}:{i % 60:02}Z'))
    elif case == 'large-json':
        for i in range(65):
            put(root, f'item-{i:03}.md',
                issue(f'Item {i}', description='x' * 70000,
                      date=f'2026-01-01T00:{i // 60:02}:{i % 60:02}Z'))
    elif case == 'config-preservation':
        put(root, 'config', 'mode=old\n')
    elif case == 'config-over-limit':
        put(root, 'config', 'x' * 65537)
    elif case == 'config-directory':
        (root / '.dots' / 'config').mkdir(parents=True)
    elif case == 'deep-directory':
        put(root, '/'.join(f'd{i}' for i in range(10)) + '/leaf.md', issue('Deep leaf'))
    elif case == 'orphan-newline':
        put(root, 'orphan/odd\nname.md', issue('Orphan newline child'))
    elif case == 'empty-close-reason':
        put(root, 'x.md', issue('X'))
    elif case == 'config-duplicates':
        put(root, 'config', 'mode=a\nmode=b\nprefix=hi\nother=c\n')
    elif case == 'config-duplicates-missing-prefix':
        put(root, 'config', 'mode=a\nmode=b\nother=c\n')
    elif case == 'jsonl-malformed-partial':
        (root / 'import.jsonl').write_text(
            json.dumps({'id': 'a', 'title': 'A', 'status': 'open',
                        'priority': 1, 'issue_type': 'task',
                        'created_at': '2026-01-01T00:00:00Z'}) + '\nnot json\n')
    elif case == 'jsonl-empty-reason':
        (root / 'import.jsonl').write_text(json.dumps({
            'id': 'closed', 'title': 'Closed', 'status': 'closed',
            'priority': 1, 'issue_type': 'task',
            'created_at': '2026-01-01T00:00:00Z', 'close_reason': '',
        }) + '\n')
    elif case == 'git-slugify':
        subprocess.run(['git', 'init', '-q'], cwd=root, check=True)
        put(root, 'config', 'prefix=bench\n')
        put(root, 'legacy-12345678.md', issue('Normal title'))
    elif case == 'git-invalid':
        (root / '.git').mkdir()
    elif case == 'field-alias':
        put(root, 'config', 'prefix=p\n')
        put(root, 'a.md', issue('A'))
    elif case == 'rm-blocked-pair':
        put(root, 'a.md', issue('A', blocks=['b']))
        put(root, 'b.md', issue('B'))
    elif case == 'close-malformed-child':
        put(root, 'p/p.md', issue('Parent'))
        put(root, 'p/bad.md', 'not frontmatter\n')
    elif case == 'slugify-archived-parent':
        put(root, 'config', 'prefix=p\n')
        put(root, 'archive/a-12345678/a-12345678.md', issue('Archived parent', 'closed'))
        put(root, 'archive/a-12345678/c-12345678.md', issue('Archived child', 'closed'))
    elif case == 'slugify-deep':
        put(root, 'config', 'prefix=p\n')
        put(root, 'a-12345678/a-12345678.md', issue('A parent'))
        put(root, 'a-12345678/a+a/b-12345678/b-12345678.md', issue('B parent'))
        put(root, 'a-12345678/a+a/b-12345678/x-12345678.md', issue('X leaf'))
    elif case == 'utf8-long-name':
        put(root, 'é' * 200 + '.md', issue('Wide filename'))
    elif case == 'utf8-long-dir':
        put(root, 'é' * 200 + '/leaf.md', issue('Wide directory'))
    elif case == 'purge-deep':
        put(root, 'archive/' + '/'.join('d' + str(i) for i in range(35)) + '/x.md', issue('Deep archived'))
    elif case == 'show-unrelated-large':
        put(root, 'a.md', issue('A'))
        put(root, 'z.md', 'x' * (1048576 + 1))
    elif case in ('show-depth-ten', 'show-depth-eleven'):
        depth = 10 if case == 'show-depth-ten' else 11
        put(root, '/'.join('d' + str(i) for i in range(depth)) + '/leaf.md', issue('Deep leaf'))
    elif case == 'show-odd-id':
        put(root, 'odd#id.md', issue('Odd ID'))
    elif case == 'empty-id-list':
        put(root, '.md', issue('Empty ID'))
    elif case == 'empty-prefix':
        put(root, 'a.md', issue('Only issue'))
    elif case in ('off-flags', 'multi-off-time'):
        put(root, 'a.md', issue('A'))
        put(root, 'b.md', issue('B'))
    elif case in ('close-flag-value', 'off-missing-id', 'empty-reason-clear'):
        put(root, 'a.md', issue('A', 'closed', extra='close-reason: Old'))
    elif case.startswith('jsonl-'):
        base = {'id': 'a', 'title': 'A', 'status': 'open', 'priority': 1,
                'issue_type': 'task', 'created_at': '2026-01-01T00:00:00Z'}
        if case == 'jsonl-priority-float':
            row = json.dumps(base).replace('"priority": 1', '"priority": 1.0')
        elif case == 'jsonl-priority-exponent':
            row = json.dumps(base).replace('"priority": 1', '"priority": 1e0')
        elif case == 'jsonl-priority-scaled':
            row = json.dumps(base).replace('"priority": 1', '"priority": 1.2e1')
        elif case == 'jsonl-priority-nonintegral':
            row = json.dumps(base).replace('"priority": 1', '"priority": 1.2e0')
        elif case == 'jsonl-priority-overflow':
            row = json.dumps(base).replace('"priority": 1', '"priority": 9223372036854775808.0')
        elif case == 'jsonl-priority-max':
            row = json.dumps(base).replace('"priority": 1', '"priority": 9223372036854775807.0')
        elif case == 'jsonl-priority-min':
            row = json.dumps(base).replace('"priority": 1', '"priority": -9223372036854775808.0')
        elif case == 'jsonl-priority-negative-exponent':
            row = json.dumps(base).replace('"priority": 1', '"priority": 120e-1')
        elif case == 'jsonl-priority-string':
            base['priority'] = '1'
            row = json.dumps(base)
        elif case == 'jsonl-priority-string-exponent':
            base['priority'] = '1e0'
            row = json.dumps(base)
        elif case == 'jsonl-duplicate-title':
            row = json.dumps(base).replace('"title": "A"', '"title": "A", "title": "B"')
        elif case in ('jsonl-duplicate-dependency-id', 'jsonl-duplicate-dependency-type'):
            base['dependencies'] = [{'depends_on_id': 'missing', 'type': 'blocks'}]
            row = json.dumps(base)
            if case == 'jsonl-duplicate-dependency-id':
                row = row.replace('"depends_on_id": "missing"',
                                  '"depends_on_id": "missing", "depends_on_id": "other"')
            else:
                row = row.replace('"type": "blocks"', '"type": "blocks", "type": "parent-child"')
        elif case == 'jsonl-optional-empty':
            base.update(assignee='', closed_at='', close_reason='')
            row = json.dumps(base)
        elif case == 'jsonl-empty-parent':
            base['dependencies'] = [{'depends_on_id': '', 'type': 'parent-child'}]
            row = json.dumps(base)
        elif case == 'jsonl-parent-file':
            put(root, 'p', 'ordinary file\n')
            base['dependencies'] = [{'depends_on_id': 'p', 'type': 'parent-child'}]
            row = json.dumps(base)
        elif case == 'jsonl-line-limit':
            row = ' ' * 1048576
        elif case == 'jsonl-stream-duplicates':
            row = json.dumps(base) + ' ' * (8192 - len(json.dumps(base)))
            row = (row + '\n') * 4096
        else:
            raise AssertionError(case)
        (root / 'import.jsonl').write_text(row + ('\n' if case != 'jsonl-stream-duplicates' else ''))
    elif case == 'tree-priority':
        put(root, 'p/p.md', issue('Parent'))
        put(root, 'p/late.md', issue('Late', priority=9))
        put(root, 'p/early.md', issue('Early', priority=0))
    elif case == 'tree-malformed':
        put(root, 'bad.md', 'not frontmatter\n')
    elif case == 'tree-deep-root':
        put(root, 'p/q/leaf.md', issue('Deep leaf'))
    elif case == 'yaml-title-tab':
        put(root, 'a.md', issue('A'))
        put(root, 'b.md', issue('B'))
        (root / '.dots' / 'a.md').write_text(issue('A').replace('title: A', 'title:\tX'))
    elif case == 'rewrite-mode':
        put(root, 'a.md', issue('A'))
        (root / '.dots' / 'a.md').chmod(0o600)
    elif case == 'config-symlink':
        put(root, 'a.md', issue('A'))
        (root / 'config-target').write_text('mode=untouched\n')
        (root / '.dots' / 'config').symlink_to('../config-target')
    elif case == 'oversized-issue':
        put(root, 'a.md', 'x' * (1048576 + 1))


def digest(value):
    return hashlib.sha256(value.encode()).hexdigest()


def run(binary, root, command, case):
    proc = subprocess.run([binary, *command], cwd=root, capture_output=True,
                          timeout=120 if case == 'jsonl-stream-duplicates' else 30,
                          env=dict(os.environ, NO_COLOR='1'))
    out = proc.stdout.decode('utf-8', errors='replace')
    err = proc.stderr.decode('utf-8', errors='replace')
    ids = {}
    if command[0] == 'add' and proc.returncode == 0:
        ids['A'] = out.strip()
    out = normalize_full(out, ids)
    err = normalize_full(err, ids)
    if case == 'slugify-deep':
        lines = out.splitlines(keepends=True)
        out = ''.join(sorted(lines[:-1]) + lines[-1:])
    tree = tree_snapshot(root, ids)
    config_unique = None
    if case == 'config-duplicates-missing-prefix':
        # Zig's hash map has unspecified file order. Compare persisted key/value
        # meaning while separately requiring the duplicate to be collapsed.
        lines = (root / '.dots' / 'config').read_text().splitlines()
        keys = [line.partition('=')[0] for line in lines]
        config_unique = len(keys) == len(set(keys))
        config_values = dict(line.partition('=')[::2] for line in lines)
        tree['.dots/config'][1] = '\n'.join(sorted(lines)) + '\n'
    result = {
        'rc': proc.returncode, 'stdout_bytes': len(out.encode()),
        'stdout_sha256': digest(out), 'stdout_start': out[:180],
        'stderr': err, 'tree_sha256': digest(json.dumps(tree, sort_keys=True)),
        'tree_entries': len(tree),
    }
    if case in ('config-directory', 'config-over-limit') or case.startswith('jsonl-'):
        result['staged'] = sorted(p.name for p in (root / '.dots').rglob('*')
                                  if '.tmp-' in p.name)
    if case.startswith('jsonl-'):
        result['issue_a'] = tree.get('.dots/a.md')
    if case == 'git-slugify':
        index = subprocess.run(['git', 'ls-files', '--stage', '.dots'], cwd=root,
                               capture_output=True, text=True, check=True)
        result['git_index'] = index.stdout
    if case == 'multi-off-time':
        times = []
        for name in ('a', 'b'):
            content = (root / '.dots' / 'archive' / (name + '.md')).read_text()
            times.append(re.search(r'^closed-at: (.*)$', content, re.M).group(1))
        result['same_closed_at'] = len(set(times)) == 1
    if case == 'rewrite-mode':
        result['mode'] = oct((root / '.dots' / 'archive' / 'a.md').stat().st_mode & 0o777)
    if case == 'config-symlink':
        result['target_content'] = (root / 'config-target').read_text()
        result['config_replaced'] = not (root / '.dots' / 'config').is_symlink()
    if config_unique is not None:
        result['config_unique'] = config_unique
        result['config_values'] = config_values
    return result


def corrected_slugify_case(case, roots, observed):
    # The Zig reference cannot rename archived children and flattens nested
    # parent folders. Keep those outcomes visible while requiring the corrected
    # Habu tree, complete progress, and preserved task contents.
    zig, habu = observed
    zig_root, habu_root = roots
    def files(root):
        return {str(path.relative_to(root / '.dots')): path.read_text()
                for path in (root / '.dots').rglob('*.md')}
    zig_files, habu_files = files(zig_root), files(habu_root)
    if case == 'slugify-archived-parent':
        expected_zig = {'archive/a-12345678/a-12345678.md',
                        'archive/a-12345678/c-12345678.md'}
        expected_habu = {
            'archive/p-archived-parent-12345678/p-archived-parent-12345678.md':
                ('Archived parent', 'closed'),
            'archive/p-archived-parent-12345678/p-archived-child-12345678.md':
                ('Archived child', 'closed'),
        }
        progress = {'c-12345678 -> p-archived-child-12345678',
                    'a-12345678 -> p-archived-parent-12345678'}
        reference_ok = (zig['rc'] == 1 and zig['stdout_start'] == '' and
                        zig['stderr'] == 'Issue not found\n' and
                        set(zig_files) == expected_zig)
    else:
        expected_zig = {'p-a-parent-12345678/p-a-parent-12345678.md',
                        'p-a-parent-12345678/p-b-parent-12345678.md',
                        'p-a-parent-12345678/p-x-leaf-12345678.md'}
        expected_habu = {
            'p-a-parent-12345678/p-a-parent-12345678.md': ('A parent', 'open'),
            'p-a-parent-12345678/a+a/p-b-parent-12345678/p-b-parent-12345678.md':
                ('B parent', 'open'),
            'p-a-parent-12345678/a+a/p-b-parent-12345678/p-x-leaf-12345678.md':
                ('X leaf', 'open'),
        }
        progress = {'a-12345678 -> p-a-parent-12345678',
                    'b-12345678 -> p-b-parent-12345678',
                    'x-12345678 -> p-x-leaf-12345678'}
        reference_ok = (zig['rc'] == 0 and zig['stderr'] == '' and
                        set(zig_files) == expected_zig)
    lines = habu['stdout_start'].splitlines()
    corrected_ok = (habu['rc'] == 0 and habu['stderr'] == '' and
                    len(lines) == len(progress) + 1 and
                    set(lines[:-1]) == progress and
                    lines[-1] == f'Slugified {len(progress)} issue(s)' and
                    set(habu_files) == set(expected_habu))
    if not corrected_ok:
        return False
    for path, (title, status) in expected_habu.items():
        content = habu_files[path]
        if f'title: {title}\n' not in content or f'status: {status}\n' not in content:
            return False
    return reference_ok


def main():
    if len(sys.argv) != 3:
        raise SystemExit('usage: edge_test.py ZIG-FULL HABU')
    binaries = [str(Path(arg).resolve()) for arg in sys.argv[1:]]
    folder = Path(tempfile.mkdtemp(prefix='full-edge-'))
    cases = [
        ('newline-name', ['ls', '--json']),
        ('large-directory', ['ls', '--json']),
        ('large-json', ['ls', '--json']),
        ('config-preservation', ['add', 'New task']),
        ('config-over-limit', ['add', 'X']),
        ('config-directory', ['add', 'X']),
        ('deep-directory', ['ls', '--json']),
        ('orphan-newline', ['fix']),
        ('empty-close-reason', ['off', 'x', '-r', '']),
        ('config-duplicates', ['add', 'X']),
        ('config-duplicates-missing-prefix', ['add', 'X']),
        ('jsonl-malformed-partial', ['init', '--from-jsonl', 'import.jsonl']),
        ('jsonl-empty-reason', ['init', '--from-jsonl', 'import.jsonl']),
        ('git-slugify', ['slugify']),
        ('git-invalid', ['init']),
        ('field-alias', ['add', 'Child', '-P', 'a', '-d', 'x' * 44]),
        ('rm-blocked-pair', ['rm', 'a', 'b']),
        ('close-malformed-child', ['close', 'p']),
        ('slugify-archived-parent', ['slugify']),
        ('slugify-deep', ['slugify']),
        ('utf8-long-name', ['ls', '--json']),
        ('utf8-long-dir', ['ls', '--json']),
        ('utf8-long-add', ['add', 'é' * 200]),
        ('purge-deep', ['purge']),
        ('show-unrelated-large', ['show', 'a']),
        ('show-depth-ten', ['show', 'leaf']),
        ('show-depth-eleven', ['show', 'leaf']),
        ('show-odd-id', ['show', 'odd#id']),
        ('empty-id-list', ['ls', '--json']),
        ('empty-prefix', ['add', 'Child', '-P', '']),
        ('off-flags', ['off', 'a', '-r', '-r', 'b']),
        ('close-flag-value', ['close', 'a', '--reason', '--reason', 'wow']),
        ('off-missing-id', ['off', '-r', 'missing']),
        ('multi-off-time', ['off', 'a', 'b']),
        ('jsonl-priority-float', ['init', '--from-jsonl', 'import.jsonl']),
        ('jsonl-priority-exponent', ['init', '--from-jsonl', 'import.jsonl']),
        ('jsonl-priority-scaled', ['init', '--from-jsonl', 'import.jsonl']),
        ('jsonl-priority-nonintegral', ['init', '--from-jsonl', 'import.jsonl']),
        ('jsonl-priority-overflow', ['init', '--from-jsonl', 'import.jsonl']),
        ('jsonl-priority-max', ['init', '--from-jsonl', 'import.jsonl']),
        ('jsonl-priority-min', ['init', '--from-jsonl', 'import.jsonl']),
        ('jsonl-priority-negative-exponent', ['init', '--from-jsonl', 'import.jsonl']),
        ('jsonl-priority-string', ['init', '--from-jsonl', 'import.jsonl']),
        ('jsonl-priority-string-exponent', ['init', '--from-jsonl', 'import.jsonl']),
        ('jsonl-duplicate-title', ['init', '--from-jsonl', 'import.jsonl']),
        ('jsonl-duplicate-dependency-id', ['init', '--from-jsonl', 'import.jsonl']),
        ('jsonl-duplicate-dependency-type', ['init', '--from-jsonl', 'import.jsonl']),
        ('jsonl-optional-empty', ['init', '--from-jsonl', 'import.jsonl']),
        ('jsonl-empty-parent', ['init', '--from-jsonl', 'import.jsonl']),
        ('jsonl-parent-file', ['init', '--from-jsonl', 'import.jsonl']),
        ('jsonl-line-limit', ['init', '--from-jsonl', 'import.jsonl']),
        ('jsonl-stream-duplicates', ['init', '--from-jsonl', 'import.jsonl']),
        ('tree-priority', ['tree', 'p']),
        ('tree-malformed', ['tree', 'bad']),
        ('tree-deep-root', ['tree']),
        ('yaml-title-tab', ['on', 'a']),
        ('empty-reason-clear', ['close', 'a', '--reason', '']),
        ('rewrite-mode', ['off', 'a']),
        ('config-symlink', ['add', 'Child']),
        ('oversized-issue', ['ls']),
    ]
    results = []
    for case, command in cases:
        observed = []
        roots = []
        for side, binary in enumerate(binaries):
            root = folder / str(side) / case / 'site'
            root.mkdir(parents=True)
            seed(root, case)
            roots.append(root)
            observed.append(run(binary, root, command, case))
        same = observed[0] == observed[1]
        if case in ('slugify-archived-parent', 'slugify-deep'):
            same = corrected_slugify_case(case, roots, observed)
        if case == 'close-malformed-child':
            # Failure must preserve the parent; Zig rewrites it as closed.
            same = all(side['rc'] == 1 and side['stdout_bytes'] == 0 and
                       side['stderr'] == 'Invalid issue frontmatter\n'
                       for side in observed)
            same = same and (roots[1] / '.dots/p/p.md').read_text() == issue('Parent')
            same = same and (roots[1] / '.dots/p/bad.md').read_text() == 'not frontmatter\n'
            same = same and not any((roots[1] / '.dots/archive').iterdir())
        if case == 'multi-off-time':
            same = same and all(side['same_closed_at'] for side in observed)
        if case == 'rewrite-mode':
            same = same and all(side['mode'] == '0o644' for side in observed)
        if case == 'config-symlink':
            same = same and all(side['target_content'] == 'mode=untouched\n'
                                and side['config_replaced'] for side in observed)
        if case == 'config-duplicates-missing-prefix':
            same = same and all(side['config_unique'] and
                                side['config_values'] == {'mode': 'b', 'other': 'c', 'prefix': 'site'}
                                for side in observed)
        expected_errors = {
            'show-depth-eleven': 'Issue not found: leaf\n',
            'config-over-limit': 'Unexpected internal error (code: StreamTooLong)\n',
            'config-directory': 'Unexpected internal error (code: IsDir)\n',
            'jsonl-priority-nonintegral': 'Invalid JSONL file\n',
            'jsonl-priority-overflow': 'Invalid JSONL file\n',
            'jsonl-duplicate-dependency-id': 'Invalid JSONL file\n',
            'jsonl-duplicate-dependency-type': 'Invalid JSONL file\n',
        }
        if case in expected_errors:
            same = same and all(side['rc'] == 1 and side['stderr'] == expected_errors[case]
                                for side in observed)
        expected_priorities = {
            'jsonl-priority-exponent': 1,
            'jsonl-priority-scaled': 12,
            'jsonl-priority-string-exponent': 1,
            'jsonl-priority-max': 9223372036854775807,
            'jsonl-priority-min': -9223372036854775808,
            'jsonl-priority-negative-exponent': 12,
        }
        if case in expected_priorities:
            same = same and all(side['rc'] == 0 and
                                side['stdout_start'] == 'Imported 1 issues from import.jsonl\n' and
                                side['issue_a'] is not None and
                                f"priority: {expected_priorities[case]}\n" in side['issue_a'][1]
                                for side in observed)
        if case in expected_errors or case in expected_priorities:
            same = same and all(not side.get('staged') for side in observed)
        if case.startswith('jsonl-duplicate-dependency') or case in (
                'jsonl-priority-nonintegral', 'jsonl-priority-overflow'):
            same = same and all(side['issue_a'] is None for side in observed)
        print(('PASS ' if same else 'FAIL ') + case, flush=True)
        results.append({'case': case, 'command': command, 'passed': same,
                        'observations': observed})
    report = {'binaries': binaries, 'passed': sum(r['passed'] for r in results),
              'total': len(results), 'cases': results}
    (folder / 'results.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({'passed': report['passed'], 'total': report['total'],
                      'run_dir': str(folder)}))
    raise SystemExit(0 if report['passed'] == report['total'] else 1)


if __name__ == '__main__':
    main()
