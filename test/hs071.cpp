// Hock-Schittkowski problem #71 - classic Ipopt test
// min x1*x4*(x1+x2+x3) + x3
// s.t. x1*x2*x3*x4 >= 25
//      x1^2 + x2^2 + x3^2 + x4^2 = 40
//      1 <= x1,x2,x3,x4 <= 5
//      x0 = (1, 5, 5, 1)

#include "IpIpoptApplication.hpp"
#include "IpTNLP.hpp"
#include <cstdio>

using namespace Ipopt;

class HS071_NLP : public TNLP {
public:
  HS071_NLP() {}
  virtual ~HS071_NLP() {}

  bool get_nlp_info(Index& n, Index& m, Index& nnz_jac_g,
                    Index& nnz_h_lag, IndexStyleEnum& index_style) override {
    n = 4;
    m = 2;
    nnz_jac_g = 8;
    nnz_h_lag = 10;
    index_style = TNLP::C_STYLE;
    return true;
  }

  bool get_bounds_info(Index n, Number* x_l, Number* x_u,
                       Index m, Number* g_l, Number* g_u) override {
    for (Index i = 0; i < 4; i++) { x_l[i] = 1.0; x_u[i] = 5.0; }
    g_l[0] = 25.0; g_u[0] = 1e19;
    g_l[1] = 40.0; g_u[1] = 40.0;
    return true;
  }

  bool get_starting_point(Index n, bool init_x, Number* x,
                          bool init_z, Number* z_L, Number* z_U,
                          Index m, bool init_lambda, Number* lambda) override {
    x[0] = 1.0; x[1] = 5.0; x[2] = 5.0; x[3] = 1.0;
    return true;
  }

  bool eval_f(Index n, const Number* x, bool new_x, Number& obj_value) override {
    obj_value = x[0] * x[3] * (x[0] + x[1] + x[2]) + x[2];
    return true;
  }

  bool eval_grad_f(Index n, const Number* x, bool new_x, Number* grad_f) override {
    grad_f[0] = x[3] * (2*x[0] + x[1] + x[2]);
    grad_f[1] = x[0] * x[3];
    grad_f[2] = x[0] * x[3] + 1;
    grad_f[3] = x[0] * (x[0] + x[1] + x[2]);
    return true;
  }

  bool eval_g(Index n, const Number* x, bool new_x, Index m, Number* g) override {
    g[0] = x[0] * x[1] * x[2] * x[3];
    g[1] = x[0]*x[0] + x[1]*x[1] + x[2]*x[2] + x[3]*x[3];
    return true;
  }

  bool eval_jac_g(Index n, const Number* x, bool new_x,
                  Index m, Index nele_jac, Index* iRow, Index* jCol,
                  Number* values) override {
    if (values == NULL) {
      iRow[0]=0; jCol[0]=0; iRow[1]=0; jCol[1]=1;
      iRow[2]=0; jCol[2]=2; iRow[3]=0; jCol[3]=3;
      iRow[4]=1; jCol[4]=0; iRow[5]=1; jCol[5]=1;
      iRow[6]=1; jCol[6]=2; iRow[7]=1; jCol[7]=3;
    } else {
      values[0] = x[1]*x[2]*x[3]; values[1] = x[0]*x[2]*x[3];
      values[2] = x[0]*x[1]*x[3]; values[3] = x[0]*x[1]*x[2];
      values[4] = 2*x[0]; values[5] = 2*x[1];
      values[6] = 2*x[2]; values[7] = 2*x[3];
    }
    return true;
  }

  bool eval_h(Index n, const Number* x, bool new_x,
              Number obj_factor, Index m, const Number* lambda,
              bool new_lambda, Index nele_hess, Index* iRow, Index* jCol,
              Number* values) override {
    if (values == NULL) {
      Index idx = 0;
      for (Index row = 0; row < 4; row++)
        for (Index col = 0; col <= row; col++)
          { iRow[idx] = row; jCol[idx] = col; idx++; }
    } else {
      values[0] = obj_factor * 2 * x[3] + lambda[1] * 2;
      values[1] = obj_factor * x[3];
      values[2] = lambda[1] * 2;
      values[3] = obj_factor * x[3];
      values[4] = 0;
      values[5] = lambda[1] * 2;
      values[6] = obj_factor * (2*x[0] + x[1] + x[2]);
      values[7] = obj_factor * x[0];
      values[8] = obj_factor * x[0];
      values[9] = lambda[1] * 2;
      // constraint 0 hessian
      values[1] += lambda[0] * x[2]*x[3];
      values[3] += lambda[0] * x[1]*x[3];
      values[4] += lambda[0] * x[0]*x[3];
      values[6] += lambda[0] * x[1]*x[2];
      values[7] += lambda[0] * x[0]*x[2];
      values[8] += lambda[0] * x[0]*x[1];
    }
    return true;
  }

  void finalize_solution(SolverReturn status, Index n, const Number* x,
                         const Number* z_L, const Number* z_U,
                         Index m, const Number* g, const Number* lambda,
                         Number obj_value, const IpoptData* ip_data,
                         IpoptCalculatedQuantities* ip_cq) override {
    printf("\n=== Solution ===\n");
    printf("x = [%f, %f, %f, %f]\n", x[0], x[1], x[2], x[3]);
    printf("obj = %f\n", obj_value);
    printf("status = %d\n", (int)status);
  }
};

int main() {
  SmartPtr<TNLP> mynlp = new HS071_NLP();
  SmartPtr<IpoptApplication> app = IpoptApplicationFactory();

  app->Options()->SetStringValue("linear_solver", "mumps");
  app->Options()->SetIntegerValue("print_level", 5);

  ApplicationReturnStatus status = app->Initialize();
  if (status != Solve_Succeeded) {
    printf("Error during initialization!\n");
    return 1;
  }

  status = app->OptimizeTNLP(mynlp);

  if (status == Solve_Succeeded || status == Solved_To_Acceptable_Level) {
    printf("\nSUCCESS!\n");
    return 0;
  } else {
    printf("\nFAILED with status %d\n", (int)status);
    return 1;
  }
}
