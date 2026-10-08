#!/usr/bin/env python3
"""Comment Rule compliance checker for UCIe simplified endpoint.

Rule:
  1. File header comment: 50-500 lines (including the blank-line tail).
  2. Revision history log present in the header.
  3. At least 5 comment lines directly above every always/always_comb/
     always_ff/always_latch and every assign.

Usage: python scripts/check_comment_rule.py
"""
import re
import glob
import sys


def header_len(lines):
    n = 0
    for line in lines:
        s = line.strip()
        if s.startswith('//'):
            n += 1
        elif s == '':
            if n > 0:
                n += 1
        else:
            break
    return n


def count_comments_above(lines, idx):
    """Count contiguous comment lines directly above idx (blank lines skipped)."""
    c = 0
    i = idx - 1
    while i >= 0:
        s = lines[i].strip()
        if s.startswith('//') or s.startswith('/*') or s.endswith('*/') or s.startswith('*'):
            c += 1
            i -= 1
        elif s == '':
            i -= 1
        else:
            break
    return c


def check_file(fp):
    with open(fp, 'r', encoding='utf-8', errors='ignore') as f:
        lines = f.readlines()
    issues = []

    hl = header_len(lines)
    if hl < 50:
        issues.append(f'header is {hl} lines (< 50)')
    elif hl > 500:
        issues.append(f'header is {hl} lines (> 500)')

    content = ''.join(lines)
    if not re.search(r'revision history', content, re.IGNORECASE):
        issues.append('no revision history section')

    for i, line in enumerate(lines):
        s = line.strip()
        if re.match(r'^(always|always_comb|always_ff|always_latch)\b', s):
            cnt = count_comments_above(lines, i)
            if cnt < 5:
                issues.append(f'line {i+1}: always has {cnt} comment lines (< 5)')
        elif re.match(r'^assign\b', s):
            cnt = count_comments_above(lines, i)
            if cnt < 5:
                issues.append(f'line {i+1}: assign has {cnt} comment lines (< 5)')
    return issues


def main():
    files = sorted(glob.glob('rtl/**/*.sv', recursive=True)) + \
            sorted(glob.glob('tb/**/*.sv', recursive=True))
    total = 0
    for fp in files:
        issues = check_file(fp)
        if issues:
            total += len(issues)
            print(f'--- {fp} ({len(issues)} issues) ---')
            for it in issues[:20]:
                print(f'    {it}')
            if len(issues) > 20:
                print(f'    ... and {len(issues)-20} more')
        else:
            print(f'{fp}: OK')
    print(f'\nTotal issues: {total}')
    return 0 if total == 0 else 1


if __name__ == '__main__':
    sys.exit(main())
