/* 01-basics: functions, recursion, loops, globals, arrays.
 * Everything here maps almost 1:1 to AL: ints become Integer, locals become AL locals. */
#include "c2al.h"

/* recursive call */
int fib(int n)
{
    if (n < 2)
        return n;
    return fib(n - 1) + fib(n - 2);
}

/* the same with a loop */
int fib_iter(int n)
{
    int a = 0, b = 1;
    for (int i = 0; i < n; i++) {
        int t = a + b;
        a = b;
        b = t;
    }
    return a;
}

int gcd(int a, int b)
{
    while (b != 0) {
        int t = a % b;
        a = b;
        b = t;
    }
    return a < 0 ? -a : a;
}

int is_prime(int n)
{
    if (n < 2)
        return 0;
    for (int d = 2; d * d <= n; d++)
        if (n % d == 0)
            return 0;
    return 1;
}

/* do/while, compound assignment, ternary */
int collatz_steps(int n)
{
    int steps = 0;
    do {
        n = (n % 2 == 0) ? n / 2 : 3 * n + 1;
        steps++;
    } while (n != 1);
    return steps;
}

/* a global array lives in the C data segment (Mem), the counter is a plain AL global */
static int history[16];
static int count;

void push(int v)
{
    history[count % 16] = v;
    count++;
}

int sum_history(void)
{
    int s = 0;
    int n = count < 16 ? count : 16;
    for (int i = 0; i < n; i++)
        s += history[i];
    return s;
}

/* C integer division truncates toward zero, like AL div/mod */
int div_trunc(int a, int b) { return a / b; }
int mod_trunc(int a, int b) { return a % b; }

/* char / short narrowing: (signed char)200 == -56 */
int narrow_char(int v) { signed char c = (signed char)v; return c; }
int narrow_ushort(int v) { unsigned short s = (unsigned short)v; return s; }
