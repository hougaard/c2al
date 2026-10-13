/* 06-control-flow: switch (with and without fall through), break/continue, early returns.
 * AL has no goto and no fall through. c2al uses
 *   - an AL 'case' when every arm ends in break/return/continue
 *   - otherwise a 'repeat ... until true' wrapper with an arm index: falling through is
 *     just running into the next 'if idx <= k' block, break is the AL break of the repeat
 * goto is not supported: rewrite it first (see docs/control-flow.md). */
#include "c2al.h"

/* clean switch -> AL case; grouped labels */
int vowel_count(const char* s)
{
    int n = 0;
    for (; *s; s++) {
        switch (*s | 32) {   /* lower case */
        case 'a': case 'e': case 'i': case 'o': case 'u': case 'y':
            n++;
            break;
        default:
            break;
        }
    }
    return n;
}

static int roman_digit(char c)
{
    switch (c) {
    case 'I': return 1;
    case 'V': return 5;
    case 'X': return 10;
    case 'L': return 50;
    case 'C': return 100;
    case 'D': return 500;
    case 'M': return 1000;
    }
    return 0;
}

int roman_to_int(const char* s)
{
    int total = 0;
    for (int i = 0; s[i]; i++) {
        int v = roman_digit(s[i]), next = roman_digit(s[i + 1]);
        total += v < next ? -v : v;
    }
    return total;
}

/* fall through: Duff's device style unrolled copy count */
int fallthrough(int n)
{
    int r = 0;
    switch (n % 4) {
    case 0: r += 1000;  /* fall through */
    case 3: r += 100;   /* fall through */
    case 2: r += 10;    /* fall through */
    case 1: r += 1;
        break;
    default:
        r = -1;
    }
    return r;
}

/* continue inside a switch inside a loop: c2al sets a flag, leaves the switch wrapper and continues */
int sum_skipping(const char* s)
{
    int sum = 0;
    for (; *s; s++) {
        switch (*s) {
        case ' ':
            continue;           /* skip spaces */
        case '#':
            return sum;         /* rest is a comment */
        case '-':
            sum -= 1;
            /* fall through */
        default:
            sum += *s >= '0' && *s <= '9' ? *s - '0' : 0;
        }
    }
    return sum;
}

/* break out of nested loops with a flag (the usual replacement for goto) */
int find_pair(int target)
{
    static const int v[] = { 8, 3, 11, 5, 7, 2 };
    int found = -1;
    for (int i = 0; i < 6 && found < 0; i++)
        for (int j = i + 1; j < 6; j++)
            if (v[i] + v[j] == target) {
                found = i * 10 + j;
                break;
            }
    return found;
}

/* short circuit evaluation: the right side must not run when the left decides */
static int calls;
static int touch(int v) { calls++; return v; }

int short_circuit(void)
{
    calls = 0;
    int r = 0;
    if (touch(0) && touch(1)) r += 1;   /* 1 call */
    if (touch(1) || touch(1)) r += 2;   /* 1 call */
    if (touch(1) && touch(0)) r += 4;   /* 2 calls */
    r += touch(0) ? touch(5) : touch(7); /* 2 calls, adds 7 */
    return r * 100 + calls;             /* 906 */
}

/* the comma operator, ++ in conditions, while(1) with break */
int digits_reversed(int n)
{
    int r = 0, guard = 0;
    while (1) {
        if (n == 0 || ++guard > 20)
            break;
        r = r * 10 + n % 10, n /= 10;
    }
    return r;
}
