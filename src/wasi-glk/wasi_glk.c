/*
 * wasi_glk.c - WASI-compatible Glk implementation for Emglken
 *
 * This implements the Glk API using WASI stdin/stdout for I/O.
 * Output is sent as JSON to stdout, input is read as JSON from stdin.
 * This follows the RemGlk protocol for compatibility.
 *
 * Copyright (c) 2025 Emglken contributors
 * MIT licensed
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include "glk.h"

/* ============== Internal structures ============== */

#define MAGIC_WINDOW_NUM  0x474C4B57  /* 'GLKW' */
#define MAGIC_STREAM_NUM  0x474C4B53  /* 'GLKS' */
#define MAGIC_FILEREF_NUM 0x474C4B46  /* 'GLKF' */

struct glk_window_struct {
    glui32 magicnum;
    glui32 rock;
    glui32 type;
    glui32 id;

    /* Input state */
    int char_request;
    int line_request;
    int char_request_uni;
    int line_request_uni;
    char *line_buffer;
    glui32 *line_buffer_uni;
    glui32 line_buflen;

    /* Stream */
    strid_t str;
    strid_t echostr;

    /* Tree structure */
    winid_t parent;
    winid_t child1, child2;

    /* Linked list */
    winid_t prev, next;
};

struct glk_stream_struct {
    glui32 magicnum;
    glui32 rock;
    glui32 id;

    int type;  /* 0=window, 1=memory, 2=file */
    int readable;
    int writable;

    /* Memory stream */
    char *buf;
    glui32 *buf_uni;
    glui32 buflen;
    glui32 bufptr;
    int is_unicode;

    /* File stream */
    FILE *file;

    /* Associated window */
    winid_t win;

    /* Statistics */
    glui32 readcount;
    glui32 writecount;

    /* Linked list */
    strid_t prev, next;
};

struct glk_fileref_struct {
    glui32 magicnum;
    glui32 rock;
    glui32 id;

    char *filename;
    glui32 usage;
    int textmode;

    frefid_t prev, next;
};

/* ============== Global state ============== */

static winid_t gli_rootwin = NULL;
static winid_t gli_windowlist = NULL;
static strid_t gli_streamlist = NULL;
static strid_t gli_currentstr = NULL;
static frefid_t gli_filereflist = NULL;

static glui32 gli_window_id_counter = 1;
static glui32 gli_stream_id_counter = 1;
static glui32 gli_fileref_id_counter = 1;

/* Case conversion tables */
static unsigned char char_tolower_table[256];
static unsigned char char_toupper_table[256];
static int tables_initialized = 0;

/* JSON output buffer */
static char json_buffer[65536];
static int json_pos = 0;

/* ============== JSON output helpers ============== */

static void json_reset(void) {
    json_pos = 0;
    json_buffer[0] = '\0';
}

static void json_append(const char *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    json_pos += vsnprintf(json_buffer + json_pos, sizeof(json_buffer) - json_pos, fmt, args);
    va_end(args);
}

static void json_flush(void) {
    if (json_pos > 0) {
        printf("%s\n", json_buffer);
        fflush(stdout);
        json_reset();
    }
}

/* Escape a string for JSON output */
static void json_append_escaped_string(const char *s) {
    json_append("\"");
    while (*s) {
        unsigned char c = *s++;
        if (c == '"') json_append("\\\"");
        else if (c == '\\') json_append("\\\\");
        else if (c == '\n') json_append("\\n");
        else if (c == '\r') json_append("\\r");
        else if (c == '\t') json_append("\\t");
        else if (c < 32) json_append("\\u%04x", c);
        else json_append("%c", c);
    }
    json_append("\"");
}

/* ============== Initialization ============== */

static void gli_initialize_tables(void) {
    if (tables_initialized) return;
    tables_initialized = 1;

    for (int ix = 0; ix < 256; ix++) {
        char_toupper_table[ix] = ix;
        char_tolower_table[ix] = ix;
    }

    for (int ix = 'A'; ix <= 'Z'; ix++) {
        char_tolower_table[ix] = ix + ('a' - 'A');
        char_toupper_table[ix + ('a' - 'A')] = ix;
    }

    /* Latin-1 characters */
    for (int ix = 0xC0; ix <= 0xDE; ix++) {
        if (ix != 0xD7) {
            char_tolower_table[ix] = ix + 0x20;
            char_toupper_table[ix + 0x20] = ix;
        }
    }
}

/* ============== Core functions ============== */

void glk_exit(void) {
    json_reset();
    json_append("{\"type\":\"exit\"}");
    json_flush();
    exit(0);
}

void glk_set_interrupt_handler(void (*func)(void)) {
    /* WASI doesn't support interrupts in the same way */
}

