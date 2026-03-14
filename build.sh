#!/bin/bash
set -e

# Build Ipopt + MUMPS for WebAssembly (wasm32)
# Strategy: Fortran -> FIR -> tco(i686) -> retarget wasm32 -> emcc

ROOT="$(cd "$(dirname "$0")" && pwd)"
MUMPS_DIR="$ROOT/ThirdParty-Mumps"
IPOPT_DIR="$ROOT/Ipopt"
BUILD_DIR="$ROOT/build"
MODDIR="$BUILD_DIR/fortran_mods"
LLDIR="$BUILD_DIR/ll"
OBJDIR="$BUILD_DIR/obj"
OUTDIR="$BUILD_DIR/out"

mkdir -p "$MODDIR" "$LLDIR" "$OBJDIR" "$OUTDIR"

# Preprocessor defines for MUMPS
MUMPS_FFLAGS=(
  -DMUMPS_ARITH=MUMPS_ARITH_d
  -DAdd_
  -DWITHOUT_PTHREAD=1
  -DWITHOUT_METIS
  -DWITHOUT_SCOTCH
  -Dpord
)

MUMPS_INCLUDES=(
  -I "$MUMPS_DIR/MUMPS/include"
  -I "$MUMPS_DIR/MUMPS/src"
  -I "$MUMPS_DIR/MUMPS/libseq"
)

# Function to retarget LLVM IR from arm64 to wasm32
retarget_ll() {
  local input="$1"
  local output="$2"
  sed \
    -e 's/^target datalayout = .*/target datalayout = "e-m:e-p:32:32-p10:8:8-p20:8:8-i64:64-n32:64-S128-ni:1:10:20"/' \
    -e 's/^target triple = .*/target triple = "wasm32-unknown-emscripten"/' \
    -e 's/ "target-cpu"="[^"]*"//g' \
    -e 's/ "target-features"="[^"]*"//g' \
    -e 's/ "frame-pointer"="[^"]*"/ "frame-pointer"="all"/g' \
    -e 's/ common global / weak global /g' \
    "$input" > "$output"
}

# Function to compile a Fortran file to wasm object
compile_fortran() {
  local src="$1"
  local basename="$(basename "$src" .F)"
  basename="$(basename "$basename" .f)"
  local ll_native="$LLDIR/${basename}_native.ll"
  local ll_wasm="$LLDIR/${basename}.ll"
  local obj="$OBJDIR/${basename}.o"

  if [ -f "$obj" ]; then
    return 0
  fi

  echo "  F: $(basename "$src")"

  local fir="$LLDIR/${basename}.fir"

  # Step 1: Fortran -> FIR (MLIR)
  flang-new -fc1 -emit-fir -w \
    "${MUMPS_FFLAGS[@]}" \
    "${MUMPS_INCLUDES[@]}" \
    -module-dir "$MODDIR" \
    -o "$fir" \
    "$src" 2>&1 | grep -v "warning:" | grep -v "^$" || true

  # Step 2: Fix external names (Add_ mangling)
  fir-opt --external-name-interop "$fir" -o "${fir}.interop" 2>&1

  # Step 3: FIR -> LLVM IR (targeting i686 for 32-bit pointers)
  tco --target=i686-unknown-linux-gnu "${fir}.interop" -o "$ll_native" 2>&1

  # Step 3: Retarget to wasm32 and fix common linkage + ptrtoint
  sed -e 's/ common global / weak global /g' \
      -e 's|^target datalayout = .*|target datalayout = "e-m:e-p:32:32-p10:8:8-p20:8:8-i64:64-n32:64-S128-ni:1:10:20"|' \
      -e 's|^target triple = .*|target triple = "wasm32-unknown-emscripten"|' \
      -e 's/i64 ptrtoint (ptr @[^ ]* to i64)/i64 0/g' \
      -e 's/ captures(none)//g' \
      -e 's/ nocreateundeforpoison//g' \
      -e 's/ noaliasing//g' \
      -e 's/declare ptr @malloc(i64)/declare ptr @malloc(i32)/g' \
      "$ll_native" > "$ll_wasm"

  # Step 3b: Fix malloc(i64) calls -> malloc(i32) with trunc
  python3 "$ROOT/fix_malloc.py" "$ll_wasm"

  # Step 4: Compile to wasm32 object
  emcc -c -O2 "$ll_wasm" -o "$obj" 2>&1
}

