// wasm64 (MEMORY64) variant — same API but no 4GB memory limit
import createIpoptModule from "./ipopt64.mjs";

let _module = null;
async function getModule() {
  if (!_module) _module = await createIpoptModule();
  return _module;
}

export async function solve(problem, options = {}) {
  const M = await getModule();
  const { n, m, x0, xl, xu, gl, gu, nele_jac, nele_hess } = problem;

  // In MEMORY64: _malloc returns Number (Emscripten wraps it)
  // But raw wasm exports expect BigInt for pointer (i64) args
  const B = (v) => BigInt(v);  // Number → BigInt for C pointer args

  const x_L = M._malloc(n * 8), x_U = M._malloc(n * 8);
  const g_L = M._malloc(m * 8), g_U = M._malloc(m * 8);
  const x = M._malloc(n * 8), g = M._malloc(m * 8);
  const obj_val = M._malloc(8);
  const mult_g = M._malloc(m * 8);
  const mxL = M._malloc(n * 8), mxU = M._malloc(n * 8);

  const H = M.HEAPF64;
  for (let i = 0; i < n; i++) {
    H[x_L / 8 + i] = xl[i];
    H[x_U / 8 + i] = xu[i];
    H[x / 8 + i] = x0[i];
  }
  for (let i = 0; i < m; i++) {
    H[g_L / 8 + i] = gl[i];
    H[g_U / 8 + i] = gu[i];
  }

  const readF64 = (ptr, len) => {
    const p = ptr / 8;
    const o = new Float64Array(len);
    for (let i = 0; i < len; i++) o[i] = H[p + i];
    return o;
  };

  // Store JS callbacks on Module for the EM_JS bridge in ipopt_glue64.c
  M._userCallbacks = {
    eval_f: problem.eval_f,
    eval_grad_f: problem.eval_grad_f,
    eval_g: problem.eval_g,
    eval_jac_g: problem.eval_jac_g,
    eval_h: problem.eval_h,
  };

  // Create Ipopt problem — C glue uses EM_JS to call back to Module._userCallbacks
  const ipopt = M._ipopt_create(n, B(x_L), B(x_U), m, B(g_L), B(g_U), nele_jac, nele_hess);

  // Set options
  for (const [key, val] of Object.entries(options)) {
    const kLen = key.length * 4 + 1;
    const kp = M._malloc(kLen);
    M.stringToUTF8(key, kp, kLen);
    if (typeof val === "string") {
      const vLen = val.length * 4 + 1;
      const vp = M._malloc(vLen);
      M.stringToUTF8(val, vp, vLen);
      M._ipopt_str_option(ipopt, B(kp), B(vp));
      M._free(vp);
    } else if (Number.isInteger(val)) {
      M._ipopt_int_option(ipopt, B(kp), val);
    } else {
      M._ipopt_num_option(ipopt, B(kp), val);
    }
    M._free(kp);
  }

  const status = M._ipopt_solve(ipopt, B(x), B(g), B(obj_val), B(mult_g), B(mxL), B(mxU));

  // Re-read HEAPF64 after solve — memory may have grown, invalidating the old view
  const H2 = M.HEAPF64;
  const readF64After = (ptr, len) => {
    const p = ptr / 8;
    const o = new Float64Array(len);
    for (let i = 0; i < len; i++) o[i] = H2[p + i];
    return o;
  };

  const result = {
    x: readF64After(x, n),
    objective: H2[obj_val / 8],
    status: Number(status),
    constraints: readF64After(g, m),
    mult_g: readF64After(mult_g, m),
    mult_x_L: readF64After(mxL, n),
    mult_x_U: readF64After(mxU, n),
  };

  M._ipopt_free(ipopt);
  delete M._userCallbacks;
  for (const p of [x_L, x_U, g_L, g_U, x, g, obj_val, mult_g, mxL, mxU]) M._free(p);

  return result;
}

export default solve;
