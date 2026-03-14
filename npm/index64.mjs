// wasm64 (MEMORY64) variant — same API but no 4GB memory limit
// Requires Node.js 20+ with BigInt/MEMORY64 support
import createIpoptModule from "./ipopt64.mjs";

let _module = null;
async function getModule() {
  if (!_module) _module = await createIpoptModule();
  return _module;
}

// In MEMORY64 mode:
// - _malloc returns BigInt (i64 pointer)
// - HEAPF64/HEAP32 indexed by byte offset (Number)
// - addFunction signature: 'p' for pointer, 'i' for i32, 'd' for f64
// - C functions expecting pointers need BigInt args

export async function solve(problem, options = {}) {
  const M = await getModule();
  const { n, m, x0, xl, xu, gl, gu, nele_jac, nele_hess } = problem;

  const P = (v) => Number(v);        // BigInt ptr → Number for heap indexing
  const B = (v) => BigInt(v);         // Number → BigInt for C pointer args

  const x_L = P(M._malloc(n*8)), x_U = P(M._malloc(n*8));
  const g_L = P(M._malloc(m*8)), g_U = P(M._malloc(m*8));
  const x = P(M._malloc(n*8)), g = P(M._malloc(m*8));
  const obj_val = P(M._malloc(8));
  const mult_g = P(M._malloc(m*8));
  const mxL = P(M._malloc(n*8)), mxU = P(M._malloc(n*8));

  const H = M.HEAPF64;
  for (let i=0;i<n;i++) { H[(x_L>>3)+i]=xl[i]; H[(x_U>>3)+i]=xu[i]; H[(x>>3)+i]=x0[i]; }
  for (let i=0;i<m;i++) { H[(g_L>>3)+i]=gl[i]; H[(g_U>>3)+i]=gu[i]; }

  const readF64 = (ptr,len) => {
    const p = typeof ptr==='bigint' ? Number(ptr) : ptr;
    const o = new Float64Array(len);
    for (let i=0;i<len;i++) o[i] = H[(p>>3)+i];
    return o;
  };

  // Signature format: first char = return type, rest = param types
  // 'p'=pointer(i64), 'i'=i32, 'd'=f64
  // eval_f: bool(int n, double* x, bool new_x, double* obj, void* ud)
  const eval_f_cb = M.addFunction((n_,xp,nx,op,ud) => {
    H[P(op)>>3] = problem.eval_f(readF64(xp,n)); return 1;
  }, "iipipp");

  // eval_g: bool(int n, double* x, bool new_x, int m, double* g, void* ud)
  const eval_g_cb = M.addFunction((n_,xp,nx,m_,gp,ud) => {
    const a=problem.eval_g(readF64(xp,n)), p=P(gp);
    for(let i=0;i<m;i++) H[(p>>3)+i]=a[i]; return 1;
  }, "iipiipp");

  // eval_grad_f: bool(int n, double* x, bool new_x, double* grad, void* ud)
  const eval_grad_f_cb = M.addFunction((n_,xp,nx,gp,ud) => {
    const a=problem.eval_grad_f(readF64(xp,n)), p=P(gp);
    for(let i=0;i<n;i++) H[(p>>3)+i]=a[i]; return 1;
  }, "iipipp");

  // eval_jac_g: bool(int n, double* x, bool new_x, int m, int nele, int* iR, int* jC, double* vals, void* ud)
  const eval_jac_g_cb = M.addFunction((n_,xp,nx,m_,ne,iR,jC,vp,ud) => {
    if(P(vp)===0) {
      const s=problem.eval_jac_g(null,true), r=P(iR), c=P(jC);
      for(let i=0;i<nele_jac;i++){M.HEAP32[(r>>2)+i]=s.iRow[i];M.HEAP32[(c>>2)+i]=s.jCol[i];}
    } else {
      const v=problem.eval_jac_g(readF64(xp,n),false), p=P(vp);
      for(let i=0;i<nele_jac;i++) H[(p>>3)+i]=v[i];
    }
    return 1;
  }, "iipiippppp");

  // eval_h: bool(int n, double* x, bool new_x, double obj_factor, int m, double* lambda, bool new_l, int nele, int* iR, int* jC, double* vals, void* ud)
  const eval_h_cb = M.addFunction((n_,xp,nx,of_,m_,lp,nl,ne,iR,jC,vp,ud) => {
    if(P(vp)===0) {
      const s=problem.eval_h(null,0,null,true), r=P(iR), c=P(jC);
      for(let i=0;i<nele_hess;i++){M.HEAP32[(r>>2)+i]=s.iRow[i];M.HEAP32[(c>>2)+i]=s.jCol[i];}
    } else {
      const v=problem.eval_h(readF64(xp,n),of_,readF64(lp,m),false), p=P(vp);
      for(let i=0;i<nele_hess;i++) H[(p>>3)+i]=v[i];
    }
    return 1;
  }, "iipidipiippp");

  const ipopt = M._ipopt_create(
    n,B(x_L),B(x_U),m,B(g_L),B(g_U),nele_jac,nele_hess,
    B(eval_f_cb),B(eval_g_cb),B(eval_grad_f_cb),B(eval_jac_g_cb),B(eval_h_cb));

  for(const [key,val] of Object.entries(options)) {
    const kp=P(M._malloc(key.length+1)); M.stringToUTF8(key,kp,key.length+1);
    if(typeof val==="string") {
      const vp=P(M._malloc(val.length+1)); M.stringToUTF8(val,vp,val.length+1);
      M._ipopt_str_option(ipopt,B(kp),B(vp)); M._free(B(vp));
    } else if(Number.isInteger(val)) { M._ipopt_int_option(ipopt,B(kp),val);
    } else { M._ipopt_num_option(ipopt,B(kp),val); }
    M._free(B(kp));
  }

  const status = Number(M._ipopt_solve(ipopt,B(x),B(g),B(obj_val),B(mult_g),B(mxL),B(mxU)));

  const result = {
    x:readF64(x,n), objective:H[obj_val>>3], status,
    constraints:readF64(g,m), mult_g:readF64(mult_g,m),
    mult_x_L:readF64(mxL,n), mult_x_U:readF64(mxU,n),
  };

  M._ipopt_free(ipopt);
  M.removeFunction(eval_f_cb); M.removeFunction(eval_g_cb);
  M.removeFunction(eval_grad_f_cb); M.removeFunction(eval_jac_g_cb);
  M.removeFunction(eval_h_cb);
  for(const p of [x_L,x_U,g_L,g_U,x,g,obj_val,mult_g,mxL,mxU]) M._free(B(p));

  return result;
}

export default solve;