# Function to compile a C file to wasm object
compile_c() {
  local src="$1"
  local basename="$(basename "$src" .c)"
  # Prefix to avoid name collisions
  local prefix="$2"
  local obj="$OBJDIR/${prefix}${basename}.o"

  if [ -f "$obj" ]; then
    return 0
  fi

  echo "  C: $(basename "$src")"
  emcc -c -O2 \
    -DAdd_ \
    -DWITHOUT_PTHREAD=1 \
    -DMUMPS_ARITH=MUMPS_ARITH_d \
    -Dpord \
    -Dmumps_ftnlen='long long' \
    \
    -I "$MUMPS_DIR/MUMPS/include" \
    -I "$MUMPS_DIR/MUMPS/src" \
    -I "$MUMPS_DIR/MUMPS/libseq" \
    -I "$MUMPS_DIR/MUMPS/PORD/include" \
    -I "$MUMPS_DIR" \
    "$src" -o "$obj" 2>&1
}

echo "=== Building MUMPS for WebAssembly ==="
echo ""

# -------------------------------------------------------
# Compile all Fortran files in topologically sorted order
# (modules defined before modules used)
# -------------------------------------------------------
echo "--- Compiling Fortran sources ---"

FORTRAN_SOURCES=(
  # Tier 0: no internal module dependencies
  "MUMPS/libseq/mpi.f"
  "MUMPS/src/ana_AMDMF.F"
  "MUMPS/src/ana_blk_m.F"
  "MUMPS/src/ana_orderings.F"
  "MUMPS/src/ana_orderings_wrappers_m.F"
  "MUMPS/src/ana_set_ordering.F"
  "MUMPS/src/bcast_errors.F"
  "MUMPS/src/dana_mtrans.F"
  "MUMPS/src/dana_reordertree.F"
  "MUMPS/src/dfac_diag.F"
  "MUMPS/src/dfac_mem_stack_aux.F"
  "MUMPS/src/dfac_process_bf.F"
  "MUMPS/src/dfac_scalings_simScaleAbs.F"
  "MUMPS/src/dfac_scalings_simScale_util.F"
  "MUMPS/src/dfac_sispointers_m.F"
  "MUMPS/src/dfac_type3_symmetrize.F"
  "MUMPS/src/dlr_type.F"
  "MUMPS/src/dmumps_config_file.F"
  "MUMPS/src/dmumps_iXamax.F"
  "MUMPS/src/dmumps_mpi3_mod.F"
  "MUMPS/src/dmumps_sol_es.F"
  "MUMPS/src/dmumps_struc_def.F"
  "MUMPS/src/domp_tps_m.F"
  "MUMPS/src/double_linked_list.F"
  "MUMPS/src/dsol_distsol.F"
  "MUMPS/src/dsol_matvec.F"
  "MUMPS/src/dsol_root_parallel.F"
  "MUMPS/src/dstatic_ptr_m.F"
  "MUMPS/src/estim_flops.F"
  "MUMPS/src/fac_future_niv2_mod.F"
  "MUMPS/src/front_data_mgt_m.F"
  "MUMPS/src/lr_common.F"
  "MUMPS/src/lr_stats.F"
  "MUMPS/src/mumps_comm_buffer_common.F"
  "MUMPS/src/mumps_intr_types_common.F"
  "MUMPS/src/mumps_l0_omp_m.F"
  "MUMPS/src/mumps_memory_mod.F"
  "MUMPS/src/mumps_mpitoomp_m.F"
  "MUMPS/src/mumps_ooc_common.F"
  "MUMPS/src/mumps_pivnul_mod.F"
  "MUMPS/src/mumps_print_defined.F"
  "MUMPS/src/mumps_type2_blocking.F"
  "MUMPS/src/mumps_version.F"
  "MUMPS/src/omp_tps_common_m.F"
  "MUMPS/src/sol_common.F"
  "MUMPS/src/sol_ds_common_m.F"
  "MUMPS/src/sol_omp_common_m.F"
  "MUMPS/src/tools_common_m.F"
  # Tier 1: depend on tier 0 modules
  "MUMPS/src/dana_aux_ELT.F"
  "MUMPS/src/dana_LDLT_preprocess.F"
  "MUMPS/src/dfac_scalings.F"
  "MUMPS/src/dini_defaults.F"
  "MUMPS/src/dmumps_f77.F"
  "MUMPS/src/dmumps_save_restore_files.F"
  "MUMPS/src/dsol_distrhs.F"
  "MUMPS/src/ana_omp_m.F"
  "MUMPS/src/dmumps_lr_data_m.F"
  "MUMPS/src/fac_descband_data_m.F"
  "MUMPS/src/fac_maprow_data_m.F"
  "MUMPS/src/mumps_static_mapping.F"
  "MUMPS/src/dbcast_int.F"
  "MUMPS/src/mumps_load.F"
  "MUMPS/src/tools_common.F"
  "MUMPS/src/dmumps_intr_types.F"
  "MUMPS/src/dmumps_ooc_buffer.F"
  "MUMPS/src/fac_asm_build_sort_index_ELT_m.F"
  "MUMPS/src/fac_asm_build_sort_index_m.F"
  # Tier 2
  "MUMPS/src/ana_blk.F"
  "MUMPS/src/dana_aux_par.F"
  "MUMPS/src/dlr_core.F"
  "MUMPS/src/dana_aux.F"
  "MUMPS/src/dfac_mem_alloc_cb.F"
  "MUMPS/src/dfac_mem_dynamic.F"
  "MUMPS/src/dfac_mem_free_block_cb.F"
  "MUMPS/src/dfac_sol_pool.F"
  "MUMPS/src/dfac_dist_arrowheads_omp.F"
  "MUMPS/src/dfac_distrib_ELT.F"
  "MUMPS/src/dfac_distrib_distentry.F"
  "MUMPS/src/dfac_lastrtnelind.F"
  "MUMPS/src/dfac_process_band.F"
  "MUMPS/src/dfac_process_end_facto_slave.F"
  "MUMPS/src/dfac_process_message.F"
  "MUMPS/src/dfac_process_root2son.F"
  "MUMPS/src/dfac_process_rtnelind.F"
  "MUMPS/src/dfac_root_parallel.F"
  "MUMPS/src/dfac_sol_l0omp_m.F"
  "MUMPS/src/dini_driver.F"
  "MUMPS/src/drank_revealing.F"
  "MUMPS/src/dsol_bwd.F"
  "MUMPS/src/dsol_fwd.F"
  "MUMPS/src/dsol_omp_m.F"
  "MUMPS/src/dmumps_ooc.F"
  # Tier 3
  "MUMPS/src/dana_dist_m.F"
  "MUMPS/src/dana_lr.F"
  "MUMPS/src/dfac_lr.F"
  "MUMPS/src/dmumps_comm_buffer.F"
  "MUMPS/src/dsol_lr.F"
  "MUMPS/src/darrowheads.F"
  "MUMPS/src/dfac_compact_factors_m.F"
  "MUMPS/src/dfac_mem_compress_cb.F"
  "MUMPS/src/dfac_process_contrib_type1.F"
  "MUMPS/src/dfac_process_master2.F"
  "MUMPS/src/dend_driver.F"
  "MUMPS/src/dfac_front_aux.F"
  "MUMPS/src/dfac_process_contrib_type3.F"
  "MUMPS/src/dfac_process_root2slave.F"
  "MUMPS/src/dmumps_save_restore.F"
  "MUMPS/src/dooc_panel_piv.F"
  "MUMPS/src/dsol_aux.F"
  "MUMPS/src/dsol_c.F"
  # Tier 4
  "MUMPS/src/dana_driver.F"
  "MUMPS/src/dfac_asm_ELT.F"
  "MUMPS/src/dfac_asm_master_ELT_m.F"
  "MUMPS/src/dfac_asm_master_m.F"
  "MUMPS/src/dfac_process_blocfacto.F"
  "MUMPS/src/dfac_mem_stack.F"
  "MUMPS/src/dfac_process_contrib_type2.F"
  "MUMPS/src/dtools.F"
  "MUMPS/src/dtype3_root.F"
  "MUMPS/src/dsol_bwd_aux.F"
  "MUMPS/src/dsol_fwd_aux.F"
  # Tier 5
  "MUMPS/src/dfac_driver.F"
  "MUMPS/src/dfac_asm.F"
  "MUMPS/src/dfac_determinant.F"
  "MUMPS/src/dfac_front_LDLT_type1.F"
  "MUMPS/src/dfac_front_LU_type1.F"
  "MUMPS/src/dfac_front_type2_aux.F"
  "MUMPS/src/dfac_process_blfac_slave.F"
  "MUMPS/src/dfac_process_blocfacto_LDLT.F"
  "MUMPS/src/dfac_process_maprow.F"
  "MUMPS/src/dmumps_driver.F"
  "MUMPS/src/dsol_driver.F"
  # Tier 6
  "MUMPS/src/dfac_omp_m.F"
  "MUMPS/src/dfac_front_LDLT_type2.F"
  "MUMPS/src/dfac_front_LU_type2.F"
  "MUMPS/src/dfac_par_m.F"
  "MUMPS/src/dfac_b.F"
)

