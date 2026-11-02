#include "shim.h"

#ifndef SHIM_SCALE
#error "SHIM_SCALE is not defined: the cflags of [native.shim] did not reach the compiler"
#endif

int shim_scale(void) { return SHIM_SCALE; }
