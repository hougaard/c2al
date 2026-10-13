/* Native implementation of the c2al natives (include/c2al.h) for the reference build:
 * the example C code is compiled with zig cc as a normal 32 bit program, and its results
 * are the "truth" the JS (and so the AL) translation is compared against. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static char logbuf[1 << 16];
static int loglen = 0;

void* c2al_malloc(int size) { return calloc(1, size); }
void c2al_free(void* p) { (void)p; }
void c2al_print(const char* s) { while (*s && loglen < (int)sizeof(logbuf) - 1) logbuf[loglen++] = *s++; }
void c2al_print_int(int v) { char t[16]; sprintf(t, "%d", v); c2al_print(t); }
void c2al_abort(const char* msg) { printf("E \"%s\"\n", msg); exit(1); }

/* result printers used by the generated test main */
static void json(const char* s)
{
    putchar('"');
    for (; *s; s++) {
        unsigned char ch = (unsigned char)*s;
        if (ch == '"' || ch == '\\') printf("\\%c", ch);
        else if (ch == '\n') printf("\\n");
        else if (ch == '\t') printf("\\t");
        else if (ch == '\r') printf("\\r");
        else if (ch < 32) printf("\\u%04x", ch);
        else putchar(ch);
    }
    putchar('"');
}

void h_int(int v) { printf("R %d\n", v); }
void h_big(long long v) { printf("R %lld\n", v); }
void h_text(const char* s) { printf("R "); json(s); putchar('\n'); }
void h_void(void) { printf("-\n"); }
void h_log_begin(void) { loglen = 0; }
void h_log(void) { logbuf[loglen] = 0; printf("L "); json(logbuf); putchar('\n'); }
char* h_dup(const char* s) { char* d = calloc(1, strlen(s) + 1); strcpy(d, s); return d; }
