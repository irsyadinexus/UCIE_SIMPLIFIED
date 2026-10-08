#!/usr/bin/env python3
"""Comment Rule compliance checker for UCIe simplified endpoint.

Rule:
  1. File header comment: 50-500 lines (including the blank-line tail).
  2. Revision history log present in the header.
  3. At least 5 comment lines directly above every always/always_comb/
     always_ff/always_latch, every assign, and every module instantiation.

Usage: python scripts/check_comment_rule.py
"""
import re
import glob
import sys

# Module instantiation: "<type> [#( ... )] <instance> (" on one line.
RE_INST = re.compile(
    r'^\s*([A-Za-z_][A-Za-z0-9_]*)\s*'      # module type
    r'(?:#\s*\(.*?\)\s*)?'                  # optional parameter override
    r'([A-Za-z_][A-Za-z0-9_]*)\s*\($'       # instance name then open paren
)
# Head of a multi-line parameter override: "<type> #(" ending the line.
RE_INST_HDR = re.compile(r'^\s*([A-Za-z_][A-Za-z0-9_]*)\s*#\s*\(\s*$')
# Closing line of a multi-line override: ") <instance> (".
RE_INST_CLOSE = re.compile(r'^\s*\)\s*[A-Za-z_][A-Za-z0-9_]*\s*\(\s*$')
# Keywords and statement forms that must never be read as an instantiation.
KW = {
    'if', 'else', 'begin', 'end', 'case', 'casex', 'casez', 'endcase',
    'for', 'while', 'repeat', 'forever', 'initial', 'final',
    'always', 'always_comb', 'always_ff', 'always_latch', 'assign',
    'module', 'endmodule', 'generate', 'endgenerate', 'function',
    'endfunction', 'task', 'endtask', 'input', 'output', 'inout',
    'logic', 'wire', 'reg', 'integer', 'int', 'bit', 'byte', 'shortint',
    'return', 'import', 'export', 'defparam', 'parameter', 'localparam',
    'typedef', 'enum', 'struct', 'union', 'package', 'endpackage',
    'assert', 'assume', 'cover', 'property', 'endproperty', 'sequence',
    'real', 'time', 'string', 'signed', 'unsigned', 'void', 'class',
    'rand', 'const', 'static', 'automatic', 'unique', 'priority',
}


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


def find_instance_heads(lines):
    """Indices of module-instantiation head lines, including multi-line #(...).

    For a multi-line parameter override the head is the '<type> #(' line, so
    the comment block must sit directly above that line.
    """
    heads = {}
    for i, line in enumerate(lines):
        m = RE_INST.match(line)
        if m and m.group(1) not in KW:
            heads[i] = m.group(2)
            continue
        m2 = RE_INST_HDR.match(line)
        if m2 and m2.group(1) not in KW:
            for j in range(i + 1, min(len(lines), i + 80)):
                if RE_INST_CLOSE.match(lines[j]):
                    heads[i] = m2.group(1)
                    break
                if lines[j].strip() and not lines[j].lstrip().startswith(('.', '//', '#')):
                    break
    return heads


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

    inst_heads = find_instance_heads(lines)

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
        elif i in inst_heads:
            cnt = count_comments_above(lines, i)
            if cnt < 5:
                issues.append(
                    f'line {i+1}: instance of {inst_heads[i]} '
                    f'has {cnt} comment lines (< 5)')
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