for f in "${FORTRAN_SOURCES[@]}"; do
  compile_fortran "$MUMPS_DIR/$f"
done

# -------------------------------------------------------
# Compile C files
# -------------------------------------------------------
echo "--- Compiling C sources ---"

MUMPS_C_FILES=(
  MUMPS/src/mumps_addr.c
  MUMPS/src/mumps_common.c
  MUMPS/src/mumps_config_file_C.c
  MUMPS/src/mumps_flytes.c
  MUMPS/src/mumps_io_basic.c
  MUMPS/src/mumps_io.c
  MUMPS/src/mumps_io_err.c
  MUMPS/src/mumps_io_thread.c
  MUMPS/src/mumps_pord.c
  MUMPS/src/mumps_save_restore_C.c
  MUMPS/src/mumps_thread_affinity.c
  MUMPS/src/mumps_register_thread.c
  MUMPS/src/mumps_thread.c
  MUMPS/src/mumps_numa.c
  MUMPS/src/dmumps_gpu.c
  MUMPS/libseq/mpic.c
  MUMPS/libseq/elapse.c
)

for f in "${MUMPS_C_FILES[@]}"; do
  compile_c "$MUMPS_DIR/$f" ""
done

# Build dmumps_c.c (the C interface)
echo "  C: mumps_c.c -> dmumps_c.o"
if [ ! -f "$OBJDIR/dmumps_c.o" ]; then
  emcc -c -O2 \
    -DAdd_ \
    -DWITHOUT_PTHREAD=1 \
    -DMUMPS_ARITH=MUMPS_ARITH_d \
    -I "$MUMPS_DIR/MUMPS/include" \
    -I "$MUMPS_DIR/MUMPS/src" \
    -I "$MUMPS_DIR/MUMPS/libseq" \
    -I "$MUMPS_DIR" \
    "$MUMPS_DIR/MUMPS/src/mumps_c.c" -o "$OBJDIR/dmumps_c.o" 2>&1
