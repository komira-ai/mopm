#include "shim.h"

#ifndef SHIM_OS_ADD
#error "SHIM_OS_ADD is not defined: the cflags_by_os of [native.shim] did not reach the compiler"
#endif

int shim_answer(void) { return shim_scale() * 7 + SHIM_OS_ADD; }
