#!/usr/bin/env python3
"""
Targeted WAT fixer: only touches the 12 functions with known errors.
For each function, does a careful stack type simulation and inserts
i32.wrap_i64 only where truly needed.
"""

import re
import sys

# Functions with known errors
AFFECTED_FUNCTIONS = {
    'dmumps_ana_gnew_',
    'dmumps_ana_lnew_',
    'dmumps_split_1node_',
    'dmumps_truncated_rrqr_',
    'dmumps_sol_b_',
    'dmumps_max_mem_',
    '_QMmumps_static_mappingFmumps_distributePmumps_costs_layer_t2',
    '_QMmumps_static_mappingFmumps_distributePmumps_costs_layer_t2pm',
    '_QMmumps_static_mappingFmumps_distributePmumps_propmap',
    '_QMmumps_static_mappingFmumps_distributePmumps_mod_propmap',
    'mumps_bloc2_get_nslavesmin_',
    'mumps_bloc2_get_nslavesmax_',
    'iparmq_',
}

def parse_types(lines, start, end):
    """Extract param+local types from function header."""
    types = []
    for j in range(start, min(start + 30, end)):
        for m in re.finditer(r'\(param\s+([^)]+)\)', lines[j]):
            types.extend(m.group(1).split())
        for m in re.finditer(r'\(local\s+([^)]+)\)', lines[j]):
            types.extend(m.group(1).split())
    return types

