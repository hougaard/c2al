/* 08-long-long: 64 bit integers map to AL BigInteger.
 * Supported: long long locals, globals, parameters and return values with + - * / % and compares.
 * Not yet: long long in memory (struct fields, arrays, pointers to long long), 64 bit shifts and
 * bit operations, unsigned long long above 2^63 - the build fails with a clear message when the
 * runtime lacks Rt_Load64 / Rt_Shl64 / ... (see docs/limitations.md). */
#include "c2al.h"

long long factorial(int n)
{
    long long r = 1;
    for (int i = 2; i <= n; i++)
        r *= i;
    return r;
}

/* (a * b) mod m without overflow for 32 bit a, b, m: the product needs 64 bits */
static int mulmod(int a, int b, int m)
{
    return (int)((long long)a * b % m);
}

int powmod(int base, int exp, int m)
{
    int result = 1 % m;
    base %= m;
    while (exp > 0) {
        if (exp % 2)
            result = mulmod(result, base, m);
        base = mulmod(base, base, m);
        exp /= 2;
    }
    return result;
}

/* deterministic Miller-Rabin for all 32 bit n (bases 2, 7, 61) */
int is_prime_mr(int n)
{
    static const int bases[] = { 2, 7, 61 };
    if (n < 2)
        return 0;
    if (n % 2 == 0)
        return n == 2;
    int d = n - 1, r = 0;
    while (d % 2 == 0) {
        d /= 2;
        r++;
    }
    for (int i = 0; i < 3; i++) {
        int a = bases[i];
        if (a % n == 0)
            continue;
        int x = powmod(a, d, n);
        if (x == 1 || x == n - 1)
            continue;
        int composite = 1;
        for (int k = 1; k < r; k++) {
            x = mulmod(x, x, n);
            if (x == n - 1) {
                composite = 0;
                break;
            }
        }
        if (composite)
            return 0;
    }
    return 1;
}

/* long long parameters and globals */
static long long total;

long long add_total(long long v)
{
    total += v;
    return total;
}

/* converting 64 -> 32 bits keeps the low 32 bits (like C on every 2's complement machine) */
int low32(long long v) { return (int)v; }