void glk_tick(void) {
    /* No-op for WASI */
}

glui32 glk_gestalt(glui32 sel, glui32 val) {
    return glk_gestalt_ext(sel, val, NULL, 0);
}

glui32 glk_gestalt_ext(glui32 sel, glui32 val, glui32 *arr, glui32 arrlen) {
    switch (sel) {
        case gestalt_Version:
            return 0x00000706; /* 0.7.6 */

        case gestalt_CharInput:
            if (val <= 0x7F || (val >= 0xA0 && val <= 0xFF))
                return 1;
            if (val >= 0x100000000 - keycode_MAXVAL)
                return 1;
            return 0;

        case gestalt_LineInput:
            if (val <= 0x7F || (val >= 0xA0 && val <= 0xFF))
                return 1;
            return 0;

        case gestalt_CharOutput:
            if (val <= 0x7F || (val >= 0xA0 && val <= 0xFF)) {
                if (arr && arrlen >= 1)
                    arr[0] = 1;
                return gestalt_CharOutput_ExactPrint;
            }
            if (arr && arrlen >= 1)
                arr[0] = 0;
            return gestalt_CharOutput_CannotPrint;

        case gestalt_Unicode:
            return 1;

        case gestalt_UnicodeNorm:
            return 1;

        case gestalt_Timer:
            return 0; /* Timers not supported in basic WASI */

        case gestalt_Graphics:
        case gestalt_DrawImage:
        case gestalt_GraphicsTransparency:
        case gestalt_GraphicsCharInput:
        case gestalt_DrawImageScale:
            return 0;

        case gestalt_Sound:
        case gestalt_SoundVolume:
        case gestalt_SoundNotify:
        case gestalt_SoundMusic:
        case gestalt_Sound2:
            return 0;

        case gestalt_Hyperlinks:
        case gestalt_HyperlinkInput:
            return 1;

        case gestalt_MouseInput:
            return 0;

        case gestalt_DateTime:
            return 1;

        case gestalt_LineInputEcho:
            return 1;

        case gestalt_LineTerminators:
            return 1;

        case gestalt_LineTerminatorKey:
            return 0;

        case gestalt_ResourceStream:
            return 1;

        default:
            return 0;
    }
}

unsigned char glk_char_to_lower(unsigned char ch) {
    gli_initialize_tables();
    return char_tolower_table[ch];
}

unsigned char glk_char_to_upper(unsigned char ch) {
    gli_initialize_tables();
    return char_toupper_table[ch];
}

/* ============== Window functions ============== */

winid_t glk_window_get_root(void) {
    return gli_rootwin;
}

static strid_t gli_stream_open_window(winid_t win);

winid_t glk_window_open(winid_t split, glui32 method, glui32 size,
    glui32 wintype, glui32 rock) {

    winid_t win = (winid_t)malloc(sizeof(struct glk_window_struct));
    if (!win) return NULL;

    memset(win, 0, sizeof(struct glk_window_struct));
    win->magicnum = MAGIC_WINDOW_NUM;
    win->rock = rock;
    win->type = wintype;
    win->id = gli_window_id_counter++;

    /* Add to list */
    win->next = gli_windowlist;
    if (gli_windowlist) gli_windowlist->prev = win;
    gli_windowlist = win;

    /* Create window stream */
    win->str = gli_stream_open_window(win);

    if (!gli_rootwin) {
        gli_rootwin = win;
    }

    /* Output window creation as JSON */
    json_reset();
    json_append("{\"type\":\"update\",\"content\":[{\"id\":%u,\"win\":%u,\"op\":\"create\",\"wintype\":%u}]}",
        win->id, win->id, wintype);
    json_flush();

    return win;
}

void glk_window_close(winid_t win, stream_result_t *result) {
    if (!win) return;

    if (result) {
        result->readcount = win->str ? win->str->readcount : 0;
        result->writecount = win->str ? win->str->writecount : 0;
    }

    /* Close associated stream */
    if (win->str) {
        win->str->win = NULL;
        glk_stream_close(win->str, NULL);
        win->str = NULL;
    }

    /* Remove from list */
    if (win->prev) win->prev->next = win->next;
    else gli_windowlist = win->next;
    if (win->next) win->next->prev = win->prev;

    if (gli_rootwin == win) gli_rootwin = NULL;

    free(win);
}

void glk_window_get_size(winid_t win, glui32 *widthptr, glui32 *heightptr) {
    if (widthptr) *widthptr = 80;
    if (heightptr) *heightptr = 24;
}

void glk_window_set_arrangement(winid_t win, glui32 method,
    glui32 size, winid_t keywin) {
    /* Stub */
}

