/*
 * c2al.h - the C library available to code translated by c2al.
 *
 * There is no libc in Business Central. Programs include this header instead of <stdio.h>,
 * <stdlib.h> and <string.h>. It provides three kinds of functions:
 *
 *   intrinsics  memset, memcpy, memmove, strlen      replaced by AL runtime procedures (Rt_*)
 *   natives     c2al_malloc, c2al_print, ...           implemented by hand in runtime/core.al
 *   plain C     strcmp, strcpy, atoi, ...              defined below, translated like your own code
 *
 * Only functions that are actually called end up in the AL codeunit (reachability analysis),
 * so the plain C functions here cost nothing when unused.
 *
 * The target is ILP32: char 8, short 16, int/long/pointers 32, long long 64 bits.
 */
#ifndef C2AL_H
#define C2AL_H

typedef unsigned int size_t;
typedef int ptrdiff_t;
typedef unsigned char uint8_t;
typedef signed char int8_t;
typedef unsigned short uint16_t;
typedef short int16_t;
typedef unsigned int uint32_t;
typedef int int32_t;
typedef long long int64_t;

#define NULL ((void*)0)
#define INT_MAX 2147483647
#define INT_MIN (-2147483647 - 1)
#define UINT_MAX 0xffffffffu

/* ---- intrinsics (runtime/core.al Rt_MemSet, Rt_MemCpy, Rt_StrLen) ---- */
void* memset(void* dst, int value, size_t count);
void* memcpy(void* dst, const void* src, size_t count);
void* memmove(void* dst, const void* src, size_t count);
size_t strlen(const char* s);

/* ---- natives (runtime/core.al) ---- */
void* c2al_malloc(int size);       /* bump allocator, memory is zeroed and never reused */
void c2al_free(void* p);           /* no-op */
void c2al_print(const char* s);    /* appends to the log, read it in AL with GetLog() */
void c2al_print_int(int v);
void c2al_abort(const char* msg);  /* raises an AL Error */

#define malloc(n) c2al_malloc(n)
#define calloc(n, size) c2al_malloc((n) * (size))
#define free(p) c2al_free(p)
#define assert(x) do { if (!(x)) c2al_abort("assertion failed: " #x); } while (0)

/* ---- plain C (translated together with the program) ---- */
static int strcmp(const char* a, const char* b)
{
    while (*a && *a == *b) { a++; b++; }
    return (unsigned char)*a - (unsigned char)*b;
}

static int strncmp(const char* a, const char* b, size_t n)
{
    while (n && *a && *a == *b) { a++; b++; n--; }
    if (n == 0) return 0;
    return (unsigned char)*a - (unsigned char)*b;
}

static char* strcpy(char* dst, const char* src)
{
    char* d = dst;
    while ((*d++ = *src++) != 0) {}
    return dst;
}

static char* strcat(char* dst, const char* src)
{
    strcpy(dst + strlen(dst), src);
    return dst;
}

static char* strchr(const char* s, int c)
{
    for (; *s; s++)
        if (*s == (char)c) return (char*)s;
    return c == 0 ? (char*)s : NULL;
}

static int memcmp(const void* a, const void* b, size_t n)
{
    const unsigned char* p = (const unsigned char*)a;
    const unsigned char* q = (const unsigned char*)b;
    for (; n; n--, p++, q++)
        if (*p != *q) return *p - *q;
    return 0;
}

static int c2al_isdigit(int c) { return c >= '0' && c <= '9'; }
static int c2al_isspace(int c) { return c == ' ' || c == '\t' || c == '\n' || c == '\r'; }
#define isdigit(c) c2al_isdigit(c)
#define isspace(c) c2al_isspace(c)

static int atoi(const char* s)
{
    int v = 0, neg = 0;
    while (isspace(*s)) s++;
    if (*s == '-' || *s == '+') neg = *s++ == '-';
    while (isdigit(*s)) v = v * 10 + (*s++ - '0');
    return neg ? -v : v;
}

#endif
