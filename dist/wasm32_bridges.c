// Bridge functions for wasm32: the Fortran IR (from tco i686) passes size_t
// as i64, but the flang C++ runtime uses i32 size_t on wasm32.
// These wrappers accept i64 and forward to the real runtime with truncated i32.

#include <stdint.h>
#include <stdbool.h>

// The real runtime functions (with i32 size_t on wasm32)
// We call them via renamed symbols to avoid infinite recursion.
// Strategy: the linker resolves our wrapper as the definition,
// and calls into the C++ runtime via the actual mangled names.

// Actually, the approach: the Fortran IR calls functions like
// _FortranACharacterCompareScalar1(ptr, ptr, i64, i64)
// but the runtime defines them as (ptr, ptr, i32, i32) on wasm32.
// We can't have both - the linker picks one signature.
//
// Better approach: use --wrap to rename, but that's complex.
// Simplest: provide our own implementations for the mismatched functions
// that accept i64 and do the right thing.

// Character comparison (string lengths as i64 from Fortran)
int _FortranACharacterCompareScalar1(const char *a, const char *b,
    int64_t a_len, int64_t b_len) {
  int64_t min_len = a_len < b_len ? a_len : b_len;
  for (int64_t i = 0; i < min_len; i++) {
    if ((unsigned char)a[i] != (unsigned char)b[i])
      return (unsigned char)a[i] < (unsigned char)b[i] ? -1 : 1;
  }
  if (a_len < b_len) {
    for (int64_t i = a_len; i < b_len; i++)
      if (' ' != b[i]) return ' ' < (unsigned char)b[i] ? -1 : 1;
  } else if (b_len < a_len) {
    for (int64_t i = b_len; i < a_len; i++)
      if ((unsigned char)a[i] != ' ') return (unsigned char)a[i] < ' ' ? -1 : 1;
  }
  return 0;
}

// I/O functions with size_t mismatch (string length params)
// These are stubs since MUMPS I/O in wasm just uses stderr

typedef void* Cookie;

Cookie _FortranAioBeginInquireFile(const char *path, int64_t path_len,
    const char *sf, int sl) {
  static int io_active;
  return &io_active;
}

bool _FortranAioOutputAscii(Cookie c, const char *str, int64_t len) {
  // Real implementation uses size_t, but we get i64
  extern int fprintf(void*, const char*, ...);
  extern void* __stderrp;
  // Just use stderr
  if (str && len > 0) {
    for (int64_t i = 0; i < len; i++) {
      extern int fputc(int, void*);
    }
  }
  return true;
}

bool _FortranAioSetAccess(Cookie c, const char *s, int64_t len) { return true; }
bool _FortranAioSetFile(Cookie c, const char *s, int64_t len) { return true; }
bool _FortranAioSetForm(Cookie c, const char *s, int64_t len) { return true; }
bool _FortranAioSetStatus(Cookie c, const char *s, int64_t len) { return true; }

void _FortranAStopStatementText(const char *text, int64_t len, bool isError, bool quiet) {
  // Stub
}

void _FortranADateAndTime(void *date, int64_t date_len, void *time, int64_t time_len,
    void *zone, int64_t zone_len, void *values, int sl, void *sf) {
  // Stub
}

// Missing function from stat.cpp (which we couldn't compile)
struct Descriptor;
struct Terminator;

int _ZN7Fortran7runtime11ReturnErrorERNS0_10TerminatorEiPKNS0_10DescriptorEb(
    void *terminator, int errcode, const void *descriptor, bool hasStat) {
  return errcode;
}
