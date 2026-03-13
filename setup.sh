#!/bin/bash
set -e

# Download and prepare all dependencies for building Ipopt+MUMPS for WebAssembly
ROOT="$(cd "$(dirname "$0")" && pwd)"

echo "=== Cloning Ipopt ==="
if [ ! -d "$ROOT/Ipopt" ]; then
  git clone https://github.com/coin-or/Ipopt.git --depth 1 "$ROOT/Ipopt"
fi

echo "=== Cloning ThirdParty-Mumps ==="
if [ ! -d "$ROOT/ThirdParty-Mumps" ]; then
  git clone https://github.com/coin-or-tools/ThirdParty-Mumps.git --depth 1 "$ROOT/ThirdParty-Mumps"
fi

echo "=== Downloading MUMPS source ==="
if [ ! -d "$ROOT/ThirdParty-Mumps/MUMPS" ]; then
  cd "$ROOT/ThirdParty-Mumps"
  bash get.Mumps
  cd "$ROOT"
fi

echo "=== Cloning reference LAPACK ==="
if [ ! -d "$ROOT/lapack" ]; then
  git clone https://github.com/Reference-LAPACK/lapack.git --depth 1 "$ROOT/lapack"
fi

echo "=== Creating config headers ==="
# mumps_int_def.h (32-bit MUMPS integers)
cat > "$ROOT/ThirdParty-Mumps/mumps_int_def.h" << 'HEADER'
#ifndef MUMPS_INT_H
#define MUMPS_INT_H
#define MUMPS_INTSIZE32
#endif
HEADER

# mumps_compat.h (COIN-OR compatibility, renamed mpi.h)
cat > "$ROOT/ThirdParty-Mumps/mumps_compat.h" << 'HEADER'
#ifndef MUMPS_COMPAT_H
#define MUMPS_COMPAT_H
#ifndef MUMPS_CALL
#define MUMPS_CALL
#endif
#define COIN_USE_MUMPS_MPI_H
#if (__STDC_VERSION__ >= 199901L)
# define MUMPS_INLINE static inline
#else
# define MUMPS_INLINE
#endif
#endif
HEADER

# Ipopt config.h
cat > "$ROOT/Ipopt/src/Common/config.h" << 'HEADER'
#define F77_FUNC(name,NAME) name ## _
#define F77_FUNC_(name,NAME) name ## _
#define HAVE_CFLOAT 1
#define HAVE_CMATH 1
#define HAVE_FLOAT_H 1
#define HAVE_INTTYPES_H 1
#define HAVE_MATH_H 1
#define HAVE_STDINT_H 1
#define HAVE_STDIO_H 1
#define HAVE_STDLIB_H 1
#define HAVE_STRING_H 1
#define HAVE_STRINGS_H 1
#define HAVE_UNISTD_H 1
#define IPOPT_C_FINITE std::isfinite
#define IPOPT_HAS_DRAND48 1
#define HAVE_VA_COPY 1
#define IPOPT_HAS_LAPACK 1
#define IPOPT_HAS_MUMPS 1
#define IPOPT_VERSION "3.14.20"
#define IPOPT_VERSION_MAJOR 3
#define IPOPT_VERSION_MINOR 14
#define IPOPT_VERSION_RELEASE 20
#define IPOPT_BLAS_FUNC(name,NAME) F77_FUNC(name,NAME)
#define IPOPT_LAPACK_FUNC(name,NAME) F77_FUNC(name,NAME)
#ifndef IPOPTLIB_EXPORT
#define IPOPTLIB_EXPORT
#endif
#define COIN_USE_MUMPS_MPI_H
#define IPOPT_MUMPS_NOMUTEX
#ifndef IPOPT_FORTRAN_INTEGER_TYPE
#define IPOPT_FORTRAN_INTEGER_TYPE int
#endif
HEADER

echo "=== Patching Ipopt BLAS/LAPACK hidden char lengths for wasm64 ==="
# On x86_64 (used by tco), hidden Fortran character lengths are i64 (long long)
cd "$ROOT"
for f in Ipopt/src/LinAlg/IpBlas.cpp Ipopt/src/LinAlg/IpLapack.cpp; do
  if grep -q "int .*_len" "$f" 2>/dev/null; then
    sed -i.bak 's/int             \([a-z_]*_len\)/long long       \1/g; s/int       \([a-z_]*_len\)/long long \1/g' "$f"
    rm -f "${f}.bak"
  fi
done
# Add missing uplo_len to dppsv declaration
if ! grep -q "uplo_len" Ipopt/src/LinAlg/IpLapack.cpp 2>/dev/null; then
  sed -i.bak '/ipindex\*        info$/{N;s/\n   );/,\n      long long       uplo_len\n   );/}' Ipopt/src/LinAlg/IpLapack.cpp
  # Also fix the call site
  sed -i.bak 's/PPSV)(\&uplo, \&N, \&NRHS, a, b, \&LDB, \&INFO);/PPSV)(\&uplo, \&N, \&NRHS, a, b, \&LDB, \&INFO, 1);/' Ipopt/src/LinAlg/IpLapack.cpp
  rm -f Ipopt/src/LinAlg/IpLapack.cpp.bak
fi

echo "=== Setup complete ==="
