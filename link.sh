#!/bin/bash
set -e

# Link Ipopt + MUMPS + LAPACK + flang runtime into a wasm32 binary

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$ROOT/build"
OUTDIR="$BUILD_DIR/out"
IPOPT_SRC="$ROOT/Ipopt/src"
MUMPS_DIR="$ROOT/ThirdParty-Mumps"

# Common sed fixups for retargeting LLVM IR to wasm32
retarget_wasm32() {
  local input="$1" output="$2"
  sed -e 's/ common global / weak global /g' \
      -e 's|^target datalayout = .*|target datalayout = "e-m:e-p:32:32-p10:8:8-p20:8:8-i64:64-n32:64-S128-ni:1:10:20"|' \
      -e 's|^target triple = .*|target triple = "wasm32-unknown-emscripten"|' \
      -e 's/i64 ptrtoint (ptr @[^ ]* to i64)/i64 0/g' \
      -e 's/ captures(none)//g' \
      -e 's/ nocreateundeforpoison//g' \
      -e 's/ noaliasing//g' \
      -e 's/declare ptr @malloc(i64)/declare ptr @malloc(i32)/g' \
      "$input" > "$output"
  python3 "$ROOT/fix_malloc.py" "$output"
}

echo "=== Fixing MUMPS signature mismatches ==="
# mpi_bcast_: remove 7th arg (hidden char length) from one caller
if grep -q "mpi_bcast_.*i64 %" "$BUILD_DIR/ll/dmumps_save_restore_files_native.ll" 2>/dev/null; then
  sed -i.bak \
    -e 's/call void @mpi_bcast_(ptr %\([0-9]*\), ptr %\([0-9]*\), ptr %\([0-9]*\), ptr %\([0-9]*\), ptr %\([0-9]*\), ptr %\([0-9]*\), i64 %[0-9]*)/call void @mpi_bcast_(ptr %\1, ptr %\2, ptr %\3, ptr %\4, ptr %\5, ptr %\6)/g' \
    -e 's/declare void @mpi_bcast_(ptr, ptr, ptr, ptr, ptr, ptr, i64)/declare void @mpi_bcast_(ptr, ptr, ptr, ptr, ptr, ptr)/' \
    "$BUILD_DIR/ll/dmumps_save_restore_files_native.ll"
  rm -f "$BUILD_DIR/ll/dmumps_save_restore_files_native.ll.bak"
  retarget_wasm32 "$BUILD_DIR/ll/dmumps_save_restore_files_native.ll" "$BUILD_DIR/ll/dmumps_save_restore_files.ll"
  emcc -c -O2 "$BUILD_DIR/ll/dmumps_save_restore_files.ll" -o "$BUILD_DIR/obj/dmumps_save_restore_files.o" 2>&1
fi

# dmumps_root_solve_: add extra param to match caller (19 vs 18 args)
if ! grep -q "extra_ignored" "$BUILD_DIR/ll/dsol_root_parallel_native.ll" 2>/dev/null; then
  # Strip captures(none) first, then add extra param
  sed 's/ captures(none)//g' "$BUILD_DIR/ll/dsol_root_parallel_native.ll" | \
  sed 's/define void @dmumps_root_solve_(ptr noalias %0, ptr noalias %1, ptr noalias %2, ptr noalias %3, ptr noalias %4, ptr noalias %5, ptr noalias %6, ptr noalias %7, ptr noalias %8, ptr noalias %9, ptr noalias %10, ptr noalias %11, ptr noalias %12, ptr noalias %13, ptr noalias %14, ptr noalias %15, ptr noalias %16, ptr noalias %17)/define void @dmumps_root_solve_(ptr noalias %0, ptr noalias %1, ptr noalias %2, ptr noalias %3, ptr noalias %4, ptr noalias %5, ptr noalias %6, ptr noalias %7, ptr noalias %8, ptr noalias %9, ptr noalias %10, ptr noalias %11, ptr noalias %12, ptr noalias %13, ptr noalias %14, ptr noalias %15, ptr noalias %16, ptr noalias %17, ptr %extra_ignored)/' > "$BUILD_DIR/ll/dsol_root_parallel_tmp.ll"
  retarget_wasm32 "$BUILD_DIR/ll/dsol_root_parallel_tmp.ll" "$BUILD_DIR/ll/dsol_root_parallel.ll"
  rm -f "$BUILD_DIR/ll/dsol_root_parallel_tmp.ll"
  emcc -c -O2 "$BUILD_DIR/ll/dsol_root_parallel.ll" -o "$BUILD_DIR/obj/dsol_root_parallel.o" 2>&1
fi

# Rebuild MUMPS library
emar rcs "$OUTDIR/libmumps.a" "$BUILD_DIR/obj"/*.o

echo "=== Linking ==="
emcc -O2 -std=c++17 \
  -DHAVE_CONFIG_H -DIPOPTLIB_BUILD -DCOIN_HAS_MUMPS -DIPOPT_HAS_MUMPS -DAdd_ \
  -I "$IPOPT_SRC/Common" -I "$IPOPT_SRC/LinAlg" -I "$IPOPT_SRC/LinAlg/TMatrices" \
  -I "$IPOPT_SRC/Algorithm" -I "$IPOPT_SRC/Algorithm/LinearSolvers" \
  -I "$IPOPT_SRC/Interfaces" -I "$IPOPT_SRC/contrib/CGPenalty" \
  -I "$MUMPS_DIR" -I "$MUMPS_DIR/MUMPS/include" -I "$MUMPS_DIR/MUMPS/libseq" \
  test/hs071.cpp "$ROOT/wasm32_bridges.c" \
  "$OUTDIR/libipopt.a" "$OUTDIR/libmumps.a" "$OUTDIR/liblapack.a" "$OUTDIR/libflangrt.a" \
  -o "$OUTDIR/ipopt_test.js" \
  -sALLOW_MEMORY_GROWTH=1 -sSTACK_SIZE=2097152 -sINITIAL_MEMORY=67108864 \
  -sERROR_ON_UNDEFINED_SYMBOLS=0 -sENVIRONMENT=node

echo "=== Validating ==="
ERRORS=$(wasm-validate "$OUTDIR/ipopt_test.wasm" 2>&1 | grep -c "error:" || true)
if [ "$ERRORS" -gt 0 ]; then
  echo "WARNING: $ERRORS validation errors remain"
  wasm-validate "$OUTDIR/ipopt_test.wasm" 2>&1 | head -5
else
  echo "wasm validates OK"
fi

echo "=== Testing ==="
node "$OUTDIR/ipopt_test.js" 2>&1 | grep "EXIT:"

ls -lh "$OUTDIR/ipopt_test.wasm" "$OUTDIR/ipopt_test.js"
echo "=== Done ==="
