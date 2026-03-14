#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <emscripten.h>
#include "IpStdCInterface.h"

// Store callbacks as integer table indices to work around MEMORY64
// call_indirect bug (i64 function pointer not truncated to i32 table index)
static int32_t cb_f=0, cb_gf=0, cb_g=0, cb_jac=0, cb_h=0;

// Use EM_ASM to call through table indices properly
// Or: use inline wasm to do call_indirect with i32 index

typedef double (*FnF)(int, double*);
typedef void (*FnGF)(int, double*, double*);
typedef void (*FnG)(int, double*, int, double*);
typedef void (*FnJac)(int, double*, int, int, int*, int*, double*, int);
typedef void (*FnH)(int, double*, double, int, double*, int, int*, int*, double*, int);

// Workaround: cast i32 table index to function pointer and call
// The compiler SHOULD truncate, but doesn't. Force it:
#define CALL_F(idx, ...) ((FnF)(intptr_t)(int32_t)(idx))(__VA_ARGS__)
#define CALL_GF(idx, ...) ((FnGF)(intptr_t)(int32_t)(idx))(__VA_ARGS__)
#define CALL_G(idx, ...) ((FnG)(intptr_t)(int32_t)(idx))(__VA_ARGS__)
#define CALL_JAC(idx, ...) ((FnJac)(intptr_t)(int32_t)(idx))(__VA_ARGS__)
#define CALL_H(idx, ...) ((FnH)(intptr_t)(int32_t)(idx))(__VA_ARGS__)

static bool c_eval_f(int n, double* x, bool new_x, double* obj, void* ud) {
    *obj = CALL_F(cb_f, n, x);
    return true;
}
static bool c_eval_g(int n, double* x, bool new_x, int m, double* g, void* ud) {
    CALL_G(cb_g, n, x, m, g);
    return true;
}
static bool c_eval_grad_f(int n, double* x, bool new_x, double* grad, void* ud) {
    CALL_GF(cb_gf, n, x, grad);
    return true;
}
static bool c_eval_jac_g(int n, double* x, bool new_x, int m, int nele, int* iRow, int* jCol, double* vals, void* ud) {
    CALL_JAC(cb_jac, n, x, m, nele, iRow, jCol, vals, vals == NULL ? 1 : 0);
    return true;
}
static bool c_eval_h(int n, double* x, bool new_x, double obj_factor, int m, double* lambda, bool new_lambda, int nele, int* iRow, int* jCol, double* vals, void* ud) {
    CALL_H(cb_h, n, x, obj_factor, m, lambda, nele, iRow, jCol, vals, vals == NULL ? 1 : 0);
    return true;
}

EMSCRIPTEN_KEEPALIVE void set_callbacks(int32_t f, int32_t gf, int32_t g, int32_t jac, int32_t h) {
    cb_f=f; cb_gf=gf; cb_g=g; cb_jac=jac; cb_h=h;
}

EMSCRIPTEN_KEEPALIVE IpoptProblem ipopt_create(int n, double* x_L, double* x_U, int m, double* g_L, double* g_U, int nele_jac, int nele_hess) {
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