def simulate_and_fix(lines, start, end, local_types):
    """
    Careful stack simulation. Returns list of (line_idx, instruction_to_insert).
    Only inserts wraps where the stack type is definitively wrong.
    """
    fixes = []
    # Stack of types. None means "unknown"
    stack = []

    def push(t):
        stack.append(t)

    def pop():
        return stack.pop() if stack else None

    def peek():
        return stack[-1] if stack else None

    def peek2():
        return stack[-2] if len(stack) >= 2 else None

    for i in range(start, end + 1):
        line = lines[i].strip()
        if not line or line.startswith('(') or line.startswith(')') or line.startswith(';;'):
            continue

        parts = line.split()
        instr = parts[0]

        # ===== Values pushed =====
        if instr == 'i32.const':
            push('i32'); continue
        if instr == 'i64.const':
            push('i64'); continue
        if instr == 'f32.const':
            push('f32'); continue
        if instr == 'f64.const':
            push('f64'); continue

        if instr == 'local.get':
            try:
                idx = int(parts[1])
                push(local_types[idx] if idx < len(local_types) else None)
            except: push(None)
            continue

        if instr == 'global.get':
            push('i64'); continue  # __stack_pointer is i64 in wasm64

        # ===== Loads =====
        if instr.startswith('i32.load'): pop(); push('i32'); continue  # pop addr, push value
        if instr.startswith('i64.load'): pop(); push('i64'); continue
        if instr.startswith('f32.load'): pop(); push('f32'); continue
        if instr.startswith('f64.load'):
            pop(); push('f64'); continue

        # ===== Conversions =====
        if instr == 'i64.extend_i32_s' or instr == 'i64.extend_i32_u':
            pop(); push('i64'); continue
        if instr == 'i32.wrap_i64':
            pop(); push('i32'); continue
        if instr.startswith('f64.convert'):
            pop(); push('f64'); continue
        if instr.startswith('f32.convert'):
            pop(); push('f32'); continue
        if instr.startswith('i32.trunc'):
            pop(); push('i32'); continue
        if instr.startswith('i64.trunc'):
            pop(); push('i64'); continue
        if instr == 'f64.reinterpret_i64':
            pop(); push('f64'); continue
        if instr == 'i64.reinterpret_f64':
            pop(); push('i64'); continue
        if instr == 'f32.reinterpret_i32':
            pop(); push('f32'); continue
        if instr == 'i32.reinterpret_f32':
            pop(); push('i32'); continue
        if instr == 'f64.promote_f32':
            pop(); push('f64'); continue
        if instr == 'f32.demote_f64':
            pop(); push('f32'); continue

        # ===== i64 binary ops =====
        if instr in ('i64.add','i64.sub','i64.mul','i64.div_s','i64.div_u',
                      'i64.rem_s','i64.rem_u','i64.and','i64.or','i64.xor',
                      'i64.shl','i64.shr_s','i64.shr_u','i64.rotl','i64.rotr'):
            pop(); pop(); push('i64'); continue
        if instr in ('i64.eq','i64.ne','i64.lt_s','i64.lt_u','i64.gt_s','i64.gt_u',
                      'i64.le_s','i64.le_u','i64.ge_s','i64.ge_u'):
            pop(); pop(); push('i32'); continue
        if instr == 'i64.eqz':
            pop(); push('i32'); continue
        if instr in ('i64.clz','i64.ctz','i64.popcnt'):
            pop(); push('i64'); continue

        # ===== i32 binary ops (these are where errors occur) =====
        if instr in ('i32.add','i32.sub','i32.mul','i32.div_s','i32.div_u',
                      'i32.rem_s','i32.rem_u','i32.and','i32.or','i32.xor',
                      'i32.shl','i32.shr_s','i32.shr_u','i32.rotl','i32.rotr'):
            top = peek()
            second = peek2()
            if top == 'i64':
                fixes.append((i, 'i32.wrap_i64'))
                stack[-1] = 'i32'
                top = 'i32'
            # After wrapping top, check second
            if second == 'i64' and len(stack) >= 2:
                # Can't easily fix second-to-top without temp local
                # But we can check: is there a previous instruction we can wrap?
                # Actually at WAT level, we insert wrap BEFORE the top's producer
                # Scan backward to find where top was produced
                for k in range(i-1, max(start, i-50), -1):
                    prev = lines[k].strip()
                    if not prev or prev.startswith(';;') or prev.startswith('(') or prev.startswith(')'):
                        continue
                    # Is this the instruction that produced the current top?
                    p = prev.split()[0] if prev.split() else ''
                    if p in ('i32.const','i32.load','i32.load8_s','i32.load8_u',
                             'i32.load16_s','i32.load16_u','i32.wrap_i64',
                             'local.get','i32.eqz') or p.startswith('i32.'):
                        # This produced the i32 on top. Insert wrap BEFORE it
                        # to wrap the i64 second-to-top value
                        fixes.append((k, 'i32.wrap_i64'))
                        stack[-2] = 'i32'
                        break
                    elif p in ('call','call_indirect','block','loop','if','end',
                               'else','br','br_if','return','unreachable'):
                        break  # Can't trace through control flow
                    break

            pop(); pop(); push('i32')
            continue

        if instr in ('i32.eq','i32.ne','i32.lt_s','i32.lt_u','i32.gt_s','i32.gt_u',
                      'i32.le_s','i32.le_u','i32.ge_s','i32.ge_u'):
            top = peek()
            if top == 'i64':
                fixes.append((i, 'i32.wrap_i64'))
                stack[-1] = 'i32'
            pop(); pop(); push('i32')
            continue

        if instr == 'i32.eqz':
            if peek() == 'i64':
                fixes.append((i, 'i32.wrap_i64'))
                stack[-1] = 'i32'
            pop(); push('i32')
            continue

        if instr in ('i32.clz','i32.ctz','i32.popcnt'):
            if peek() == 'i64':
                fixes.append((i, 'i32.wrap_i64'))
                stack[-1] = 'i32'
            continue

        # ===== f64 binary ops =====
        if instr in ('f64.add','f64.sub','f64.mul','f64.div','f64.min','f64.max','f64.copysign'):
            pop(); pop(); push('f64'); continue
        if instr in ('f64.eq','f64.ne','f64.lt','f64.gt','f64.le','f64.ge'):
            pop(); pop(); push('i32'); continue
        if instr in ('f64.abs','f64.neg','f64.ceil','f64.floor','f64.trunc','f64.nearest','f64.sqrt'):
            continue

        # ===== Stores =====
        if instr in ('i32.store','i32.store8','i32.store16'):
            if peek() == 'i64':
                fixes.append((i, 'i32.wrap_i64'))
            pop(); pop(); continue  # pop value, pop addr
        if instr in ('i64.store','i64.store8','i64.store16','i64.store32'):
            pop(); pop(); continue
        if instr in ('f64.store','f32.store'):
            pop(); pop(); continue

        # ===== local.tee / local.set =====
        if instr == 'local.tee':
            try:
                idx = int(parts[1])
                lt = local_types[idx] if idx < len(local_types) else None
                if lt == 'i32' and peek() == 'i64':
                    fixes.append((i, 'i32.wrap_i64'))
                    stack[-1] = 'i32'
            except: pass
            continue  # tee doesn't change stack

        if instr == 'local.set':
            try:
                idx = int(parts[1])
                lt = local_types[idx] if idx < len(local_types) else None
                if lt == 'i32' and peek() == 'i64':
                    fixes.append((i, 'i32.wrap_i64'))
            except: pass
            pop(); continue

        if instr == 'global.set':
            pop(); continue

        # ===== Control flow =====
        # block/loop/end are structural markers, don't clear stack
        # br/br_if/br_table/return/unreachable terminate the current path
        if instr in ('block', 'loop'):
            continue  # structural, stack persists
        if instr == 'end':
            continue  # keep stack - values persist through blocks
        if instr == 'if':
            pop()  # consumes condition (i32)
            continue  # keep stack for if body
        if instr == 'else':
            stack.clear(); continue  # different branch, unknown stack
        if instr in ('br','br_if','br_table','return','unreachable'):
            if instr == 'br_if':
                pop()  # consumes condition
            else:
                stack.clear()
            continue

        # ===== Calls =====
        if instr == 'call':
            stack.clear()
            # Try to infer return type from what follows
            # If next instruction is local.tee/local.set N, the return type matches local N
            # If next is i32.store, return is i32; if i64.store, return is i64
            # For known functions:
            fname = parts[1] if len(parts) > 1 else ''
            if fname in ('$lround', '$lroundf', '$llround', '$__wasi_clock_time_get'):
                push('i64')
            elif fname.startswith('$_Fortran') and 'Begin' in fname:
                push('i64')  # returns Cookie (ptr = i64)
            elif fname.startswith('$_Fortran') and ('Output' in fname or 'Input' in fname or 'Set' in fname or 'Inquire' in fname or 'Enable' in fname):
                push('i32')  # returns bool/int
            elif fname.startswith('$_Fortran') and 'End' in fname:
                push('i32')  # returns enum
            elif fname.startswith('$_Fortran') and ('Allocat' in fname or 'Deallocat' in fname):
                push('i32')  # returns int status
            else:
                # Unknown return type - check next instruction for hints
                for k in range(i+1, min(i+5, end)):
                    next_l = lines[k].strip()
                    if not next_l or next_l.startswith(';;'):
                        continue
                    np = next_l.split()
                    if not np:
                        continue
                    ni = np[0]
                    if ni == 'local.tee' or ni == 'local.set':
                        try:
                            idx = int(np[1])
                            lt = local_types[idx] if idx < len(local_types) else None
                            if lt:
                                push(lt)
                        except:
                            pass
                    elif ni == 'drop':
                        push('unknown')
                    elif ni.startswith('i32.'):
                        push('i32')
                    elif ni.startswith('i64.'):
                        push('i64')
                    elif ni.startswith('f64.'):
                        push('f64')
                    break
            continue
        if instr == 'call_indirect':
            stack.clear(); continue

        # ===== Memory ops =====
        if instr == 'memory.fill':
            stack.clear(); continue
        if instr == 'memory.copy':
            stack.clear(); continue
        if instr == 'memory.grow':
            pop(); push('i64'); continue
        if instr == 'memory.size':
            push('i64'); continue

        # ===== Misc =====
        if instr == 'drop':
            pop(); continue
        if instr == 'select':
            pop(); pop(); continue  # leaves one value
        if instr == 'nop':
            continue

        # Unknown - clear
        stack.clear()

    return fixes

