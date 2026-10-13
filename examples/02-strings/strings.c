/* 02-strings: char arrays, pointers into them, string literals in the data segment.
 * Strings cross the AL boundary as C addresses: AL calls AllocText('...') to make a C string
 * and ReadText(Addr) to read one back. */
#include "c2al.h"

/* in place: walks two pointers towards each other */
char* reverse(char* s)
{
    char* a = s;
    char* b = s + strlen(s) - 1;
    while (a < b) {
        char t = *a;
        *a++ = *b;
        *b-- = t;
    }
    return s;
}

char* to_upper(char* s)
{
    for (char* p = s; *p; p++)
        if (*p >= 'a' && *p <= 'z')
            *p = *p - 'a' + 'A';
    return s;
}

int count_words(const char* s)
{
    int n = 0, in_word = 0;
    for (; *s; s++) {
        if (isspace(*s))
            in_word = 0;
        else if (!in_word) {
            in_word = 1;
            n++;
        }
    }
    return n;
}

int is_palindrome(const char* s)
{
    int i = 0, j = (int)strlen(s) - 1;
    while (i < j) {
        if (s[i] != s[j])
            return 0;
        i++;
        j--;
    }
    return 1;
}

/* the result goes into a static buffer: the returned address stays valid until the next call */
static char numbuf[16];

char* int_to_text(int v)
{
    char tmp[16];  /* local array: lives on the C stack (in Mem, below SP) */
    int n = 0, neg = v < 0;
    unsigned int u = neg ? 0u - (unsigned int)v : (unsigned int)v;
    do {
        tmp[n++] = (char)('0' + u % 10);
        u /= 10;
    } while (u);
    char* p = numbuf;
    if (neg)
        *p++ = '-';
    while (n)
        *p++ = tmp[--n];
    *p = 0;
    return numbuf;
}

int parse_int(const char* s) { return atoi(s); }

/* string literals live in the data segment; the table is an array of pointers to them */
static const char* const weekdays[] = { "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday" };

const char* weekday(int i)
{
    return weekdays[i % 7];
}

/* builds "Hello, <name>!" with strcpy/strcat from c2al.h */
char* greet(const char* name)
{
    char* r = malloc((int)strlen(name) + 9);
    strcpy(r, "Hello, ");
    strcat(r, name);
    strcat(r, "!");
    return r;
}

int compare(const char* a, const char* b)
{
    int r = strcmp(a, b);
    return r < 0 ? -1 : r > 0 ? 1 : 0;
}
