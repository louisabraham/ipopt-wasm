#!/usr/bin/env python3
"""
Fix wasm64 lround/lroundf codegen bug: these return i64 but callers expect i32.
Insert i32.wrap_i64 after each call to the identified lround/lroundf functions.
Works with unnamed (indexed) functions.
"""
import sys
import re

def find_lround_funcs(lines):
    """Find function indices for lround (f64->i64) and lroundf (f32->i64)."""
    funcs = set()
    for i, line in enumerate(lines):
        # lround: (func (;N;) (type M) (param f64) (result i64)  with body: call X; i64.trunc_sat_f64_s
        # lroundf: (func (;N;) (type M) (param f32) (result i64) with body: call X; i64.trunc_sat_f32_s
        m = re.match(r'\s*\(func \(;(\d+);\).*\(param f(?:32|64)\) \(result i64\)', line)
        if m:
            idx = int(m.group(1))
            # Check body for trunc_sat pattern
            for j in range(i+1, min(i+5, len(lines))):
                if 'trunc_sat_f' in lines[j]:
                    funcs.add(idx)
                    break
    return funcs

def fix(lines, lround_funcs):
    """Insert i32.wrap_i64 after calls to lround/lroundf functions."""
    insertions = []
    call_pattern = re.compile(r'^(\s*)call (\d+)\s*$')

    for i, line in enumerate(lines):
        m = call_pattern.match(line)
        if m and int(m.group(2)) in lround_funcs:
            indent = m.group(1)
            # Check if next non-empty line already has i32.wrap_i64
            for j in range(i+1, min(i+3, len(lines))):
                next_line = lines[j].strip()
                if next_line == 'i32.wrap_i64':
                    break  # already fixed
                if next_line:
                    insertions.append((i+1, f"{indent}i32.wrap_i64\n"))
                    break

    # Apply insertions backwards
    for pos, text in reversed(insertions):
        lines.insert(pos, text)

    return len(insertions)

def main():
    wat_in = sys.argv[1]
    wat_out = sys.argv[2]

    with open(wat_in, 'r') as f:
        lines = f.readlines()

    lround_funcs = find_lround_funcs(lines)
    print(f"Found lround/lroundf functions: {sorted(lround_funcs)}")

    count = fix(lines, lround_funcs)
    print(f"Inserted {count} i32.wrap_i64 instructions")

    with open(wat_out, 'w') as f:
        f.writelines(lines)

if __name__ == '__main__':
    main()
