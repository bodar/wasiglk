/* wasi_compat.h — force-included into the agt2agx build.
 *
 * AGiliTy's filename.c references popen()/pclose() in its pipe-I/O path
 * (try_open_pipe), which is only reached at runtime when a game filename
 * names a pipe (fc->special) — something the agt2agx converter never does.
 * wasi-libc does not declare or provide these functions, so we supply
 * prototypes here (and no-op definitions in wasi_compat.c) purely to satisfy
 * the compiler and linker. They are never actually called.
 */
#ifndef WASIGLK_WASI_COMPAT_H
#define WASIGLK_WASI_COMPAT_H
#include <stdio.h>
FILE *popen(const char *command, const char *type);
int pclose(FILE *stream);
#endif
