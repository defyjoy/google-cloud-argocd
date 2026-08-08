#!/usr/bin/env python3
"""Enforce the no-comments-in-values-files convention (see CLAUDE.md).

    scripts/helm/values-comments.py --check          # exit 1 if any YAML comment remains
    scripts/helm/values-comments.py --fix [PATH...]  # strip them

Comments inside YAML block scalars (`key: |`) are string DATA, not YAML comments —
e.g. the HCL comments in helmcharts/vault's raft `config: |`. They are never touched.

--fix refuses to write any file whose parsed YAML would change, so a quoting edge case
cannot silently alter config. That guard is the whole point; do not remove it.
"""
from __future__ import annotations
import re
import sys
from pathlib import Path

import yaml

# This file lives in scripts/helm/, so the repo root is three levels up. Keep in step
# if it moves — a wrong root makes the rglob below match nothing and the check pass
# vacuously, which looks identical to "no comments found".
REPO = Path(__file__).resolve().parent.parent.parent
BLOCK_OPEN = re.compile(r':\s*[|>][+-]?\d*\s*$')


def _rel(p: Path) -> str:
    """Repo-relative path for display; tolerates paths passed in relative form."""
    try:
        return str(p.resolve().relative_to(REPO))
    except ValueError:
        return str(p)


def values_files(paths: list[str] | None = None) -> list[Path]:
    if paths:
        return [Path(p) for p in paths]
    out = []
    for p in (REPO / 'helmcharts').rglob('*.y*ml'):
        if '/charts/' in str(p):          # vendored subcharts are not ours
            continue
        if 'values' in p.name or p.parent.name == 'values':
            out.append(p)
    return sorted(out)


def _strip_inline(line: str) -> str:
    """Drop a trailing ' #...' comment, respecting quotes."""
    out, quote, i = [], None, 0
    while i < len(line):
        ch = line[i]
        if quote:
            out.append(ch)
            if ch == '\\' and i + 1 < len(line):
                out.append(line[i + 1])
                i += 2
                continue
            if ch == quote:
                quote = None
        elif ch in ('"', "'"):
            quote = ch
            out.append(ch)
        elif ch == '#' and (not out or out[-1] in (' ', '\t')):
            break
        else:
            out.append(ch)
        i += 1
    return ''.join(out).rstrip()


def scan(text: str):
    """Yield (lineno, line) for real YAML comments — whole-line *and* trailing inline —
    skipping block-scalar bodies, where '#' is string data."""
    block_indent = None
    for n, raw in enumerate(text.splitlines(), 1):
        stripped, indent = raw.strip(), len(raw) - len(raw.lstrip())
        if block_indent is not None:
            if stripped == '' or indent >= block_indent:
                continue
            block_indent = None
        if stripped.startswith('#'):
            yield n, raw
            continue
        if _strip_inline(raw) != raw.rstrip():        # trailing ' # ...' was dropped
            yield n, raw
        if BLOCK_OPEN.search(raw.rstrip()):
            block_indent = indent + 1


def strip_text(text: str) -> str:
    kept: list[tuple[str, bool]] = []
    block_indent = None
    for raw in text.splitlines():
        stripped, indent = raw.strip(), len(raw) - len(raw.lstrip())
        if block_indent is not None:
            if stripped == '' or indent >= block_indent:
                kept.append((raw, True))       # verbatim: string data
                continue
            block_indent = None
        if stripped.startswith('#'):
            continue
        line = _strip_inline(raw)
        if line.strip() == '' and stripped != '':
            continue                            # became comment-only
        kept.append((line, False))
        if BLOCK_OPEN.search(line):
            block_indent = indent + 1
    out, blank = [], False
    for line, verbatim in kept:
        if verbatim:
            blank = False
            out.append(line)
        elif line.strip() == '':
            if blank or not out:
                continue
            blank = True
            out.append('')
        else:
            blank = False
            out.append(line)
    while out and out[-1].strip() == '':
        out.pop()
    return '\n'.join(out) + '\n'


def main() -> int:
    args = sys.argv[1:]
    mode = '--fix' if '--fix' in args else '--check'
    paths = [a for a in args if not a.startswith('--')]
    files = values_files(paths)
    bad = 0

    for f in files:
        text = f.read_text(encoding='utf-8')
        hits = list(scan(text))
        if not hits:
            continue
        rel = _rel(f)
        if mode == '--check':
            bad += 1
            print(f'{rel}: {len(hits)} comment line(s) — move the rationale to the chart README')
            for n, line in hits[:3]:
                print(f'    {n}: {line.strip()[:88]}')
            continue

        new = strip_text(text)
        try:
            if list(yaml.safe_load_all(text)) != list(yaml.safe_load_all(new)):
                print(f'{rel}: REFUSED — parsed YAML would change, left untouched')
                bad += 1
                continue
        except yaml.YAMLError as exc:
            print(f'{rel}: REFUSED — parse error: {exc}')
            bad += 1
            continue
        f.write_text(new, encoding='utf-8')
        print(f'{rel}: stripped {len(hits)} line(s)')

    if mode == '--check':
        print('OK: no comments in any values file' if not bad
              else f'\n{bad} file(s) still carry comments. See CLAUDE.md → Helm chart conventions.')
    return 1 if bad else 0


if __name__ == '__main__':
    raise SystemExit(main())
