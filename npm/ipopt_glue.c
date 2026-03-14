#include <stdlib.h>
#include <emscripten.h>
#include "IpStdCInterface.h"

EMSCRIPTEN_KEEPALIVE
IpoptProblem ipopt_create(
    int n, double* x_L, double* x_U,
    int m, double* g_L, double* g_U,
    int nele_jac, int nele_hess,
    Eval_F_CB eval_f, Eval_G_CB eval_g, Eval_Grad_F_CB eval_grad_f,
    Eval_Jac_G_CB eval_jac_g, Eval_H_CB eval_h)
{
    return CreateIpoptProblem(n, x_L, x_U, m, g_L, g_U,
        nele_jac, nele_hess, 0,
        eval_f, eval_g, eval_grad_f, eval_jac_g, eval_h);
}

EMSCRIPTEN_KEEPALIVE void ipopt_free(IpoptProblem p) { FreeIpoptProblem(p); }

EMSCRIPTEN_KEEPALIVE int ipopt_str_option(IpoptProblem p, const char* k, const char* v) {
    return AddIpoptStrOption(p, k, v);
}
EMSCRIPTEN_KEEPALIVE int ipopt_num_option(IpoptProblem p, const char* k, double v) {
    return AddIpoptNumOption(p, k, v);
}
EMSCRIPTEN_KEEPALIVE int ipopt_int_option(IpoptProblem p, const char* k, int v) {
    return AddIpoptIntOption(p, k, v);
}

EMSCRIPTEN_KEEPALIVE
int ipopt_solve(IpoptProblem p, double* x, double* g,
                double* obj_val, double* mult_g,
                double* mult_x_L, double* mult_x_U) {
    return IpoptSolve(p, x, g, obj_val, mult_g, mult_x_L, mult_x_U, NULL);
}
