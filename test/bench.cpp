// Benchmark: discretized optimal control problem
// min sum_{i=0}^{N-1} u_i^2
// s.t. x_{i+1} = x_i + h*(x_i^2 + u_i), i=0..N-1
//      x_0 = 1 (initial condition)
//      x_N = 0 (terminal condition, via constraint)
//      -2 <= u_i <= 2

#include "IpIpoptApplication.hpp"
#include "IpTNLP.hpp"
#include <cstdio>
#include <cmath>
#include <cstdlib>
#include <chrono>

using namespace Ipopt;

class OCP : public TNLP {
  int N;
  double h;
public:
  OCP(int N) : N(N), h(1.0/N) {}

  // Variables: x_0..x_N, u_0..u_{N-1} => n = 2*N+1
  // Constraints: dynamics x_{i+1}=x_i+h*(x_i^2+u_i) for i=0..N-1, plus x_0=1 => m = N+1

  bool get_nlp_info(Index& n, Index& m, Index& nnz_jac_g, Index& nnz_h_lag, IndexStyleEnum& index_style) override {
    n = 2*N+1;  // x_0..x_N, u_0..u_{N-1}
    m = N+1;    // N dynamics + 1 initial condition
    nnz_jac_g = 1 + N*3; // initial: 1, dynamics: 3 per (x_i, x_{i+1}, u_i)
    nnz_h_lag = N + N;   // obj hessian: N diagonal (u_i), constraint hessian: N diagonal (x_i)
    index_style = C_STYLE;
    return true;
  }

  bool get_bounds_info(Index n, Number* x_l, Number* x_u, Index m, Number* g_l, Number* g_u) override {
    for (int i = 0; i <= N; i++) { x_l[i] = -1e19; x_u[i] = 1e19; } // x unbounded
    // Terminal constraint: x_N = 0
    x_l[N] = 0; x_u[N] = 0;
    for (int i = 0; i < N; i++) { x_l[N+1+i] = -2; x_u[N+1+i] = 2; } // u bounded
    // Constraints: all equality (dynamics + initial)
    for (int i = 0; i < m; i++) { g_l[i] = 0; g_u[i] = 0; }
    return true;
  }

  bool get_starting_point(Index n, bool init_x, Number* x, bool, Number*, Number*, Index, bool, Number*) override {
    for (int i = 0; i <= N; i++) x[i] = 1.0 - (double)i/N; // linear interp
    for (int i = 0; i < N; i++) x[N+1+i] = 0;
    return true;
  }

  bool eval_f(Index n, const Number* x, bool, Number& obj) override {
    obj = 0;
    for (int i = 0; i < N; i++) obj += h * x[N+1+i]*x[N+1+i];
    return true;
  }

  bool eval_grad_f(Index n, const Number* x, bool, Number* grad) override {
    for (int i = 0; i < n; i++) grad[i] = 0;
    for (int i = 0; i < N; i++) grad[N+1+i] = 2*h*x[N+1+i];
    return true;
  }

  bool eval_g(Index n, const Number* x, bool, Index m, Number* g) override {
    g[0] = x[0] - 1.0; // x_0 = 1
    for (int i = 0; i < N; i++)
      g[1+i] = x[i+1] - x[i] - h*(x[i]*x[i] + x[N+1+i]);
    return true;
  }

  bool eval_jac_g(Index n, const Number* x, bool, Index m, Index nele, Index* iRow, Index* jCol, Number* v) override {
    if (!v) {
      int k = 0;
      iRow[k]=0; jCol[k]=0; k++; // dx_0
      for (int i = 0; i < N; i++) {
        iRow[k]=1+i; jCol[k]=i;     k++; // dx_i
        iRow[k]=1+i; jCol[k]=i+1;   k++; // dx_{i+1}
        iRow[k]=1+i; jCol[k]=N+1+i; k++; // du_i
      }
    } else {
      int k = 0;
      v[k++] = 1.0;
      for (int i = 0; i < N; i++) {
        v[k++] = -1.0 - 2*h*x[i]; // d/dx_i
        v[k++] = 1.0;               // d/dx_{i+1}
        v[k++] = -h;                // d/du_i
      }
    }
    return true;
  }

  bool eval_h(Index n, const Number* x, bool, Number obj_factor, Index m, const Number* lambda, bool, Index nele, Index* iRow, Index* jCol, Number* v) override {
    if (!v) {
      int k = 0;
      for (int i = 0; i < N; i++) { iRow[k]=i; jCol[k]=i; k++; }     // x_i diagonal
      for (int i = 0; i < N; i++) { iRow[k]=N+1+i; jCol[k]=N+1+i; k++; } // u_i diagonal
    } else {
      int k = 0;
      for (int i = 0; i < N; i++) v[k++] = -2*h*lambda[1+i]; // d²g/dx_i²
      for (int i = 0; i < N; i++) v[k++] = 2*h*obj_factor;    // d²f/du_i²
    }
    return true;
  }

  void finalize_solution(SolverReturn, Index n, const Number* x, const Number*, const Number*, Index, const Number*, const Number*, Number obj, const IpoptData*, IpoptCalculatedQuantities*) override {
    printf("obj=%.6f x[0]=%.6f x[N]=%.6f\n", obj, x[0], x[N]);
  }
};

int main(int argc, char** argv) {
  int N = argc > 1 ? atoi(argv[1]) : 5000;
  SmartPtr<TNLP> nlp = new OCP(N);
  SmartPtr<IpoptApplication> app = IpoptApplicationFactory();
  app->Options()->SetStringValue("linear_solver", "mumps");
  app->Options()->SetIntegerValue("print_level", 0);
  app->Initialize();

  auto t0 = std::chrono::high_resolution_clock::now();
  auto status = app->OptimizeTNLP(nlp);
  auto t1 = std::chrono::high_resolution_clock::now();
  double ms = std::chrono::duration<double,std::milli>(t1-t0).count();

  printf("N=%d status=%d time=%.0fms\n", N, (int)status, ms);
  return status != Solve_Succeeded;
}
