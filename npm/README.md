# ipopt-wasm

[![npm](https://img.shields.io/npm/v/ipopt-wasm)](https://www.npmjs.com/package/ipopt-wasm)

[Ipopt](https://coin-or.github.io/Ipopt/) (Interior Point Optimizer) for JavaScript via WebAssembly. Solves large-scale nonlinear optimization problems. Includes the [MUMPS](http://mumps-solver.org/) sparse direct solver.

Works in **Node.js** and **browsers** — all objective functions and constraints are defined in JavaScript.

## Install

```bash
npm install ipopt-wasm
```

## Quick example

```javascript
import { solve } from "ipopt-wasm";

// Minimize x0*x3*(x0+x1+x2) + x2
// subject to: x0*x1*x2*x3 >= 25, x0²+x1²+x2²+x3² = 40, 1 <= xi <= 5
const result = await solve({
  n: 4,
  m: 2,
  x0: new Float64Array([1, 5, 5, 1]),
  xl: new Float64Array([1, 1, 1, 1]),
  xu: new Float64Array([5, 5, 5, 5]),
  gl: new Float64Array([25, 40]),
  gu: new Float64Array([1e19, 40]),
  nele_jac: 8,
  nele_hess: 10,
  eval_f: (x) => x[0] * x[3] * (x[0] + x[1] + x[2]) + x[2],
  eval_grad_f: (x) => new Float64Array([
    x[3] * (2*x[0] + x[1] + x[2]),
    x[0] * x[3],
    x[0] * x[3] + 1,
    x[0] * (x[0] + x[1] + x[2]),
  ]),
  eval_g: (x) => new Float64Array([
    x[0] * x[1] * x[2] * x[3],
    x[0]**2 + x[1]**2 + x[2]**2 + x[3]**2,
  ]),
  eval_jac_g: (x, structure) => {
    if (structure) return {
      iRow: new Int32Array([0,0,0,0,1,1,1,1]),
      jCol: new Int32Array([0,1,2,3,0,1,2,3]),
    };
    return new Float64Array([
      x[1]*x[2]*x[3], x[0]*x[2]*x[3], x[0]*x[1]*x[3], x[0]*x[1]*x[2],
      2*x[0], 2*x[1], 2*x[2], 2*x[3],
    ]);
  },
  eval_h: (x, obj_factor, lambda, structure) => {
    if (structure) {
      const iRow = [], jCol = [];
      for (let r = 0; r < 4; r++)
        for (let c = 0; c <= r; c++) { iRow.push(r); jCol.push(c); }
      return { iRow: new Int32Array(iRow), jCol: new Int32Array(jCol) };
    }
    const v = new Float64Array(10);
    // ... fill Hessian values
    return v;
  },
}, { print_level: 0 });

console.log(result.x);        // [1.0, 4.743, 3.821, 1.379]
console.log(result.objective); // 17.014
console.log(result.status);    // 0 (optimal)
```

## API

### `solve(problem, options?) → Promise<Result>`

#### Problem definition

| Field | Type | Description |
|-------|------|-------------|
| `n` | `number` | Number of variables |
| `m` | `number` | Number of constraints |
| `x0` | `Float64Array(n)` | Initial guess |
| `xl` | `Float64Array(n)` | Variable lower bounds |
| `xu` | `Float64Array(n)` | Variable upper bounds |
| `gl` | `Float64Array(m)` | Constraint lower bounds |
| `gu` | `Float64Array(m)` | Constraint upper bounds |
| `nele_jac` | `number` | Number of nonzeros in the constraint Jacobian |
| `nele_hess` | `number` | Number of nonzeros in the Hessian of the Lagrangian |
| `eval_f` | `(x: Float64Array) => number` | Objective function |
| `eval_grad_f` | `(x: Float64Array) => Float64Array` | Objective gradient |
| `eval_g` | `(x: Float64Array) => Float64Array` | Constraint functions |
| `eval_jac_g` | `(x, structure) => ...` | Constraint Jacobian (see below) |
| `eval_h` | `(x, obj_factor, lambda, structure) => ...` | Hessian of Lagrangian (see below) |

#### Sparse Jacobian (`eval_jac_g`)

Called with `structure=true` to get the sparsity pattern, then with `structure=false` to get values:

```javascript
eval_jac_g: (x, structure) => {
  if (structure) return {
    iRow: new Int32Array([...]),  // row indices (0-based)
    jCol: new Int32Array([...]),  // column indices (0-based)
  };
  return new Float64Array([...]); // values (same order as structure)
}
```

#### Sparse Hessian (`eval_h`)

Lower-triangular part of the Hessian of the Lagrangian:

```javascript
eval_h: (x, obj_factor, lambda, structure) => {
  if (structure) return { iRow: new Int32Array([...]), jCol: new Int32Array([...]) };
  // H = obj_factor * ∇²f(x) + Σ lambda[i] * ∇²g_i(x)
  return new Float64Array([...]); // values
}
```

#### Options

Pass Ipopt options as a plain object. Common options:

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `print_level` | `number` | `5` | Output verbosity (0 = silent) |
| `tol` | `number` | `1e-8` | Convergence tolerance |
| `max_iter` | `number` | `3000` | Maximum iterations |
| `linear_solver` | `string` | `"mumps"` | Linear solver (only MUMPS available) |

Full list: [Ipopt options documentation](https://coin-or.github.io/Ipopt/OPTIONS.html)

#### Result

| Field | Type | Description |
|-------|------|-------------|
| `x` | `Float64Array(n)` | Optimal solution |
| `objective` | `number` | Optimal objective value |
| `status` | `number` | 0 = solved, see [return codes](https://coin-or.github.io/Ipopt/IpReturnCodes_8h.html) |
| `constraints` | `Float64Array(m)` | Constraint values at solution |
| `mult_g` | `Float64Array(m)` | Constraint multipliers |
| `mult_x_L` | `Float64Array(n)` | Lower bound multipliers |
| `mult_x_U` | `Float64Array(n)` | Upper bound multipliers |

## Performance

Benchmarked on a discretized optimal control problem: minimize ∑u² subject to dynamics x_{i+1} = x_i + h·(x_i² + u_i), with x_0=1, x_N=0. See [`bench.mjs`](https://github.com/louisabraham/ipopt-wasm/blob/main/npm/bench.mjs) and [`test/bench.cpp`](https://github.com/louisabraham/ipopt-wasm/blob/main/test/bench.cpp).

```bash
# Run the benchmarks
node bench.mjs 8000       # wasm32
node bench64.mjs 8000     # wasm64
```

| Problem size | Native arm64 | wasm32 | wasm64 |
|---|---|---|---|
| N=8000 (16k vars) | 72ms | 218ms | 188ms |
| N=80000 (160k vars) | 533ms | OOM | 980ms |

The wasm32 build is limited to 4 GB of memory. For large problems, use the wasm64 build which has no memory limit:

```javascript
import { solve } from "ipopt-wasm/index64.mjs";
```

WebAssembly overhead is **~2–3x** vs native on compute-bound problems.

## License

MIT. The bundled WebAssembly binary contains Ipopt (EPL-2.0), MUMPS (CeCILL-C), LAPACK (BSD-3), and flang-rt (Apache-2.0 WITH LLVM-exception). See [THIRD_PARTY_LICENSES.md](https://github.com/louisabraham/ipopt-wasm/blob/main/THIRD_PARTY_LICENSES.md).
