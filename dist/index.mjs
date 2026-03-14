/**
 * ipopt-wasm - Ipopt nonlinear optimizer for JavaScript
 *
 * Works in Node.js and browsers via WebAssembly.
 */

import createIpoptModule from "./ipopt.mjs";

let _module = null;

async function getModule() {
  if (!_module) {
    _module = await createIpoptModule();
  }
  return _module;
}

/**
 * Solve a nonlinear optimization problem using Ipopt.
 *
 * @param {object} problem - Problem definition
 * @param {number} problem.n - Number of variables
 * @param {number} problem.m - Number of constraints
 * @param {Float64Array} problem.x0 - Initial guess (length n)
 * @param {Float64Array} problem.xl - Variable lower bounds (length n)
 * @param {Float64Array} problem.xu - Variable upper bounds (length n)
 * @param {Float64Array} problem.gl - Constraint lower bounds (length m)
 * @param {Float64Array} problem.gu - Constraint upper bounds (length m)
 * @param {number} problem.nele_jac - Number of nonzeros in constraint Jacobian
 * @param {number} problem.nele_hess - Number of nonzeros in Hessian of Lagrangian
 * @param {function} problem.eval_f - (x: Float64Array) => number
 * @param {function} problem.eval_grad_f - (x: Float64Array) => Float64Array
 * @param {function} problem.eval_g - (x: Float64Array) => Float64Array
 * @param {function} problem.eval_jac_g - (x: Float64Array, structure: boolean) => {iRow: Int32Array, jCol: Int32Array} | Float64Array
 * @param {function} problem.eval_h - (x: Float64Array, obj_factor: number, lambda: Float64Array, structure: boolean) => {iRow: Int32Array, jCol: Int32Array} | Float64Array
 * @param {object} [options] - Ipopt options (e.g. {print_level: 5, tol: 1e-8, linear_solver: "mumps"})
 * @returns {Promise<object>} Solution: {x, objective, status, constraints, mult_g, mult_x_L, mult_x_U}
 */
