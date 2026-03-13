#!/bin/bash
set -e

# Build the flang Fortran runtime library for wasm64 (MEMORY64)
# Requires: emcc, flang headers (from brew install flang or LLVM source)

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$ROOT/build"
OBJDIR="$BUILD_DIR/obj_flangrt"
OUTDIR="$BUILD_DIR/out"
LLVM_SRC="$ROOT/llvm-project"

mkdir -p "$OBJDIR" "$OUTDIR"

# Clone flang-rt source if needed
if [ ! -d "$LLVM_SRC/flang-rt" ]; then
  echo "=== Cloning flang-rt source ==="
  git clone --depth 1 --filter=blob:none --sparse \
    https://github.com/llvm/llvm-project.git \
    --branch llvmorg-22.1.1 "$LLVM_SRC"
  cd "$LLVM_SRC"
  git sparse-checkout set flang-rt
  cd "$ROOT"
fi

# Find flang headers
FLANG_INCLUDE=""
for d in /opt/homebrew/Cellar/flang/*/include /usr/local/include /usr/include; do
  if [ -f "$d/flang/ISO_Fortran_binding.h" ]; then
    FLANG_INCLUDE="$d"
    break
  fi
done

if [ -z "$FLANG_INCLUDE" ]; then
  echo "ERROR: Cannot find flang headers. Install flang (brew install flang)."
  exit 1
fi
echo "Using flang headers from: $FLANG_INCLUDE"

# Create config.h for flang-rt (needed by io-error.cpp and stop.cpp)
cat > "$LLVM_SRC/flang-rt/lib/runtime/config.h" << 'EOF'
#ifndef FLANG_RT_CONFIG_H
#define FLANG_RT_CONFIG_H
#define HAVE_UNISTD_H 1
#endif
EOF

FLANGRT_FLAGS=(
  -O2 -sMEMORY64=1 -std=c++17 -Wno-c++11-narrowing
  -I "$LLVM_SRC/flang-rt/include"
  -I "$FLANG_INCLUDE"
  -I "$FLANG_INCLUDE/flang"
  -I "$FLANG_INCLUDE/flang/Runtime"
  -I "$FLANG_INCLUDE/flang-rt/runtime"
  -DFLANG_LITTLE_ENDIAN=1
)

echo "=== Compiling flang runtime for wasm64 ==="
COMPILED=0
ERRORS=0
for f in "$LLVM_SRC"/flang-rt/lib/runtime/*.cpp; do
  basename="$(basename "$f" .cpp)"
  if [ ! -f "$OBJDIR/${basename}.o" ]; then
    if emcc -c "${FLANGRT_FLAGS[@]}" "$f" -o "$OBJDIR/${basename}.o" 2>/dev/null; then
      COMPILED=$((COMPILED + 1))
    else
      ERRORS=$((ERRORS + 1))
    fi
  fi
done

# Compile C file
if [ ! -f "$OBJDIR/complex-reduction.o" ]; then
  emcc -c -O2 -sMEMORY64=1 \
    -I "$LLVM_SRC/flang-rt/include" \
    -I "$FLANG_INCLUDE" \
    -DFLANG_LITTLE_ENDIAN=1 \
    "$LLVM_SRC/flang-rt/lib/runtime/complex-reduction.c" \
    -o "$OBJDIR/complex-reduction.o" 2>/dev/null || true
fi

emar rcs "$OUTDIR/libflangrt.a" "$OBJDIR"/*.o

TOTAL=$(ls "$OBJDIR"/*.o 2>/dev/null | wc -l | tr -d ' ')
echo "Built libflangrt.a: $TOTAL objects ($COMPILED new, $ERRORS errors)"
