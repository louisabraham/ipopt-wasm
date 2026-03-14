#!/usr/bin/env python3
"""Fix malloc(i64) -> malloc(i32) in LLVM IR for wasm32.
Inserts a trunc instruction before each malloc call."""

import re
import sys

def fix_malloc(content):
    lines = content.split('\n')
    result = []

    for line in lines:
        # Fix declaration
        if 'declare ptr @malloc(i64)' in line:
            result.append(line.replace('declare ptr @malloc(i64)', 'declare ptr @malloc(i32)'))
            continue

        # Fix call: %X = call ptr @malloc(i64 %Y)
        m = re.match(r'(\s*)(%\S+) = call ptr @malloc\(i64 (%\S+)\)', line)
        if m:
            indent, result_var, size_var = m.groups()
            # Use %malloc.trunc.N for unique names
            fix_malloc.counter = getattr(fix_malloc, 'counter', 0) + 1
            trunc_var = f'%malloc.trunc.{fix_malloc.counter}'
            result.append(f'{indent}{trunc_var} = trunc i64 {size_var} to i32')
            result.append(f'{indent}{result_var} = call ptr @malloc(i32 {trunc_var})')
            continue

        # Fix call without result: call ptr @malloc(i64 %Y)
        m = re.match(r'(\s*)call ptr @malloc\(i64 (%\S+)\)', line)
        if m:
            indent, size_var = m.groups()
            fix_malloc.counter = getattr(fix_malloc, 'counter', 0) + 1
            trunc_var = f'%malloc.trunc.{fix_malloc.counter}'
            result.append(f'{indent}{trunc_var} = trunc i64 {size_var} to i32')
            result.append(f'{indent}call ptr @malloc(i32 {trunc_var})')
            continue

        result.append(line)

    return '\n'.join(result)

if __name__ == '__main__':
    content = open(sys.argv[1]).read()
    fixed = fix_malloc(content)
    open(sys.argv[2] if len(sys.argv) > 2 else sys.argv[1], 'w').write(fixed)
