import re
import glob

tb_files = sorted(glob.glob('tb/**/*.sv', recursive=True))

def check_construct_comments(filepath):
    with open(filepath, 'r', encoding='utf-8', errors='ignore') as f:
        lines = f.readlines()
        
    issues = []
    
    def count_comments_above(idx):
        c = 0
        i = idx - 1
        while i >= 0:
            line_str = lines[i].strip()
            if line_str.startswith('//') or line_str.startswith('/*') or line_str.endswith('*/') or line_str.startswith('*'):
                c += 1
                i -= 1
            elif line_str == '':
                i -= 1
                continue
            else:
                break
        return c

    for i, line in enumerate(lines):
        s = line.strip()
        if re.match(r'^(always|always_comb|always_ff|always_latch)\b', s):
            cnt = count_comments_above(i)
            if cnt < 5:
                issues.append(('always', i + 1, cnt, s[:30]))
        elif re.match(r'^assign\b', s):
            cnt = count_comments_above(i)
            if cnt < 5:
                issues.append(('assign', i + 1, cnt, s[:30]))
                
    if issues:
        print(f"\n--- {filepath} ({len(issues)} issues) ---")
        for kind, lineno, cnt, snippet in issues[:10]:
            print(f"  Line {lineno}: {kind} has only {cnt} comment lines: {snippet}")
        if len(issues) > 10:
            print(f"  ... and {len(issues) - 10} more")
    else:
        print(f"{filepath}: ALL OK")

for fp in tb_files:
    check_construct_comments(fp)