void glk_window_get_arrangement(winid_t win, glui32 *methodptr,
    glui32 *sizeptr, winid_t *keywinptr) {
    if (methodptr) *methodptr = 0;
    if (sizeptr) *sizeptr = 0;
    if (keywinptr) *keywinptr = NULL;
}

winid_t glk_window_iterate(winid_t win, glui32 *rockptr) {
    if (!win) win = gli_windowlist;
    else win = win->next;

    if (win && rockptr) *rockptr = win->rock;
    return win;
}

glui32 glk_window_get_rock(winid_t win) {
    if (!win) return 0;
    return win->rock;
}

glui32 glk_window_get_type(winid_t win) {
    if (!win) return 0;
    return win->type;
}

winid_t glk_window_get_parent(winid_t win) {
    if (!win) return NULL;
    return win->parent;
}

winid_t glk_window_get_sibling(winid_t win) {
    if (!win || !win->parent) return NULL;
    if (win->parent->child1 == win) return win->parent->child2;
    return win->parent->child1;
}

void glk_window_clear(winid_t win) {
    if (!win) return;
    json_reset();
    json_append("{\"type\":\"update\",\"content\":[{\"id\":%u,\"op\":\"clear\"}]}", win->id);
    json_flush();
}

void glk_window_move_cursor(winid_t win, glui32 xpos, glui32 ypos) {
    /* Stub for grid windows */
}

strid_t glk_window_get_stream(winid_t win) {
    if (!win) return NULL;
    return win->str;
}

void glk_window_set_echo_stream(winid_t win, strid_t str) {
    if (!win) return;
    win->echostr = str;
}

strid_t glk_window_get_echo_stream(winid_t win) {
    if (!win) return NULL;
    return win->echostr;
}

void glk_set_window(winid_t win) {
    if (win) gli_currentstr = win->str;
    else gli_currentstr = NULL;
}

/* ============== Stream functions ============== */

static strid_t gli_stream_new(int type, int readable, int writable, glui32 rock) {
    strid_t str = (strid_t)malloc(sizeof(struct glk_stream_struct));
    if (!str) return NULL;

    memset(str, 0, sizeof(struct glk_stream_struct));
    str->magicnum = MAGIC_STREAM_NUM;
    str->rock = rock;
    str->id = gli_stream_id_counter++;
    str->type = type;
    str->readable = readable;
    str->writable = writable;

    str->next = gli_streamlist;
    if (gli_streamlist) gli_streamlist->prev = str;
    gli_streamlist = str;

    return str;
}

static strid_t gli_stream_open_window(winid_t win) {
    strid_t str = gli_stream_new(0, 0, 1, 0);
    if (str) {
        str->win = win;
    }
    return str;
}

strid_t glk_stream_open_file(frefid_t fileref, glui32 fmode, glui32 rock) {
    if (!fileref) return NULL;

    const char *modestr;
    int readable = 0, writable = 0;

    switch (fmode) {
        case filemode_Write:
            modestr = fileref->textmode ? "w" : "wb";
            writable = 1;
            break;
        case filemode_Read:
            modestr = fileref->textmode ? "r" : "rb";
            readable = 1;
            break;
        case filemode_ReadWrite:
            modestr = fileref->textmode ? "r+" : "r+b";
            readable = writable = 1;
            break;
        case filemode_WriteAppend:
            modestr = fileref->textmode ? "a" : "ab";
            writable = 1;
            break;
        default:
            return NULL;
    }

    FILE *file = fopen(fileref->filename, modestr);
    if (!file) return NULL;

    strid_t str = gli_stream_new(2, readable, writable, rock);
    if (!str) {
        fclose(file);
        return NULL;
    }

    str->file = file;
    return str;
}

strid_t glk_stream_open_memory(char *buf, glui32 buflen, glui32 fmode, glui32 rock) {
    int readable = 0, writable = 0;

    if (fmode == filemode_Read) readable = 1;
    else if (fmode == filemode_Write) writable = 1;
    else if (fmode == filemode_ReadWrite) readable = writable = 1;

    strid_t str = gli_stream_new(1, readable, writable, rock);
    if (!str) return NULL;

    str->buf = buf;
    str->buflen = buflen;
    str->bufptr = 0;
    str->is_unicode = 0;

    return str;
}

void glk_stream_close(strid_t str, stream_result_t *result) {
    if (!str) return;

    if (result) {
        result->readcount = str->readcount;
        result->writecount = str->writecount;
    }

    if (str->file) {
        fclose(str->file);
        str->file = NULL;
    }

    if (gli_currentstr == str) gli_currentstr = NULL;

    if (str->prev) str->prev->next = str->next;
    else gli_streamlist = str->next;
    if (str->next) str->next->prev = str->prev;

    free(str);
}

