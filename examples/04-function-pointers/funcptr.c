/* 04-function-pointers: callbacks, tables of functions, a generic sort.
 * A C function pointer is a small integer id. Calls through it go to a generated
 * CallFn<n> / CallFnV<n> procedure: a 'case' over every function whose address is taken. */
#include "c2al.h"

typedef int (*binop_t)(int, int);

static int add(int a, int b) { return a + b; }
static int sub(int a, int b) { return a - b; }
static int mul(int a, int b) { return a * b; }
static int max(int a, int b) { return a > b ? a : b; }

static const struct {
    char sym;
    binop_t fn;
} ops[] = { { '+', add }, { '-', sub }, { '*', mul }, { 'M', max } };

/* looks the operator up in a table of function pointers */
int calc(int a, int op, int b)
{
    for (int i = 0; i < (int)(sizeof(ops) / sizeof(ops[0])); i++)
        if (ops[i].sym == op)
            return ops[i].fn(a, b);
    return 0;
}

/* evaluates "3+4*2-1" left to right (no precedence) */
int eval(const char* s)
{
    int acc = 0;
    while (*s >= '0' && *s <= '9')
        acc = acc * 10 + (*s++ - '0');
    while (*s) {
        int op = *s++, v = 0;
        while (*s >= '0' && *s <= '9')
            v = v * 10 + (*s++ - '0');
        acc = calc(acc, op, v);
    }
    return acc;
}

/* fold over an array with any binop */
static int fold(const int* a, int n, int init, binop_t f)
{
    for (int i = 0; i < n; i++)
        init = f(init, a[i]);
    return init;
}

static int data[] = { 3, -1, 4, 1, -5, 9, 2, 6 };

int fold_demo(int which)
{
    binop_t fs[] = { add, mul, max };
    return fold(data, 8, which == 1 ? 1 : which == 2 ? -1000 : 0, fs[which]);
}

/* ---- qsort style: void* elements and a comparator ---- */
static void sort(void* base, int n, int size, int (*cmp)(const void*, const void*))
{
    char* b = base;
    char tmp[32];
    for (int i = 1; i < n; i++) {   /* insertion sort */
        memcpy(tmp, b + i * size, size);
        int j = i - 1;
        while (j >= 0 && cmp(b + j * size, tmp) > 0) {
            memcpy(b + (j + 1) * size, b + j * size, size);
            j--;
        }
        memcpy(b + (j + 1) * size, tmp, size);
    }
}

static int by_value(const void* a, const void* b) { return *(const int*)a - *(const int*)b; }
static int by_value_desc(const void* a, const void* b) { return *(const int*)b - *(const int*)a; }

typedef struct { const char* name; int age; } person_t;
static int by_name(const void* a, const void* b) { return strcmp(((const person_t*)a)->name, ((const person_t*)b)->name); }
static int by_age(const void* a, const void* b) { return ((const person_t*)a)->age - ((const person_t*)b)->age; }

/* sorts a copy of data[] and prints it */
void sort_ints(int descending)
{
    int a[8];
    memcpy(a, data, sizeof(a));
    sort(a, 8, sizeof(int), descending ? by_value_desc : by_value);
    for (int i = 0; i < 8; i++) {
        c2al_print_int(a[i]);
        c2al_print(i < 7 ? "," : "");
    }
}

void sort_people(int by)
{
    person_t p[4] = { { "Mads", 41 }, { "Anna", 29 }, { "Erik", 52 }, { "Bo", 35 } };
    sort(p, 4, sizeof(person_t), by ? by_age : by_name);
    for (int i = 0; i < 4; i++) {
        c2al_print(p[i].name);
        c2al_print(" ");
    }
}
