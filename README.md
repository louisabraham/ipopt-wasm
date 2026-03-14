# ipopt-wasm

Ipopt (Interior Point Optimizer) + MUMPS sparse solver compiled to WebAssembly.

**Download**: [louisabraham.github.io/ipopt-wasm](https://louisabraham.github.io/ipopt-wasm/)

## Pre-built libraries

The `dist/` directory contains pre-built static libraries (wasm64/MEMORY64):

| Library | Contents |
|---------|----------|
| `libipopt.a` | Ipopt 3.14.20 |
| `libmumps.a` | MUMPS 5.8.1 + PORD + MPI stubs |
| `liblapack.a` | Reference BLAS/LAPACK |
| `libflangrt.a` | Flang Fortran runtime |

## How to use

Link against these libraries with Emscripten in MEMORY64 mode:

```bash
emcc -sMEMORY64=1 -sWASM_BIGINT -sALLOW_MEMORY_GROWTH=1 \
  your_program.cpp \
  libipopt.a libmumps.a liblapack.a libflangrt.a \
  -o output.js
```

See `test/hs071.cpp` for an example (Hock-Schittkowski problem #71).

## How the build was produced

### Prerequisites (macOS)

```bash
brew install emscripten flang wabt
```

Versions used: Emscripten 5.0.2, flang 22.1.1 (LLVM 22), wabt (for wasm2wat/wat2wasm).

### Build pipeline

The main challenge is compiling Fortran (MUMPS, BLAS/LAPACK) to WebAssembly. Flang cannot target wasm directly, so we use a multi-step pipeline:

```
Fortran source
    ↓  flang-new -fc1 -emit-fir
FIR (Fortran Intermediate Representation, MLIR dialect)
    ↓  fir-opt --external-name-interop
FIR with C-interop name mangling (Add_ convention)
    ↓  tco --target=x86_64-unknown-linux-gnu
LLVM IR (x86_64)
    ↓  sed (retarget triple, fix common linkage, strip unsupported attrs)
LLVM IR (wasm64)
    ↓  emcc -sMEMORY64=1
WebAssembly object (.o)
```

After linking, 21 LLVM wasm64 backend codegen bugs are patched via `fix_wat_targeted.py`, which converts the binary to WAT text format, inserts `i32.wrap_i64` instructions where `lround`/`lroundf` return values feed into i32 locals, and converts back.

### Build steps

```bash
# 1. Download dependencies (Ipopt, MUMPS, LAPACK source)
bash setup.sh

# 2. Build flang Fortran runtime for wasm64
bash build_flangrt.sh

# 3. Compile MUMPS + BLAS/LAPACK + Ipopt
bash build.sh

# 4. Link, patch WAT, validate, test
bash link.sh
```

### Key workarounds

- **flang i686 target bug**: `unrealized_conversion_cast` on assumed-size arrays prevents using 32-bit target. Workaround: use x86_64 target + wasm64/MEMORY64.
- **LLVM wasm64 codegen bugs**: 21 functions have i32/i64 type mismatches from `lround`/`lroundf` returning i64 on wasm64. Fixed by post-processing the WAT.
- **Fortran hidden char lengths**: x86_64 ABI passes character string lengths as `i64`. Ipopt's BLAS/LAPACK declarations patched to use `long long` instead of `int`.
- **MUMPS signature mismatches**: `mpi_bcast_` and `dmumps_root_solve_` have caller/callee argument count differences fixed in the LLVM IR.
- **`ptrtoint` in static initializers**: Fortran type descriptors use `ptrtoint ptr to i64` which is unsupported on wasm32. Zeroed out (runtime recalculates).
- **Fortran descriptor ABI**: `CFI_index_t` (ptrdiff_t) and `elem_len` (size_t) are 64-bit in flang's IR but 32-bit on wasm32. Using wasm64 makes them match natively.

### Performance

On Hock-Schittkowski problem #71 (4 variables):

| Platform | Time |
|----------|------|
| Native arm64 (Apple M4) | 2ms |
| WebAssembly (Node.js) | 42ms |

~21x overhead, dominated by startup/initialization on this small problem.
