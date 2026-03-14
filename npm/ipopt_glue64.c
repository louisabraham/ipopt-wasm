#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <emscripten.h>
#include <emscripten/em_js.h>
#include "IpStdCInterface.h"

// EM_JS callbacks — compiled as wasm imports, bypassing the MEMORY64
// call_indirect bug that blocks addFunction-based callbacks.
// JS callbacks are stored on Module._userCallbacks before solving.

EM_JS(double, js_eval_f, (int n, double* x_ptr), {
    var p = Number(x_ptr) / 8;
    var x = new Float64Array(n);
    for (var i = 0; i < n; i++) x[i] = HEAPF64[p + i];
    return Module._userCallbacks.eval_f(x);
});

EM_JS(void, js_eval_grad_f, (int n, double* x_ptr, double* grad_ptr), {
    var p = Number(x_ptr) / 8;
    var x = new Float64Array(n);
    for (var i = 0; i < n; i++) x[i] = HEAPF64[p + i];
    var result = Module._userCallbacks.eval_grad_f(x);
    var g = Number(grad_ptr) / 8;
    for (var i = 0; i < n; i++) HEAPF64[g + i] = result[i];
});

EM_JS(void, js_eval_g, (int n, double* x_ptr, int m, double* g_ptr), {
    var p = Number(x_ptr) / 8;
    var x = new Float64Array(n);
    for (var i = 0; i < n; i++) x[i] = HEAPF64[p + i];
    var result = Module._userCallbacks.eval_g(x);
    var g = Number(g_ptr) / 8;
    for (var i = 0; i < m; i++) HEAPF64[g + i] = result[i];
});

EM_JS(void, js_eval_jac_g, (int n, double* x_ptr, int m, int nele,
                             int* iRow_ptr, int* jCol_ptr, double* vals_ptr,
                             int structure), {
    if (structure) {
        var s = Module._userCallbacks.eval_jac_g(null, true);
        var r = Number(iRow_ptr) / 4;
        var c = Number(jCol_ptr) / 4;
        for (var i = 0; i < nele; i++) {
            HEAP32[r + i] = s.iRow[i];
            HEAP32[c + i] = s.jCol[i];
        }
    } else {
        var p = Number(x_ptr) / 8;
        var x = new Float64Array(n);
        for (var i = 0; i < n; i++) x[i] = HEAPF64[p + i];
        var v = Module._userCallbacks.eval_jac_g(x, false);
        var pv = Number(vals_ptr) / 8;
        for (var i = 0; i < nele; i++) HEAPF64[pv + i] = v[i];
    }
});

EM_JS(void, js_eval_h, (int n, double* x_ptr, double obj_factor, int m,
                         double* lambda_ptr, int nele, int* iRow_ptr,
                         int* jCol_ptr, double* vals_ptr, int structure), {
    if (structure) {
        var s = Module._userCallbacks.eval_h(null, 0, null, true);
        var r = Number(iRow_ptr) / 4;
        var c = Number(jCol_ptr) / 4;
        for (var i = 0; i < nele; i++) {
            HEAP32[r + i] = s.iRow[i];
            HEAP32[c + i] = s.jCol[i];
        }
    } else {
        var p = Number(x_ptr) / 8;
        var x = new Float64Array(n);
        for (var i = 0; i < n; i++) x[i] = HEAPF64[p + i];
        var pl = Number(lambda_ptr) / 8;
        var lam = new Float64Array(m);
        for (var i = 0; i < m; i++) lam[i] = HEAPF64[pl + i];
        var v = Module._userCallbacks.eval_h(x, obj_factor, lam, false);
        var pv = Number(vals_ptr) / 8;
        for (var i = 0; i < nele; i++) HEAPF64[pv + i] = v[i];
    }
});

// C callback wrappers matching Ipopt's expected signatures.
// These are called by Ipopt via call_indirect with correct ABI,
// and they call back to JS via the EM_JS imports above.
static Bool c_eval_f(Index n, Number* x, Bool new_x, Number* obj, UserDataPtr ud) {
    *obj = js_eval_f(n, x);
    return TRUE;
}
static Bool c_eval_g(Index n, Number* x, Bool new_x, Index m, Number* g, UserDataPtr ud) {
    js_eval_g(n, x, m, g);
    return TRUE;
}
static Bool c_eval_grad_f(Index n, Number* x, Bool new_x, Number* grad, UserDataPtr ud) {
    js_eval_grad_f(n, x, grad);
    return TRUE;
}
static Bool c_eval_jac_g(Index n, Number* x, Bool new_x, Index m, Int nele,
                          Index* iRow, Index* jCol, Number* vals, UserDataPtr ud) {
    js_eval_jac_g(n, x, m, nele, iRow, jCol, vals, vals == NULL ? 1 : 0);
    return TRUE;
}
static Bool c_eval_h(Index n, Number* x, Bool new_x, Number obj_factor,
                      Index m, Number* lambda, Bool new_lambda,
                      Int nele, Index* iRow, Index* jCol, Number* vals, UserDataPtr ud) {
    js_eval_h(n, x, obj_factor, m, lambda, nele, iRow, jCol, vals, vals == NULL ? 1 : 0);
    return TRUE;
}

EMSCRIPTEN_KEEPALIVE IpoptProblem ipopt_create(int n, double* x_L, double* x_U,
    int m, double* g_L, double* g_U, int nele_jac, int nele_hess) {
    return CreateIpoptProblem(n, x_L, x_U, m, g_L, g_U, nele_jac, nele_hess, 0,
        c_eval_f, c_eval_g, c_eval_grad_f, c_eval_jac_g, c_eval_h);
}

EMSCRIPTEN_KEEPALIVE void ipopt_free(IpoptProblem p) { FreeIpoptProblem(p); }
EMSCRIPTEN_KEEPALIVE int ipopt_str_option(IpoptProblem p, const char* k, const char* v) { return AddIpoptStrOption(p, k, v); }
EMSCRIPTEN_KEEPALIVE int ipopt_num_option(IpoptProblem p, const char* k, double v) { return AddIpoptNumOption(p, k, v); }
EMSCRIPTEN_KEEPALIVE int ipopt_int_option(IpoptProblem p, const char* k, int v) { return AddIpoptIntOption(p, k, v); }
EMSCRIPTEN_KEEPALIVE int ipopt_solve(IpoptProblem p, double* x, double* g, double* obj, double* mg, double* mxl, double* mxu) {
    return IpoptSolve(p, x, g, obj, mg, mxl, mxu, NULL);
}