strid_t glk_stream_iterate(strid_t str, glui32 *rockptr) {
    if (!str) str = gli_streamlist;
    else str = str->next;

    if (str && rockptr) *rockptr = str->rock;
    return str;
}

glui32 glk_stream_get_rock(strid_t str) {
    if (!str) return 0;
    return str->rock;
}

void glk_stream_set_position(strid_t str, glsi32 pos, glui32 seekmode) {
    if (!str) return;

    if (str->type == 2 && str->file) {
        int whence = (seekmode == seekmode_Current) ? SEEK_CUR :
                     (seekmode == seekmode_End) ? SEEK_END : SEEK_SET;
        fseek(str->file, pos, whence);
    } else if (str->type == 1) {
        if (seekmode == seekmode_Current) str->bufptr += pos;
        else if (seekmode == seekmode_End) str->bufptr = str->buflen + pos;
        else str->bufptr = pos;

        if (str->bufptr > str->buflen) str->bufptr = str->buflen;
    }
}

glui32 glk_stream_get_position(strid_t str) {
    if (!str) return 0;

    if (str->type == 2 && str->file) {
        return ftell(str->file);
    } else if (str->type == 1) {
        return str->bufptr;
    }
    return 0;
}

void glk_stream_set_current(strid_t str) {
    gli_currentstr = str;
}

strid_t glk_stream_get_current(void) {
    return gli_currentstr;
}

/* ============== Output functions ============== */

static void gli_put_char_to_stream(strid_t str, unsigned char ch) {
    if (!str || !str->writable) return;

    str->writecount++;

    if (str->type == 0 && str->win) {
        /* Window stream - output as JSON */
        char buf[2] = { ch, 0 };
        json_reset();
        json_append("{\"type\":\"update\",\"content\":[{\"id\":%u,\"text\":", str->win->id);
        json_append_escaped_string(buf);
        json_append("}]}");
        json_flush();
    } else if (str->type == 1 && str->buf) {
        /* Memory stream */
        if (str->bufptr < str->buflen) {
            str->buf[str->bufptr++] = ch;
        }
    } else if (str->type == 2 && str->file) {
        /* File stream */
        fputc(ch, str->file);
    }
}

void glk_put_char(unsigned char ch) {
    gli_put_char_to_stream(gli_currentstr, ch);
}

void glk_put_char_stream(strid_t str, unsigned char ch) {
    gli_put_char_to_stream(str, ch);
}

void glk_put_string(char *s) {
    glk_put_string_stream(gli_currentstr, s);
}

void glk_put_string_stream(strid_t str, char *s) {
    if (!s) return;
    while (*s) gli_put_char_to_stream(str, *s++);
}

void glk_put_buffer(char *buf, glui32 len) {
    glk_put_buffer_stream(gli_currentstr, buf, len);
}

void glk_put_buffer_stream(strid_t str, char *buf, glui32 len) {
    if (!buf) return;
    for (glui32 i = 0; i < len; i++) {
        gli_put_char_to_stream(str, buf[i]);
    }
}

void glk_set_style(glui32 styl) {
    /* Style changes could be sent as JSON if needed */
}

void glk_set_style_stream(strid_t str, glui32 styl) {
    /* Stub */
}

/* ============== Input functions ============== */

glsi32 glk_get_char_stream(strid_t str) {
    if (!str || !str->readable) return -1;

    str->readcount++;

    if (str->type == 1 && str->buf) {
        if (str->bufptr < str->buflen) {
            return (unsigned char)str->buf[str->bufptr++];
        }
        return -1;
    } else if (str->type == 2 && str->file) {
        return fgetc(str->file);
    }

    return -1;
}

glui32 glk_get_line_stream(strid_t str, char *buf, glui32 len) {
    if (!str || !str->readable || !buf || len == 0) return 0;

    glui32 count = 0;

    if (str->type == 1 && str->buf) {
        while (count < len - 1 && str->bufptr < str->buflen) {
            char ch = str->buf[str->bufptr++];
            buf[count++] = ch;
            str->readcount++;
            if (ch == '\n') break;
        }
    } else if (str->type == 2 && str->file) {
        if (fgets(buf, len, str->file)) {
            count = strlen(buf);
            str->readcount += count;
        }
    }

    buf[count] = '\0';
    return count;
}

glui32 glk_get_buffer_stream(strid_t str, char *buf, glui32 len) {
    if (!str || !str->readable || !buf) return 0;

    glui32 count = 0;

    if (str->type == 1 && str->buf) {
        while (count < len && str->bufptr < str->buflen) {
            buf[count++] = str->buf[str->bufptr++];
            str->readcount++;
        }
    } else if (str->type == 2 && str->file) {
        count = fread(buf, 1, len, str->file);
        str->readcount += count;
    }

    return count;
}

