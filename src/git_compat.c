// git_compat.c - Compatibility shims for the Git interpreter
//
// The Git interpreter's git_unix.c is missing fatalErrorI which is
// declared in git.h but only implemented in git_windows.c.
// We provide it here to avoid modifying the submodule.

#include <stdio.h>
#include <stdlib.h>

// Declared in git.h, implemented here
void fatalErrorI(const char* s, int i)
{
    fprintf(stderr, "*** fatal error: %s: %d ***\n", s, i);
    exit(1);
}
