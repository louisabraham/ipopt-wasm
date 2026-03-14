#!/usr/bin/env python3
"""
Comprehensive WAT fixer for wasm64 type mismatches.
Two categories:
1. lround/lroundf: ALWAYS wrap i64 result to i32 (these conceptually return int)
2. Other i64 functions: wrap when flowing into i32 locals/stores
"""
import re
import sys

def find_lround_funcs(lines):
    """Find function indices for lround/lroundf: (f64->i64) or (f32->i64) with trunc_sat body."""
    funcs = set()
    for i, line in enumerate(lines):
        m = re.match(r'\s*\(func \(;(\d+);\).*\(param f(?:32|64)\) \(result i64\)', line)
        if m:
            idx = int(m.group(1))
            for j in range(i+1, min(i+5, len(lines))):
                if 'trunc_sat_f' in lines[j]:
                    funcs.add(idx)
                    break
    return funcs

def build_func_return_types(lines):
    """Build map: func_index -> return_type."""
    ret = {}
    for line in lines:
        m = re.match(r'\s*\(func \(;(\d+);\) \(type (\d+)\)', line)
        if m:
            fidx = int(m.group(1))
            rm = re.search(r'\(result (i32|i64|f32|f64)\)', line)
            ret[fidx] = rm.group(1) if rm else None
    return ret

def get_local_types(lines, start, end):
    """Extract param+local types from function header."""
    types = []
    for j in range(start, min(start + 50, end)):
        for m in re.finditer(r'\(param\s+([^)]+)\)', lines[j]):
            types.extend(m.group(1).split())
        for m in re.finditer(r'\(local\s+([^)]+)\)', lines[j]):
            types.extend(m.group(1).split())
        stripped = lines[j].strip()
        if stripped and not stripped.startswith('(') and not stripped.startswith(')'):
            break
    return types

def fix_function(lines, start, end, local_types, func_returns, lround_funcs):
    """Find and fix i64->i32 mismatches."""
    fixes = []
    call_re = re.compile(r'^(\s*)call (\d+)\s*$')

    for i in range(start, end):
        m = call_re.match(lines[i])
        if not m:
            continue

        callee = int(m.group(2))
        indent = m.group(1)

        # Category 1: lround/lroundf — ALWAYS wrap
        if callee in lround_funcs:
            # Check next non-empty line isn't already a wrap
            for j in range(i + 1, min(i + 3, end)):
                next_line = lines[j].strip()
                if not next_line or next_line.startswith(';;'):
                    continue
                if next_line.startswith('i32.wrap_i64'):
                    break
                fixes.append((i + 1, indent + 'i32.wrap_i64\n'))
                break
            continue

        # Category 2: other i64-returning functions
        ret_type = func_returns.get(callee)
        if ret_type != 'i64':
            continue

        for j in range(i + 1, min(i + 3, end)):
            next_line = lines[j].strip()
            if not next_line or next_line.startswith(';;'):
                continue
            if next_line.startswith('i32.wrap_i64'):
                break

            # local.tee/set to i32 local
            lm = re.match(r'^\s*local\.(tee|set) (\d+)', lines[j])
            if lm:
                local_idx = int(lm.group(2))
                if local_idx < len(local_types) and local_types[local_idx] == 'i32':
                    fixes.append((i + 1, indent + 'i32.wrap_i64\n'))
                break

            # i32 operations
            if any(next_line.startswith(op) for op in [
                'i32.store', 'i32.add', 'i32.sub', 'i32.mul', 'i32.div',
                'i32.rem', 'i32.and', 'i32.or', 'i32.xor', 'i32.shl',
                'i32.shr', 'i32.eqz', 'i32.eq', 'i32.ne', 'i32.lt',
                'i32.gt', 'i32.le', 'i32.ge', 'i32.clz', 'i32.ctz',
                'i32.popcnt', 'i32.rotl', 'i32.rotr']):
                fixes.append((i + 1, indent + 'i32.wrap_i64\n'))
                break
            break

    return fixes

def main():
    wat_in = sys.argv[1]
    wat_out = sys.argv[2]

    with open(wat_in, 'r') as f:
        lines = f.readlines()

    print(f"Read {len(lines)} lines")

    lround_funcs = find_lround_funcs(lines)
    print(f"lround/lroundf functions: {sorted(lround_funcs)}")

    func_returns = build_func_return_types(lines)
    i64_funcs = sum(1 for v in func_returns.values() if v == 'i64')
    print(f"Found {len(func_returns)} functions, {i64_funcs} return i64")

    func_pattern = re.compile(r'^\s*\(func \(;(\d+);\)')
    func_starts = []
    for i, line in enumerate(lines):
        m = func_pattern.match(line)
        if m:
            func_starts.append((i, int(m.group(1))))

    all_fixes = []
    for k, (start, fidx) in enumerate(func_starts):
        end = func_starts[k + 1][0] if k + 1 < len(func_starts) else len(lines)
        local_types = get_local_types(lines, start, end)
        fixes = fix_function(lines, start, end, local_types, func_returns, lround_funcs)
        if fixes:
            all_fixes.extend(fixes)
            print(f"  func {fidx}: {len(fixes)} fixes")

    print(f"\nTotal: {len(all_fixes)} fixes")

    all_fixes.sort(key=lambda x: x[0], reverse=True)
    for pos, text in all_fixes:
        lines.insert(pos, text)

    with open(wat_out, 'w') as f:
        f.writelines(lines)

    print(f"Written {len(lines)} lines")

if __name__ == '__main__':
    main()