export async function solve(problem, options = {}) {
  const M = await getModule();
  const { n, m, x0, xl, xu, gl, gu, nele_jac, nele_hess } = problem;

  // Allocate wasm memory for arrays
  const x_L = M._malloc(n * 8);
  const x_U = M._malloc(n * 8);
  const g_L = M._malloc(m * 8);
  const g_U = M._malloc(m * 8);
  const x = M._malloc(n * 8);
  const g = M._malloc(m * 8);
  const obj_val = M._malloc(8);
  const mult_g = M._malloc(m * 8);
  const mult_x_L_ptr = M._malloc(n * 8);
  const mult_x_U_ptr = M._malloc(n * 8);

  // Copy input arrays to wasm heap
  const H = M.HEAPF64;
  for (let i = 0; i < n; i++) {
    H[(x_L >> 3) + i] = xl[i];
    H[(x_U >> 3) + i] = xu[i];
    H[(x >> 3) + i] = x0[i];
  }
  for (let i = 0; i < m; i++) {
    H[(g_L >> 3) + i] = gl[i];
    H[(g_U >> 3) + i] = gu[i];
  }

  // Helpers: use M.HEAPF64/M.HEAP32 live (not cached) to survive memory growth
  const readF64 = (ptr, len) => {
    const out = new Float64Array(len);
    const h = M.HEAPF64;
    for (let i = 0; i < len; i++) out[i] = h[(ptr >> 3) + i];
    return out;
  };

  // Create callback wrappers
  // eval_f: (n, x_ptr, new_x, obj_ptr, user_data) => bool
  const eval_f_cb = M.addFunction((n_arg, x_ptr, new_x, obj_ptr, ud) => {
    const xArr = readF64(x_ptr, n);
    const val = problem.eval_f(xArr);
    M.HEAPF64[obj_ptr >> 3] = val;
    return 1;
  }, "iiiiii");

  // eval_g: (n, x_ptr, new_x, m, g_ptr, user_data) => bool
  const eval_g_cb = M.addFunction((n_arg, x_ptr, new_x, m_arg, g_ptr, ud) => {
    const xArr = readF64(x_ptr, n);
    const gArr = problem.eval_g(xArr);
    const h = M.HEAPF64;
    for (let i = 0; i < m; i++) h[(g_ptr >> 3) + i] = gArr[i];
    return 1;
  }, "iiiiiii");

  // eval_grad_f: (n, x_ptr, new_x, grad_ptr, user_data) => bool
  const eval_grad_f_cb = M.addFunction((n_arg, x_ptr, new_x, grad_ptr, ud) => {
    const xArr = readF64(x_ptr, n);
    const gfArr = problem.eval_grad_f(xArr);
    const h = M.HEAPF64;
    for (let i = 0; i < n; i++) h[(grad_ptr >> 3) + i] = gfArr[i];
    return 1;
  }, "iiiiii");

  // eval_jac_g: (n, x_ptr, new_x, m, nele_jac, iRow_ptr, jCol_ptr, values_ptr, user_data) => bool
  const eval_jac_g_cb = M.addFunction((n_arg, x_ptr, new_x, m_arg, nele, iRow_ptr, jCol_ptr, vals_ptr, ud) => {
    if (vals_ptr === 0) {
      const s = problem.eval_jac_g(null, true);
      for (let i = 0; i < nele_jac; i++) {
        M.HEAP32[(iRow_ptr >> 2) + i] = s.iRow[i];
        M.HEAP32[(jCol_ptr >> 2) + i] = s.jCol[i];
      }
    } else {
      const xArr = readF64(x_ptr, n);
      const v = problem.eval_jac_g(xArr, false);
      const h = M.HEAPF64;
      for (let i = 0; i < nele_jac; i++) h[(vals_ptr >> 3) + i] = v[i];
    }
    return 1;
  }, "iiiiiiiiii");

  // eval_h: (n, x_ptr, new_x, obj_factor, m, lambda_ptr, new_lambda, nele_hess, iRow_ptr, jCol_ptr, values_ptr, user_data) => bool
  const eval_h_cb = M.addFunction((n_arg, x_ptr, new_x, obj_factor, m_arg, lambda_ptr, new_lambda, nele, iRow_ptr, jCol_ptr, vals_ptr, ud) => {
    if (vals_ptr === 0) {
      const s = problem.eval_h(null, 0, null, true);
      for (let i = 0; i < nele_hess; i++) {
        M.HEAP32[(iRow_ptr >> 2) + i] = s.iRow[i];
        M.HEAP32[(jCol_ptr >> 2) + i] = s.jCol[i];
      }
    } else {
      const xArr = readF64(x_ptr, n);
      const lambdaArr = readF64(lambda_ptr, m);
      const v = problem.eval_h(xArr, obj_factor, lambdaArr, false);
      const h = M.HEAPF64;
      for (let i = 0; i < nele_hess; i++) h[(vals_ptr >> 3) + i] = v[i];
    }
    return 1;
  }, "iiiidiiiiiiii");

  // Create Ipopt problem
  const ipopt = M._ipopt_create(n, x_L, x_U, m, g_L, g_U, nele_jac, nele_hess,
    eval_f_cb, eval_g_cb, eval_grad_f_cb, eval_jac_g_cb, eval_h_cb);

  // Set options
  for (const [key, val] of Object.entries(options)) {
    const keyPtr = M._malloc(key.length + 1);
    M.stringToUTF8(key, keyPtr, key.length + 1);
    if (typeof val === "string") {
      const valPtr = M._malloc(val.length + 1);
      M.stringToUTF8(val, valPtr, val.length + 1);
      M._ipopt_str_option(ipopt, keyPtr, valPtr);
      M._free(valPtr);
    } else if (Number.isInteger(val)) {
      M._ipopt_int_option(ipopt, keyPtr, val);
    } else {
      M._ipopt_num_option(ipopt, keyPtr, val);
    }
    M._free(keyPtr);
  }

  // Solve
  const status = M._ipopt_solve(ipopt, x, g, obj_val, mult_g, mult_x_L_ptr, mult_x_U_ptr);

  // Re-read heap views after solve — memory may have grown, invalidating old views
  const H2 = M.HEAPF64;
  const readF64After = (ptr, len) => {
    const out = new Float64Array(len);
    for (let i = 0; i < len; i++) out[i] = H2[(ptr >> 3) + i];
    return out;
  };

  // Read results
  const result = {
    x: readF64After(x, n),
    objective: H2[obj_val >> 3],
    status,
    constraints: readF64After(g, m),
    mult_g: readF64After(mult_g, m),
    mult_x_L: readF64After(mult_x_L_ptr, n),
    mult_x_U: readF64After(mult_x_U_ptr, n),
  };

  // Cleanup
  M._ipopt_free(ipopt);
  M.removeFunction(eval_f_cb);
  M.removeFunction(eval_g_cb);
  M.removeFunction(eval_grad_f_cb);
  M.removeFunction(eval_jac_g_cb);
  M.removeFunction(eval_h_cb);
  M._free(x_L); M._free(x_U); M._free(g_L); M._free(g_U);
  M._free(x); M._free(g); M._free(obj_val);
  M._free(mult_g); M._free(mult_x_L_ptr); M._free(mult_x_U_ptr);

  return result;
}

export default solve;