def main():
    wat_in = sys.argv[1]
    wat_out = sys.argv[2]

    with open(wat_in, 'r') as f:
        lines = f.readlines()

    print(f"Read {len(lines)} lines")

    # Find affected functions
    func_pattern = re.compile(r'^\s*\(func \$(\S+)')
    all_fixes = []

    i = 0
    while i < len(lines):
        m = func_pattern.match(lines[i])
        if m:
            func_name = m.group(1)
            func_start = i

            # Find end
            depth = 0
            func_end = i
            for j in range(i, len(lines)):
                depth += lines[j].count('(') - lines[j].count(')')
                if depth <= 0 and j > i:
                    func_end = j
                    break

            # Only process affected functions
            if func_name in AFFECTED_FUNCTIONS:
                local_types = parse_types(lines, func_start, func_end)
                fixes = simulate_and_fix(lines, func_start, func_end, local_types)
                if fixes:
                    all_fixes.extend(fixes)
                    print(f"  ${func_name}: {len(fixes)} fixes")

            i = func_end + 1
        else:
            i += 1

    print(f"\nTotal: {len(all_fixes)} fixes")

    # Apply fixes backwards
    all_fixes.sort(key=lambda x: x[0], reverse=True)
    for line_idx, instruction in all_fixes:
        indent = re.match(r'^(\s*)', lines[line_idx]).group(1)
        lines.insert(line_idx, f"{indent}{instruction}\n")

    with open(wat_out, 'w') as f:
        f.writelines(lines)

    print(f"Written {len(lines)} lines")

if __name__ == '__main__':
    main()