/* ============== File reference functions ============== */

static frefid_t gli_fileref_new(const char *filename, glui32 usage, glui32 rock) {
    frefid_t fref = (frefid_t)malloc(sizeof(struct glk_fileref_struct));
    if (!fref) return NULL;

    memset(fref, 0, sizeof(struct glk_fileref_struct));
    fref->magicnum = MAGIC_FILEREF_NUM;
    fref->rock = rock;
    fref->id = gli_fileref_id_counter++;
    fref->usage = usage;
    fref->textmode = (usage & fileusage_TextMode) != 0;

    fref->filename = strdup(filename);
    if (!fref->filename) {
        free(fref);
        return NULL;
    }

    fref->next = gli_filereflist;
    if (gli_filereflist) gli_filereflist->prev = fref;
    gli_filereflist = fref;

    return fref;
}

frefid_t glk_fileref_create_temp(glui32 usage, glui32 rock) {
    char filename[64];
    snprintf(filename, sizeof(filename), "/tmp/glktmp_%u", gli_fileref_id_counter);
    return gli_fileref_new(filename, usage, rock);
}

frefid_t glk_fileref_create_by_name(glui32 usage, char *name, glui32 rock) {
    if (!name) return NULL;
    return gli_fileref_new(name, usage, rock);
}

frefid_t glk_fileref_create_by_prompt(glui32 usage, glui32 fmode, glui32 rock) {
    /* In WASI, we can't really prompt interactively.
       Output a request and read the filename from stdin */
    json_reset();
    json_append("{\"type\":\"fileref_prompt\",\"usage\":%u,\"fmode\":%u}", usage, fmode);
    json_flush();

    char filename[256];
    if (fgets(filename, sizeof(filename), stdin)) {
        /* Remove trailing newline */
        size_t len = strlen(filename);
        if (len > 0 && filename[len-1] == '\n') filename[len-1] = '\0';
        return gli_fileref_new(filename, usage, rock);
    }
    return NULL;
}

frefid_t glk_fileref_create_from_fileref(glui32 usage, frefid_t fref, glui32 rock) {
    if (!fref) return NULL;
    return gli_fileref_new(fref->filename, usage, rock);
}

void glk_fileref_destroy(frefid_t fref) {
    if (!fref) return;

    if (fref->prev) fref->prev->next = fref->next;
    else gli_filereflist = fref->next;
    if (fref->next) fref->next->prev = fref->prev;

    free(fref->filename);
    free(fref);
}

frefid_t glk_fileref_iterate(frefid_t fref, glui32 *rockptr) {
    if (!fref) fref = gli_filereflist;
    else fref = fref->next;

    if (fref && rockptr) *rockptr = fref->rock;
    return fref;
}

glui32 glk_fileref_get_rock(frefid_t fref) {
    if (!fref) return 0;
    return fref->rock;
}

void glk_fileref_delete_file(frefid_t fref) {
    if (!fref) return;
    remove(fref->filename);
}

glui32 glk_fileref_does_file_exist(frefid_t fref) {
    if (!fref) return 0;
    FILE *f = fopen(fref->filename, "r");
    if (f) {
        fclose(f);
        return 1;
    }
    return 0;
}

/* ============== Event functions ============== */

void glk_select(event_t *event) {
    if (!event) return;

    event->type = evtype_None;
    event->win = NULL;
    event->val1 = 0;
    event->val2 = 0;

    /* Find a window with an input request */
    winid_t win;
    for (win = gli_windowlist; win; win = win->next) {
        if (win->char_request || win->line_request ||
            win->char_request_uni || win->line_request_uni) {
            break;
        }
    }

    if (!win) {
        /* No input request - this is technically valid but we'll just return */
        return;
    }

    /* Output input request as JSON */
    json_reset();
    if (win->line_request || win->line_request_uni) {
        json_append("{\"type\":\"input\",\"gen\":1,\"windows\":[{\"id\":%u,\"type\":\"line\"}]}", win->id);
    } else {
        json_append("{\"type\":\"input\",\"gen\":1,\"windows\":[{\"id\":%u,\"type\":\"char\"}]}", win->id);
    }
    json_flush();

    /* Read input from stdin */
    char input[1024];
    if (!fgets(input, sizeof(input), stdin)) {
        /* EOF - exit */
        glk_exit();
    }

    /* Remove trailing newline */
    size_t len = strlen(input);
    if (len > 0 && input[len-1] == '\n') {
        input[--len] = '\0';
    }

    if (win->line_request) {
        /* Copy input to buffer */
        if (win->line_buffer) {
            glui32 copylen = len;
            if (copylen > win->line_buflen - 1) copylen = win->line_buflen - 1;
            memcpy(win->line_buffer, input, copylen);
            win->line_buffer[copylen] = '\0';

            event->type = evtype_LineInput;
            event->win = win;
            event->val1 = copylen;
        }
        win->line_request = 0;
        win->line_buffer = NULL;
    } else if (win->char_request) {
        event->type = evtype_CharInput;
        event->win = win;
        if (len > 0) {
            event->val1 = (unsigned char)input[0];
        } else {
            event->val1 = keycode_Return;
        }
        win->char_request = 0;
    }
}

