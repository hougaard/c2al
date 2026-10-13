/* 09-signed-overflow: the one C behaviour that does not translate for free.
 *
 * In C, signed int overflow is undefined, but in practice it wraps (2's complement) and lots of
 * code relies on that: hash functions, random number generators, fixed point math.
 * In AL, Integer overflow is a runtime error. c2al therefore
 *   - always wraps unsigned arithmetic (computed in BigInteger, then reduced mod 2^32)
 *   - leaves signed arithmetic as plain AL arithmetic (fast), except
 *       "wrap_all_signed": true   wraps every signed + - *          (this project)
 *       "wrap_sites": "file.json" wraps only the listed (function, line offset) sites
 * The JS test build checks every signed operation and reports the overflowing source lines,
 * which is how the DOOM wrap sites were found (see docs/arithmetic.md). */
#include "c2al.h"

/* Java's String.hashCode: h = 31 * h + c, overflows after a few characters */
int java_hash(const char* s)
{
    int h = 0;
    for (; *s; s++)
        h = 31 * h + *s;
    return h;
}

/* the rand() LCG from the C standard, with a signed state: the multiply overflows */
static int seed = 1;

int lcg_next(void)
{
    seed = seed * 1103515245 + 12345;
    return (int)(((unsigned int)seed / 65536) % 32768);
}

int lcg_sequence(int n)
{
    int sum = 0;
    seed = 1;
    for (int i = 0; i < n; i++)
        sum += lcg_next();
    return sum;
}

/* no overflow here: never needs wrapping, but with wrap_all_signed it is wrapped anyway (slower) */
int plain_sum(int n)
{
    int s = 0;
    for (int i = 1; i <= n; i++)
        s += i;
    return s;
}
