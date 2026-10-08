import re
import glob
import os

rtl_files = sorted(glob.glob('rtl/**/*.sv', recursive=True))
tb_files = sorted(glob.glob('tb/**/*.sv', recursive=True))
all_files = rtl_files + tb_files

print(f"Total files: {len(all_files)}")

def analyze_file(filepath):
    with open(filepath, 'r', encoding='utf-8', errors='ignore') as f:
        lines = f.readlines()
    
    # 1. Header comments: find top comment block
    header_lines = 0
    in_block = False
    for line in lines:
        s = line.strip()
        if s.startswith('//'):
            header_lines += 1
        elif s.startswith('/*'):
            in_block = True
            header_lines += 1
        elif in_block:
            header_lines += 1
            if '*/' in s:
                in_block = False
        elif s == '':
            if header_lines > 0:
                header_lines += 1  # count blank lines inside header
            continue
        else:
            break
            
    # Check revision history
    content = "".join(lines)
    has_rev = bool(re.search(r'revision history|rev\s+date', content, re.IGNORECASE))
    
    # Check always blocks
    always_indices = []
    assign_indices = []
    inst_indices = []
    
    for i, line in enumerate(lines):
        s = line.strip()
        if re.match(r'^(always|always_comb|always_ff|always_latch)\b', s):
            always_indices.append(i)
        elif re.match(r'^assign\b', s):
            assign_indices.append(i)
            
    print(f"{filepath}: header_lines={header_lines}, has_rev={has_rev}, always={len(always_indices)}, assign={len(assign_indices)}")

for fp in all_files:
    analyze_file(fp)
