import { solve } from "./index64.mjs";

const N = parseInt(process.argv[2] || "80000");
const h = 1.0 / N;
const n = 2 * N + 1;
const m = N + 1;

console.log(`Optimal control: N=${N}, n=${n} vars, m=${m} constraints (wasm64)`);

const t0 = performance.now();
const result = await solve({
  n, m,
  x0: Float64Array.from({ length: n }, (_, i) => i <= N ? 1 - i / N : 0),
  xl: Float64Array.from({ length: n }, (_, i) => i <= N ? (i === N ? 0 : -1e19) : -2),
  xu: Float64Array.from({ length: n }, (_, i) => i <= N ? (i === N ? 0 : 1e19) : 2),
  gl: new Float64Array(m),
  gu: new Float64Array(m),
  nele_jac: 1 + N * 3,
  nele_hess: N + N,
  eval_f(x) { let o=0; for(let i=0;i<N;i++) o+=h*x[N+1+i]**2; return o; },
  eval_grad_f(x) { const g=new Float64Array(n); for(let i=0;i<N;i++) g[N+1+i]=2*h*x[N+1+i]; return g; },
  eval_g(x) { const g=new Float64Array(m); g[0]=x[0]-1; for(let i=0;i<N;i++) g[1+i]=x[i+1]-x[i]-h*(x[i]*x[i]+x[N+1+i]); return g; },
  eval_jac_g(x,s) { if(s){const r=new Int32Array(1+N*3),c=new Int32Array(1+N*3);let k=0;r[k]=0;c[k]=0;k++;for(let i=0;i<N;i++){r[k]=1+i;c[k]=i;k++;r[k]=1+i;c[k]=i+1;k++;r[k]=1+i;c[k]=N+1+i;k++;}return{iRow:r,jCol:c};}const v=new Float64Array(1+N*3);let k=0;v[k++]=1;for(let i=0;i<N;i++){v[k++]=-1-2*h*x[i];v[k++]=1;v[k++]=-h;}return v; },
  eval_h(x,of,l,s) { if(s){const r=new Int32Array(2*N),c=new Int32Array(2*N);let k=0;for(let i=0;i<N;i++){r[k]=i;c[k]=i;k++;}for(let i=0;i<N;i++){r[k]=N+1+i;c[k]=N+1+i;k++;}return{iRow:r,jCol:c};}const v=new Float64Array(2*N);let k=0;for(let i=0;i<N;i++) v[k++]=-2*h*l[1+i];for(let i=0;i<N;i++) v[k++]=2*h*of;return v; },
}, { print_level: 0, linear_solver: "mumps" });

const elapsed = performance.now() - t0;
console.log(`status=${result.status} obj=${result.objective.toFixed(6)} time=${elapsed.toFixed(0)}ms`);
