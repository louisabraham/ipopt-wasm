// Benchmark: discretized optimal control problem
// min sum u_i^2, s.t. x_{i+1} = x_i + h*(x_i^2 + u_i), x_0=1, x_N=0
import { solve } from "./index.mjs";

const N = parseInt(process.argv[2] || "200000");
const h = 1.0 / N;
const n = 2 * N + 1; // x_0..x_N, u_0..u_{N-1}
const m = N + 1;      // N dynamics + initial condition

console.log(`Optimal control: N=${N}, n=${n} vars, m=${m} constraints`);

const t0 = performance.now();
const result = await solve(
  {
    n, m,
    x0: Float64Array.from({ length: n }, (_, i) =>
      i <= N ? 1 - i / N : 0
    ),
    xl: Float64Array.from({ length: n }, (_, i) =>
      i <= N ? (i === N ? 0 : -1e19) : -2
    ),
    xu: Float64Array.from({ length: n }, (_, i) =>
      i <= N ? (i === N ? 0 : 1e19) : 2
    ),
    gl: new Float64Array(m), // all zeros (equality)
    gu: new Float64Array(m),
    nele_jac: 1 + N * 3,
    nele_hess: N + N,

    eval_f(x) {
      let obj = 0;
      for (let i = 0; i < N; i++) obj += h * x[N + 1 + i] ** 2;
      return obj;
    },

    eval_grad_f(x) {
      const g = new Float64Array(n);
      for (let i = 0; i < N; i++) g[N + 1 + i] = 2 * h * x[N + 1 + i];
      return g;
    },

    eval_g(x) {
      const g = new Float64Array(m);
      g[0] = x[0] - 1;
      for (let i = 0; i < N; i++)
        g[1 + i] = x[i + 1] - x[i] - h * (x[i] * x[i] + x[N + 1 + i]);
      return g;
    },

    eval_jac_g(x, structure) {
      if (structure) {
        const iRow = new Int32Array(1 + N * 3);
        const jCol = new Int32Array(1 + N * 3);
        let k = 0;
        iRow[k] = 0; jCol[k] = 0; k++;
        for (let i = 0; i < N; i++) {
          iRow[k] = 1 + i; jCol[k] = i;       k++;
          iRow[k] = 1 + i; jCol[k] = i + 1;   k++;
          iRow[k] = 1 + i; jCol[k] = N + 1 + i; k++;
        }
        return { iRow, jCol };
      }
      const v = new Float64Array(1 + N * 3);
      let k = 0;
      v[k++] = 1;
      for (let i = 0; i < N; i++) {
        v[k++] = -1 - 2 * h * x[i];
        v[k++] = 1;
        v[k++] = -h;
      }
      return v;
    },

    eval_h(x, obj_factor, lambda, structure) {
      if (structure) {
        const iRow = new Int32Array(2 * N);
        const jCol = new Int32Array(2 * N);
        let k = 0;
        for (let i = 0; i < N; i++) { iRow[k] = i; jCol[k] = i; k++; }
        for (let i = 0; i < N; i++) { iRow[k] = N+1+i; jCol[k] = N+1+i; k++; }
        return { iRow, jCol };
      }
      const v = new Float64Array(2 * N);
      let k = 0;
      for (let i = 0; i < N; i++) v[k++] = -2 * h * lambda[1 + i];
      for (let i = 0; i < N; i++) v[k++] = 2 * h * obj_factor;
      return v;
    },
  },
  { print_level: 0, linear_solver: "mumps" }
);

const elapsed = performance.now() - t0;
console.log(`status=${result.status} obj=${result.objective.toFixed(6)} time=${elapsed.toFixed(0)}ms`);
