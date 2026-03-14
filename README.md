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

## npm package

The `npm/` directory contains a JavaScript/TypeScript-friendly wrapper around Ipopt. It works in both Node.js and browsers — all objective functions and constraints are defined in JavaScript.

```javascript
import { solve } from "ipopt-wasm";

const result = await solve({
  n: 4, m: 2,
  x0: new Float64Array([1, 5, 5, 1]),
  xl: new Float64Array([1, 1, 1, 1]),
  xu: new Float64Array([5, 5, 5, 5]),
  gl: new Float64Array([25, 1e19]),
  gu: new Float64Array([1e19, 40]),
  nele_jac: 8, nele_hess: 10,

  eval_f: (x) => x[0]*x[3]*(x[0]+x[1]+x[2]) + x[2],
  eval_grad_f: (x) => new Float64Array([...]),
  eval_g: (x) => new Float64Array([...]),
  eval_jac_g: (x, structure) => structure ? {iRow, jCol} : new Float64Array([...]),
  eval_h: (x, obj_factor, lambda, structure) => structure ? {iRow, jCol} : new Float64Array([...]),
}, { print_level: 0, linear_solver: "mumps" });

console.log(result.x, result.objective, result.status);
```

Test in Node: `cd npm && node test.mjs`
Test in browser: serve `npm/` and open `test.html`

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

The full build compiles ~2500 source files (130 MUMPS Fortran, 2200+ BLAS/LAPACK, 109 Ipopt C++, 65 flang runtime C++) and takes approximately 30 minutes on a modern machine. Because of this, the CI only deploys the pre-built `dist/` directory to GitHub Pages — it does not rebuild from source.

To reproduce the `dist/` libraries locally:

```bash
# 1. Download dependencies (Ipopt, MUMPS, LAPACK source)
bash setup.sh

# 2. Build flang Fortran runtime for wasm32
bash build_flangrt.sh

# 3. Compile MUMPS + BLAS/LAPACK + Ipopt
bash build.sh

# 4. Link, validate, test
bash link.sh

# 5. Copy artifacts to dist/
cp build/out/lib*.a dist/
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

Benchmarked on a discretized optimal control problem (see `test/bench.cpp`, `npm/bench.mjs`):

| Problem size | Native arm64 | wasm32 | wasm64 |
|---|---|---|---|
| N=8000 (16k vars) | 72ms | 218ms | 188ms |
| N=80000 (160k vars) | 533ms | OOM | 980ms |

WebAssembly overhead is ~2–3x vs native. The wasm32 build is limited to 4 GB; the wasm64 build (MEMORY64) has no memory limit.

## License

The build scripts, JS wrapper, and glue code in this repository are licensed under the [MIT License](LICENSE).

The compiled WebAssembly binary bundles the following third-party libraries under their own licenses:

| Library | License |
|---------|---------|
| [Ipopt](https://github.com/coin-or/Ipopt) | EPL-2.0 |
| [MUMPS](http://mumps-solver.org/) | CeCILL-C (LGPL-compatible) |
| [LAPACK](https://github.com/Reference-LAPACK/lapack) | BSD-3-Clause |
| [flang-rt](https://github.com/llvm/llvm-project/tree/main/flang-rt) | Apache-2.0 WITH LLVM-exception |

See [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md) for full details.
