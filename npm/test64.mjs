// Test: solve HS071 with objective/constraints defined entirely in JavaScript (wasm64)
import { solve } from "./index64.mjs";

const result = await solve(
  {
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

    eval_grad_f: (x) =>
      new Float64Array([
        x[3] * (2 * x[0] + x[1] + x[2]),
        x[0] * x[3],
        x[0] * x[3] + 1,
        x[0] * (x[0] + x[1] + x[2]),
      ]),

    eval_g: (x) =>
      new Float64Array([
        x[0] * x[1] * x[2] * x[3],
        x[0] ** 2 + x[1] ** 2 + x[2] ** 2 + x[3] ** 2,
      ]),

    eval_jac_g: (x, structure) => {
      if (structure)
        return {
          iRow: new Int32Array([0, 0, 0, 0, 1, 1, 1, 1]),
          jCol: new Int32Array([0, 1, 2, 3, 0, 1, 2, 3]),
        };
      return new Float64Array([
        x[1] * x[2] * x[3],
        x[0] * x[2] * x[3],
        x[0] * x[1] * x[3],
        x[0] * x[1] * x[2],
        2 * x[0],
        2 * x[1],
        2 * x[2],
        2 * x[3],
      ]);
    },

    eval_h: (x, obj_factor, lambda, structure) => {
      if (structure) {
        const iRow = [], jCol = [];
        for (let row = 0; row < 4; row++)
          for (let col = 0; col <= row; col++) {
            iRow.push(row);
            jCol.push(col);
          }
        return { iRow: new Int32Array(iRow), jCol: new Int32Array(jCol) };
      }
      const v = new Float64Array(10);
      v[0] = obj_factor * 2 * x[3] + lambda[1] * 2;
      v[1] = obj_factor * x[3] + lambda[0] * x[2] * x[3];
      v[2] = lambda[1] * 2;
      v[3] = obj_factor * x[3] + lambda[0] * x[1] * x[3];
      v[4] = lambda[0] * x[0] * x[3];
      v[5] = lambda[1] * 2;
      v[6] = obj_factor * (2 * x[0] + x[1] + x[2]) + lambda[0] * x[1] * x[2];
      v[7] = obj_factor * x[0] + lambda[0] * x[0] * x[2];
      v[8] = obj_factor * x[0] + lambda[0] * x[0] * x[1];
      v[9] = lambda[1] * 2;
      return v;
    },
  },
  { print_level: 5, linear_solver: "mumps" }
);

console.log("\n=== Result ===");
console.log("x:", Array.from(result.x).map((v) => v.toFixed(6)));
console.log("objective:", result.objective.toFixed(6));
console.log("status:", result.status, result.status === 0 ? "(optimal)" : "(FAILED)");

if (result.status !== 0) process.exit(1);
if (Math.abs(result.objective - 17.014017) > 0.001) {
  console.error("Wrong objective!");
  process.exit(1);
}
console.log("PASS");