void glk_select_poll(event_t *event) {
    if (!event) return;
    event->type = evtype_None;
    event->win = NULL;
    event->val1 = 0;
    event->val2 = 0;
}

void glk_request_timer_events(glui32 millisecs) {
    /* Timers not supported in basic WASI */
}

void glk_request_line_event(winid_t win, char *buf, glui32 maxlen, glui32 initlen) {
    if (!win) return;
    win->line_request = 1;
    win->line_buffer = buf;
    win->line_buflen = maxlen;

    /* Copy initial text if any */
    if (initlen > 0 && buf) {
        /* Already in buffer */
    }
}

void glk_request_char_event(winid_t win) {
    if (!win) return;
    win->char_request = 1;
}

void glk_request_mouse_event(winid_t win) {
    /* Not supported */
}

void glk_cancel_line_event(winid_t win, event_t *event) {
    if (!win) return;

    if (event) {
        event->type = evtype_None;
        event->win = NULL;
        event->val1 = 0;
        event->val2 = 0;
    }

    win->line_request = 0;
    win->line_buffer = NULL;
}

void glk_cancel_char_event(winid_t win) {
    if (!win) return;
    win->char_request = 0;
}

void glk_cancel_mouse_event(winid_t win) {
    /* Not supported */
}

/* ============== Style hints ============== */

void glk_stylehint_set(glui32 wintype, glui32 styl, glui32 hint, glsi32 val) {
    /* Stub */
}

void glk_stylehint_clear(glui32 wintype, glui32 styl, glui32 hint) {
    /* Stub */
}

glui32 glk_style_distinguish(winid_t win, glui32 styl1, glui32 styl2) {
    return (styl1 != styl2) ? 1 : 0;
}

glui32 glk_style_measure(winid_t win, glui32 styl, glui32 hint, glui32 *result) {
    if (result) *result = 0;
    return 0;
}

/* ============== Optional module stubs ============== */

#ifdef GLK_MODULE_LINE_ECHO
void glk_set_echo_line_event(winid_t win, glui32 val) {
    /* Stub */
}
#endif

#ifdef GLK_MODULE_LINE_TERMINATORS
void glk_set_terminators_line_event(winid_t win, glui32 *keycodes, glui32 count) {
    /* Stub */
}
#endif

#ifdef GLK_MODULE_UNICODE

glui32 glk_buffer_to_lower_case_uni(glui32 *buf, glui32 len, glui32 numchars) {
    for (glui32 i = 0; i < numchars && i < len; i++) {
        if (buf[i] >= 'A' && buf[i] <= 'Z') {
            buf[i] = buf[i] + ('a' - 'A');
        }
    }
    return numchars;
}

glui32 glk_buffer_to_upper_case_uni(glui32 *buf, glui32 len, glui32 numchars) {
    for (glui32 i = 0; i < numchars && i < len; i++) {
        if (buf[i] >= 'a' && buf[i] <= 'z') {
            buf[i] = buf[i] - ('a' - 'A');
        }
    }
    return numchars;
}

glui32 glk_buffer_to_title_case_uni(glui32 *buf, glui32 len, glui32 numchars, glui32 lowerrest) {
    if (numchars > 0 && len > 0) {
        if (buf[0] >= 'a' && buf[0] <= 'z') {
            buf[0] = buf[0] - ('a' - 'A');
        }
    }
    if (lowerrest) {
        for (glui32 i = 1; i < numchars && i < len; i++) {
            if (buf[i] >= 'A' && buf[i] <= 'Z') {
                buf[i] = buf[i] + ('a' - 'A');
            }
        }
    }
    return numchars;
}

