# ipopt-wasm

Ipopt (Interior Point Optimizer) + MUMPS sparse solver compiled to WebAssembly.

**Download**: [louisabraham.github.io/ipopt-wasm](https://louisabraham.github.io/ipopt-wasm/)

## Pre-built libraries

The `dist/` directory contains pre-built wasm32 static libraries (compiled with `-fPIC`):

| Library | Contents |
|---------|----------|
| `libipopt.a` | Ipopt 3.14.20 |
| `libmumps.a` | MUMPS 5.8.1 + PORD + MPI stubs |
| `liblapack.a` | Reference BLAS/LAPACK |
| `libflangrt.a` | Flang Fortran runtime |
| `wasm32_bridges.c` | Bridge functions for Fortran runtime ABI |

## How to use

Link against these libraries with Emscripten:

```bash
emcc -fPIC -sALLOW_MEMORY_GROWTH=1 -sERROR_ON_UNDEFINED_SYMBOLS=0 \
  your_program.cpp wasm32_bridges.c \
  libipopt.a libmumps.a liblapack.a libflangrt.a \
  -o output.js
```

See `test/hs071.cpp` for an example (Hock-Schittkowski problem #71).

## Pyodide / cyipopt

This project enables [cyipopt](https://github.com/mechmotum/cyipopt) to run in [Pyodide](https://pyodide.org), bringing Ipopt to the browser and any Python-in-WebAssembly environment.

The [cyipopt build wheels PR](https://github.com/mechmotum/cyipopt/pull/305) uses ipopt-wasm as follows:

1. The Pyodide build downloads the pre-built `.a` libraries from [GitHub Pages](https://louisabraham.github.io/ipopt-wasm/)
2. cyipopt's Cython extension links against them during `pyodide build`
3. The resulting `.whl` can be `pip install`'d in any Pyodide environment

```python
# In Pyodide (browser or Node.js)
import micropip
await micropip.install("cyipopt")

import cyipopt
# ... solve optimization problems with Ipopt + MUMPS
```

This means Ipopt — a production-grade nonlinear optimizer backed by the MUMPS sparse direct solver — can now run entirely in the browser with no server-side computation.

## How the build was produced

### Prerequisites (macOS)

```bash
brew install emscripten flang wabt
```

Versions used: Emscripten 5.0.2, flang 22.1.1 (LLVM 22), wabt (for wasm validation).

### Build pipeline

The main challenge is compiling Fortran (MUMPS, BLAS/LAPACK) to WebAssembly. Flang cannot target wasm directly, so we use a multi-step pipeline:

```
Fortran source
    ↓  flang-new -fc1 -emit-fir
FIR (Fortran Intermediate Representation, MLIR dialect)
    ↓  fir-opt --external-name-interop
FIR with C-interop name mangling (Add_ convention)
    ↓  tco --target=i686-unknown-linux-gnu
LLVM IR (i686, 32-bit pointers)
    ↓  sed (retarget to wasm32, fix common linkage, strip attrs, fix malloc)
    ↓  fix_malloc.py (patch malloc(i64) → malloc(i32))
LLVM IR (wasm32)
    ↓  emcc -fPIC
WebAssembly object (.o)
```

### Build steps

```bash
# 1. Download dependencies (Ipopt, MUMPS, LAPACK source)
bash setup.sh

# 2. Build flang Fortran runtime for wasm32
bash build_flangrt.sh

# 3. Compile MUMPS + BLAS/LAPACK + Ipopt
bash build.sh

# 4. Link, validate, test
bash link.sh
```

### Key workarounds

- **flang can't target wasm**: Fortran → FIR → `tco` (i686 LLVM IR) → retarget wasm32 via sed.
- **flang i686 `unrealized_conversion_cast` bug**: `flang-new --target=i686` crashes on assumed-size arrays. Workaround: use `flang-new -fc1 -emit-fir` (target-independent) then `tco --target=i686` (separate lowering, avoids the bug).
- **`malloc(i64)` in Fortran IR**: `tco` always generates 64-bit malloc sizes. Fixed by `fix_malloc.py` which inserts `trunc i64 to i32` before each call.
- **`ptrtoint` in static initializers**: Fortran type descriptors use `ptrtoint ptr to i64` which is unsupported on wasm32. Zeroed out in the IR (runtime recalculates).
- **Fortran descriptor ABI**: `CFI_index_t` and `elem_len` are 64-bit in flang's IR but 32-bit in the C runtime. The flang runtime is compiled with a patched `ISO_Fortran_binding.h` using `int64_t`/`uint64_t` for these fields.
- **Fortran hidden char lengths**: flang generates `i64` for Fortran CHARACTER string length parameters. `wasm32_bridges.c` provides wrapper functions that accept `i64` lengths for the mismatched runtime functions.
- **MUMPS signature mismatches**: `mpi_bcast_` and `dmumps_root_solve_` have caller/callee argument count differences fixed in the LLVM IR.
- **`-fPIC`**: Required for Pyodide/shared library linking.

### Performance

On Hock-Schittkowski problem #71 (4 variables):

| Platform | Time |
|----------|------|
| Native arm64 (Apple M4) | 5ms |
| WebAssembly wasm32 (Node.js) | 43ms |

~9x overhead, dominated by startup/initialization on this small problem.