fi

# PORD (pure C, internal ordering)
echo "--- Compiling PORD ---"
PORD_C_FILES=(
  MUMPS/PORD/lib/bucket.c
  MUMPS/PORD/lib/ddbisect.c
  MUMPS/PORD/lib/ddcreate.c
  MUMPS/PORD/lib/gbipart.c
  MUMPS/PORD/lib/gbisect.c
  MUMPS/PORD/lib/gelim.c
  MUMPS/PORD/lib/graph.c
  MUMPS/PORD/lib/interface.c
  MUMPS/PORD/lib/minpriority.c
  MUMPS/PORD/lib/multisector.c
  MUMPS/PORD/lib/nestdiss.c
  MUMPS/PORD/lib/sort.c
  MUMPS/PORD/lib/symbfac.c
  MUMPS/PORD/lib/tree.c
)

for f in "${PORD_C_FILES[@]}"; do
  compile_c "$MUMPS_DIR/$f" "pord_"
done

# -------------------------------------------------------
# Create MUMPS static library
# -------------------------------------------------------
echo "--- Creating MUMPS static library ---"
emar rcs "$OUTDIR/libmumps.a" "$OBJDIR"/*.o
echo "  Created: $OUTDIR/libmumps.a"

# -------------------------------------------------------
# Phase 5: Build BLAS/LAPACK
# -------------------------------------------------------
LAPACK_DIR="$ROOT/lapack"
LAPACK_OBJDIR="$BUILD_DIR/obj_lapack"
LAPACK_LLDIR="$BUILD_DIR/ll_lapack"
mkdir -p "$LAPACK_OBJDIR" "$LAPACK_LLDIR"

compile_lapack_fortran() {
  local src="$1"
  local basename="$(basename "$src" .f)"
  basename="$(basename "$basename" .f90)"
  local ll_native="$LAPACK_LLDIR/${basename}_native.ll"
  local ll_wasm="$LAPACK_LLDIR/${basename}.ll"
  local obj="$LAPACK_OBJDIR/${basename}.o"

  if [ -f "$obj" ]; then
    return 0
  fi

  local fir="$LAPACK_LLDIR/${basename}.fir"
  flang-new -fc1 -emit-fir -w \
    -module-dir "$LAPACK_LLDIR" \
    -o "$fir" \
    "$src" 2>&1 | grep -v "warning:" || true

  fir-opt --external-name-interop "$fir" -o "${fir}.interop" 2>&1
  tco --target=i686-unknown-linux-gnu "${fir}.interop" -o "$ll_native" 2>&1

  sed -e 's/ common global / weak global /g' \
      -e 's|^target datalayout = .*|target datalayout = "e-m:e-p:32:32-p10:8:8-p20:8:8-i64:64-n32:64-S128-ni:1:10:20"|' \
      -e 's|^target triple = .*|target triple = "wasm32-unknown-emscripten"|' \
      -e 's/i64 ptrtoint (ptr @[^ ]* to i64)/i64 0/g' \
      -e 's/ captures(none)//g' \
      -e 's/ nocreateundeforpoison//g' \
      -e 's/ noaliasing//g' \
      -e 's/declare ptr @malloc(i64)/declare ptr @malloc(i32)/g' \
      "$ll_native" > "$ll_wasm"
  python3 "$ROOT/fix_malloc.py" "$ll_wasm"
  emcc -c -O2 "$ll_wasm" -o "$obj" 2>&1
}

# Compile LAPACK f90 module dependencies first (before BLAS, since BLAS .f90 may use them)
echo "--- Compiling LAPACK modules ---"
for f in "$LAPACK_DIR"/SRC/la_constants.f90 "$LAPACK_DIR"/SRC/la_xisnan.f90; do
  if [ -f "$f" ]; then
    basename="$(basename "$f" .f90)"
    if [ ! -f "$LAPACK_OBJDIR/${basename}.o" ]; then
      echo "  F: $(basename "$f")"
      compile_lapack_fortran "$f"
    fi
  fi
done

echo "--- Compiling BLAS ---"
for f in "$LAPACK_DIR"/BLAS/SRC/*.f "$LAPACK_DIR"/BLAS/SRC/*.f90; do
  [ -f "$f" ] || continue
  basename="$(basename "$f" .f)"
  basename="$(basename "$basename" .f90)"
  if [ ! -f "$LAPACK_OBJDIR/${basename}.o" ]; then
    echo -n "."
    compile_lapack_fortran "$f"
  fi
done
echo ""

echo "--- Compiling LAPACK ---"
for f in "$LAPACK_DIR"/SRC/*.f; do
  basename="$(basename "$f" .f)"
  if [ ! -f "$LAPACK_OBJDIR/${basename}.o" ]; then
    echo -n "."
    compile_lapack_fortran "$f"
  fi
done
# Also compile LAPACK f90 files
for f in "$LAPACK_DIR"/SRC/*.f90; do
  basename="$(basename "$f" .f90)"
  if [ ! -f "$LAPACK_OBJDIR/${basename}.o" ]; then
    echo -n "."
    compile_lapack_fortran "$f"
  fi
done
echo ""

echo "--- Compiling LAPACK INSTALL (dlamch etc.) ---"
for f in "$LAPACK_DIR"/INSTALL/dlamch.f "$LAPACK_DIR"/INSTALL/slamch.f "$LAPACK_DIR"/INSTALL/ilaver.f "$LAPACK_DIR"/INSTALL/lsame.f; do
  if [ -f "$f" ]; then
    basename="$(basename "$f" .f)"
    if [ ! -f "$LAPACK_OBJDIR/${basename}.o" ]; then
      echo "  F: $(basename "$f")"
      compile_lapack_fortran "$f"
    fi
  fi
done

echo "--- Creating LAPACK static library ---"
emar rcs "$OUTDIR/liblapack.a" "$LAPACK_OBJDIR"/*.o

# -------------------------------------------------------
# Phase 6: Build Ipopt
# -------------------------------------------------------
echo "--- Compiling Ipopt ---"
IPOPT_OBJDIR="$BUILD_DIR/obj_ipopt"
mkdir -p "$IPOPT_OBJDIR"

IPOPT_SRC="$IPOPT_DIR/src"
IPOPT_INCLUDES=(
  -I "$IPOPT_SRC/Common"
  -I "$IPOPT_SRC/LinAlg"
  -I "$IPOPT_SRC/LinAlg/TMatrices"
  -I "$IPOPT_SRC/Algorithm"
  -I "$IPOPT_SRC/Algorithm/LinearSolvers"
  -I "$IPOPT_SRC/Interfaces"
  -I "$IPOPT_SRC/contrib/CGPenalty"
  -I "$MUMPS_DIR"
  -I "$MUMPS_DIR/MUMPS/include"
  -I "$MUMPS_DIR/MUMPS/libseq"
)

IPOPT_DEFINES=(
  -DHAVE_CONFIG_H
  -DIPOPTLIB_BUILD
  -DCOIN_HAS_MUMPS
  -DIPOPT_HAS_MUMPS
  -DAdd_
)

compile_ipopt_cpp() {
  local src="$1"
  local basename="$(basename "$src" .cpp)"
  basename="$(basename "$basename" .c)"
  local obj="$IPOPT_OBJDIR/${basename}.o"

  if [ -f "$obj" ]; then
    return 0
  fi

  echo "  CXX: $(basename "$src")"
  emcc -c -O2 -std=c++17 \
    "${IPOPT_DEFINES[@]}" \
    "${IPOPT_INCLUDES[@]}" \
    "$src" -o "$obj" 2>&1
}

# Common
for f in "$IPOPT_SRC"/Common/*.cpp; do
  compile_ipopt_cpp "$f"
done

# LinAlg
for f in "$IPOPT_SRC"/LinAlg/*.cpp; do
  compile_ipopt_cpp "$f"
done

# LinAlg/TMatrices
for f in "$IPOPT_SRC"/LinAlg/TMatrices/*.cpp; do
  compile_ipopt_cpp "$f"
done

# Algorithm
for f in "$IPOPT_SRC"/Algorithm/*.cpp; do
  compile_ipopt_cpp "$f"
done

# Algorithm/LinearSolvers (selective)
for f in \
  IpLinearSolversRegOp.cpp \
  IpSlackBasedTSymScalingMethod.cpp \
  IpTripletToCSRConverter.cpp \
  IpTSymDependencyDetector.cpp \
  IpTSymLinearSolver.cpp \
  IpMumpsSolverInterface.cpp \
  IpMa27TSolverInterface.cpp \
  IpMa57TSolverInterface.cpp \
  IpMa77SolverInterface.cpp \
  IpMa86SolverInterface.cpp \
  IpMa97SolverInterface.cpp \
  IpMc19TSymScalingMethod.cpp \
  IpPardisoSolverInterface.cpp \
; do
  compile_ipopt_cpp "$IPOPT_SRC/Algorithm/LinearSolvers/$f"
done

# Also compile the C file
echo "  C: IpLinearSolvers.c"
if [ ! -f "$IPOPT_OBJDIR/IpLinearSolvers.o" ]; then
  emcc -c -O2 \
    "${IPOPT_DEFINES[@]}" \
    "${IPOPT_INCLUDES[@]}" \
    "$IPOPT_SRC/Algorithm/LinearSolvers/IpLinearSolvers.c" -o "$IPOPT_OBJDIR/IpLinearSolvers.o" 2>&1
fi

# Interfaces
for f in \
  IpInterfacesRegOp.cpp \
  IpIpoptApplication.cpp \
  IpSolveStatistics.cpp \
  IpStdCInterface.cpp \
  IpStdInterfaceTNLP.cpp \
  IpTNLP.cpp \
  IpTNLPAdapter.cpp \
  IpTNLPReducer.cpp \
; do
  compile_ipopt_cpp "$IPOPT_SRC/Interfaces/$f"
done

# Also the C interface
echo "  C: IpStdFInterface.c"
if [ ! -f "$IPOPT_OBJDIR/IpStdFInterface.o" ]; then
  emcc -c -O2 \
    "${IPOPT_DEFINES[@]}" \
    "${IPOPT_INCLUDES[@]}" \
    "$IPOPT_SRC/Interfaces/IpStdFInterface.c" -o "$IPOPT_OBJDIR/IpStdFInterface.o" 2>&1
fi

# contrib/CGPenalty
for f in "$IPOPT_SRC"/contrib/CGPenalty/*.cpp; do
  compile_ipopt_cpp "$f"
done

# NOTE: Fortran runtime stubs are no longer needed - using real libflangrt.a instead

echo "--- Creating Ipopt static library ---"
emar rcs "$OUTDIR/libipopt.a" "$IPOPT_OBJDIR"/*.o

echo ""
echo "=== Build complete ==="
echo "MUMPS:   $OUTDIR/libmumps.a ($(ls "$OBJDIR"/*.o | wc -l | tr -d ' ') objects)"
echo "LAPACK:  $OUTDIR/liblapack.a ($(ls "$LAPACK_OBJDIR"/*.o | wc -l | tr -d ' ') objects)"
echo "Ipopt:   $OUTDIR/libipopt.a ($(ls "$IPOPT_OBJDIR"/*.o | wc -l | tr -d ' ') objects)"