void glk_put_char_uni(glui32 ch) {
    if (ch < 0x80) {
        glk_put_char((unsigned char)ch);
    } else {
        /* UTF-8 encode */
        char buf[4];
        int len = 0;
        if (ch < 0x800) {
            buf[len++] = 0xC0 | (ch >> 6);
            buf[len++] = 0x80 | (ch & 0x3F);
        } else if (ch < 0x10000) {
            buf[len++] = 0xE0 | (ch >> 12);
            buf[len++] = 0x80 | ((ch >> 6) & 0x3F);
            buf[len++] = 0x80 | (ch & 0x3F);
        } else {
            buf[len++] = 0xF0 | (ch >> 18);
            buf[len++] = 0x80 | ((ch >> 12) & 0x3F);
            buf[len++] = 0x80 | ((ch >> 6) & 0x3F);
            buf[len++] = 0x80 | (ch & 0x3F);
        }
        glk_put_buffer(buf, len);
    }
}

void glk_put_string_uni(glui32 *s) {
    if (!s) return;
    while (*s) glk_put_char_uni(*s++);
}

void glk_put_buffer_uni(glui32 *buf, glui32 len) {
    for (glui32 i = 0; i < len; i++) {
        glk_put_char_uni(buf[i]);
    }
}

void glk_put_char_stream_uni(strid_t str, glui32 ch) {
    strid_t save = gli_currentstr;
    gli_currentstr = str;
    glk_put_char_uni(ch);
    gli_currentstr = save;
}

void glk_put_string_stream_uni(strid_t str, glui32 *s) {
    strid_t save = gli_currentstr;
    gli_currentstr = str;
    glk_put_string_uni(s);
    gli_currentstr = save;
}

void glk_put_buffer_stream_uni(strid_t str, glui32 *buf, glui32 len) {
    strid_t save = gli_currentstr;
    gli_currentstr = str;
    glk_put_buffer_uni(buf, len);
    gli_currentstr = save;
}

glsi32 glk_get_char_stream_uni(strid_t str) {
    return glk_get_char_stream(str);
}

glui32 glk_get_buffer_stream_uni(strid_t str, glui32 *buf, glui32 len) {
    /* Simplified - doesn't handle UTF-8 properly */
    char *cbuf = (char *)malloc(len);
    if (!cbuf) return 0;
    glui32 count = glk_get_buffer_stream(str, cbuf, len);
    for (glui32 i = 0; i < count; i++) {
        buf[i] = (unsigned char)cbuf[i];
    }
    free(cbuf);
    return count;
}

glui32 glk_get_line_stream_uni(strid_t str, glui32 *buf, glui32 len) {
    char *cbuf = (char *)malloc(len);
    if (!cbuf) return 0;
    glui32 count = glk_get_line_stream(str, cbuf, len);
    for (glui32 i = 0; i < count; i++) {
        buf[i] = (unsigned char)cbuf[i];
    }
    free(cbuf);
    return count;
}

strid_t glk_stream_open_file_uni(frefid_t fileref, glui32 fmode, glui32 rock) {
    return glk_stream_open_file(fileref, fmode, rock);
}

strid_t glk_stream_open_memory_uni(glui32 *buf, glui32 buflen, glui32 fmode, glui32 rock) {
    int readable = 0, writable = 0;

    if (fmode == filemode_Read) readable = 1;
    else if (fmode == filemode_Write) writable = 1;
    else if (fmode == filemode_ReadWrite) readable = writable = 1;

    strid_t str = gli_stream_new(1, readable, writable, rock);
    if (!str) return NULL;

    str->buf_uni = buf;
    str->buflen = buflen;
    str->bufptr = 0;
    str->is_unicode = 1;

    return str;
}

void glk_request_char_event_uni(winid_t win) {
    if (!win) return;
    win->char_request_uni = 1;
}

void glk_request_line_event_uni(winid_t win, glui32 *buf, glui32 maxlen, glui32 initlen) {
    if (!win) return;
    win->line_request_uni = 1;
    win->line_buffer_uni = buf;
    win->line_buflen = maxlen;
}

#endif /* GLK_MODULE_UNICODE */

#ifdef GLK_MODULE_UNICODE_NORM
glui32 glk_buffer_canon_decompose_uni(glui32 *buf, glui32 len, glui32 numchars) {
    return numchars; /* Stub */
}

glui32 glk_buffer_canon_normalize_uni(glui32 *buf, glui32 len, glui32 numchars) {
    return numchars; /* Stub */
}
#endif

#ifdef GLK_MODULE_HYPERLINKS
void glk_set_hyperlink(glui32 linkval) {
    /* Stub */
}

void glk_set_hyperlink_stream(strid_t str, glui32 linkval) {
    /* Stub */
}

void glk_request_hyperlink_event(winid_t win) {
    /* Stub */
}

void glk_cancel_hyperlink_event(winid_t win) {
    /* Stub */
}
#endif

#ifdef GLK_MODULE_DATETIME

#include <time.h>

void glk_current_time(glktimeval_t *time) {
    if (!time) return;
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);

    time->high_sec = (ts.tv_sec >> 32) & 0xFFFFFFFF;
    time->low_sec = ts.tv_sec & 0xFFFFFFFF;
    time->microsec = ts.tv_nsec / 1000;
}

