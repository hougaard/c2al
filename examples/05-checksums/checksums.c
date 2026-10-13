/* 05-checksums: unsigned 32 bit arithmetic and bit operations.
 * AL has no unsigned type and no bit operators. c2al keeps unsigned values in Integer
 * (same bits, 2's complement), wraps unsigned + - * through BigInteger, and lowers
 *   & | ^      constant masks -> div/mod arithmetic, otherwise byte lookup tables (Rt_And/Or/Xor)
 *   << >>      constant shifts -> multiply/divide by powers of two, otherwise Rt_Shr / Rt_UShr */
#include "c2al.h"

static uint32_t crc_table[256];
static int crc_ready;

static void crc_init(void)
{
    for (uint32_t i = 0; i < 256; i++) {
        uint32_t c = i;
        for (int k = 0; k < 8; k++)
            c = (c & 1) ? 0xEDB88320u ^ (c >> 1) : c >> 1;
        crc_table[i] = c;
    }
    crc_ready = 1;
}

uint32_t crc32(const char* s)
{
    if (!crc_ready)
        crc_init();
    uint32_t c = 0xFFFFFFFFu;
    for (const unsigned char* p = (const unsigned char*)s; *p; p++)
        c = crc_table[(c ^ *p) & 0xFF] ^ (c >> 8);
    return c ^ 0xFFFFFFFFu;
}

uint32_t adler32(const char* s)
{
    uint32_t a = 1, b = 0;
    for (; *s; s++) {
        a = (a + (unsigned char)*s) % 65521;
        b = (b + a) % 65521;
    }
    return (b << 16) | a;
}

/* FNV-1a: the multiply overflows 32 bits on purpose (fine for unsigned in C, and in c2al) */
uint32_t fnv1a(const char* s)
{
    uint32_t h = 2166136261u;
    for (; *s; s++) {
        h ^= (unsigned char)*s;
        h *= 16777619u;
    }
    return h;
}

/* formats a 32 bit value as 8 hex digits */
static char hexbuf[9];

char* hex32(uint32_t v)
{
    static const char digits[] = "0123456789abcdef";
    for (int i = 7; i >= 0; i--) {
        hexbuf[i] = digits[v & 15];
        v >>= 4;
    }
    hexbuf[8] = 0;
    return hexbuf;
}

char* crc32_hex(const char* s) { return hex32(crc32(s)); }
char* adler32_hex(const char* s) { return hex32(adler32(s)); }
char* fnv1a_hex(const char* s) { return hex32(fnv1a(s)); }

/* bit tricks */
int popcount(uint32_t v)
{
    int n = 0;
    while (v) {
        v &= v - 1;
        n++;
    }
    return n;
}

uint32_t rotl(uint32_t v, int n) { return (v << n) | (v >> (32 - n)); }

int unsigned_less(int a, int b) { return (unsigned)a < (unsigned)b; }
