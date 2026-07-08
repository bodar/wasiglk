/* wasi_compat.c — no-op stubs for functions wasi-libc omits.
 * See wasi_compat.h for why these exist. Never called at runtime. */
#include "wasi_compat.h"

FILE *popen(const char *command, const char *type) {
    (void)command;
    (void)type;
    return NULL;
}

int pclose(FILE *stream) {
    (void)stream;
    return -1;
}