glsi32 glk_current_simple_time(glui32 factor) {
    if (factor == 0) return 0;
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    return (glsi32)(ts.tv_sec / factor);
}

void glk_time_to_date_utc(glktimeval_t *time, glkdate_t *date) {
    if (!time || !date) return;
    time_t secs = ((time_t)time->high_sec << 32) | time->low_sec;
    struct tm *tm = gmtime(&secs);
    if (tm) {
        date->year = tm->tm_year + 1900;
        date->month = tm->tm_mon + 1;
        date->day = tm->tm_mday;
        date->weekday = tm->tm_wday;
        date->hour = tm->tm_hour;
        date->minute = tm->tm_min;
        date->second = tm->tm_sec;
        date->microsec = time->microsec;
    }
}

void glk_time_to_date_local(glktimeval_t *time, glkdate_t *date) {
    if (!time || !date) return;
    time_t secs = ((time_t)time->high_sec << 32) | time->low_sec;
    struct tm *tm = localtime(&secs);
    if (tm) {
        date->year = tm->tm_year + 1900;
        date->month = tm->tm_mon + 1;
        date->day = tm->tm_mday;
        date->weekday = tm->tm_wday;
        date->hour = tm->tm_hour;
        date->minute = tm->tm_min;
        date->second = tm->tm_sec;
        date->microsec = time->microsec;
    }
}

void glk_simple_time_to_date_utc(glsi32 time, glui32 factor, glkdate_t *date) {
    glktimeval_t tv;
    tv.high_sec = 0;
    tv.low_sec = (glui32)time * factor;
    tv.microsec = 0;
    glk_time_to_date_utc(&tv, date);
}

void glk_simple_time_to_date_local(glsi32 time, glui32 factor, glkdate_t *date) {
    glktimeval_t tv;
    tv.high_sec = 0;
    tv.low_sec = (glui32)time * factor;
    tv.microsec = 0;
    glk_time_to_date_local(&tv, date);
}

void glk_date_to_time_utc(glkdate_t *date, glktimeval_t *time) {
    if (!date || !time) return;
    struct tm tm = {0};
    tm.tm_year = date->year - 1900;
    tm.tm_mon = date->month - 1;
    tm.tm_mday = date->day;
    tm.tm_hour = date->hour;
    tm.tm_min = date->minute;
    tm.tm_sec = date->second;
    time_t secs = timegm(&tm);
    time->high_sec = (secs >> 32) & 0xFFFFFFFF;
    time->low_sec = secs & 0xFFFFFFFF;
    time->microsec = date->microsec;
}

void glk_date_to_time_local(glkdate_t *date, glktimeval_t *time) {
    if (!date || !time) return;
    struct tm tm = {0};
    tm.tm_year = date->year - 1900;
    tm.tm_mon = date->month - 1;
    tm.tm_mday = date->day;
    tm.tm_hour = date->hour;
    tm.tm_min = date->minute;
    tm.tm_sec = date->second;
    time_t secs = mktime(&tm);
    time->high_sec = (secs >> 32) & 0xFFFFFFFF;
    time->low_sec = secs & 0xFFFFFFFF;
    time->microsec = date->microsec;
}

glsi32 glk_date_to_simple_time_utc(glkdate_t *date, glui32 factor) {
    if (!date || factor == 0) return 0;
    glktimeval_t time;
    glk_date_to_time_utc(date, &time);
    return (glsi32)(time.low_sec / factor);
}

glsi32 glk_date_to_simple_time_local(glkdate_t *date, glui32 factor) {
    if (!date || factor == 0) return 0;
    glktimeval_t time;
    glk_date_to_time_local(date, &time);
    return (glsi32)(time.low_sec / factor);
}

#endif /* GLK_MODULE_DATETIME */

#ifdef GLK_MODULE_RESOURCE_STREAM
strid_t glk_stream_open_resource(glui32 filenum, glui32 rock) {
    return NULL; /* Resources not supported in basic WASI version */
}

strid_t glk_stream_open_resource_uni(glui32 filenum, glui32 rock) {
    return NULL;
}
#endif

/* ============== Main entry point wrapper ============== */

/* The interpreter defines glk_main(). We provide main() which sets up
   the Glk environment and calls glk_main(). */

int main(int argc, char **argv) {
    gli_initialize_tables();

    /* Output initialization message */
    json_reset();
    json_append("{\"type\":\"init\",\"version\":\"0.7.6\",\"support\":[\"unicode\",\"hyperlinks\",\"datetime\"]}");
    json_flush();

    glk_main();

    glk_exit();
    return 0;
}
