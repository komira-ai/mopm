#ifndef SHIM_H
#define SHIM_H

/* The scale the build gives (-DSHIM_SCALE in mopm.toml). */
int shim_scale(void);

/* scale * 7, plus what the operating system's flags add: 42 on Linux, 43 on macOS. */
int shim_answer(void);

#endif
