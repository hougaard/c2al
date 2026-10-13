/* 03-structs-malloc: structs, unions, pointers to structs, malloc, struct copies.
 * A struct always lives in Mem; a pointer to it is its address. Field access is address + offset. */
#include "c2al.h"

/* ---- binary search tree ---------------------------------------------------- */
typedef struct node {
    int key;
    int count;
    struct node* left;
    struct node* right;
} node_t;

static node_t* root;
static int size;

static node_t* insert(node_t* n, int key)
{
    if (!n) {
        n = malloc(sizeof(node_t));
        n->key = key;
        n->count = 1;
        size++;
        return n;
    }
    if (key < n->key)
        n->left = insert(n->left, key);
    else if (key > n->key)
        n->right = insert(n->right, key);
    else
        n->count++;
    return n;
}

void tree_add(int key) { root = insert(root, key); }
int tree_size(void) { return size; }

static int height(const node_t* n)
{
    if (!n)
        return 0;
    int l = height(n->left), r = height(n->right);
    return 1 + (l > r ? l : r);
}

int tree_height(void) { return height(root); }

static void walk(const node_t* n)
{
    if (!n)
        return;
    walk(n->left);
    c2al_print_int(n->key);
    if (n->count > 1) {
        c2al_print("x");
        c2al_print_int(n->count);
    }
    c2al_print(" ");
    walk(n->right);
}

/* in order traversal: prints the sorted keys to the log */
void tree_print(void) { walk(root); }

/* ---- value semantics: struct assignment and struct parameters copy the bytes ---- */
typedef struct {
    int x, y;
} point_t;

typedef struct {
    point_t min, max;    /* nested structs */
    char label[8];       /* array inside a struct */
} rect_t;

static int area(rect_t r)  /* passed by value: the callee gets its own copy */
{
    r.max.x -= r.min.x;  /* does not change the caller's rect */
    return r.max.x * (r.max.y - r.min.y);
}

int rect_demo(void)
{
    rect_t a = { { 1, 2 }, { 11, 7 }, "a" };
    rect_t b = a;        /* copy */
    b.max.y = 12;
    int sum = area(a) + area(b);  /* 50 + 100 */
    return sum * 100 + a.max.x;   /* a.max.x is still 11 */
}

/* ---- unions: two views of the same 4 bytes (little endian) ---------------------- */
typedef union {
    unsigned int word;
    unsigned char bytes[4];
} word_t;

int union_demo(int v)
{
    word_t w;
    w.word = (unsigned int)v;
    return w.bytes[0] + w.bytes[1] * 10 + w.bytes[3] * 1000;
}

/* ---- pointer arithmetic over an array of structs ---------------------------------- */
int sum_of_points(void)
{
    point_t pts[5];
    for (int i = 0; i < 5; i++) {
        pts[i].x = i;
        pts[i].y = i * i;
    }
    int s = 0;
    for (point_t* p = pts; p < pts + 5; p++)
        s += p->x + p->y;
    return s + (int)(&pts[4] - &pts[1]);  /* pointer difference counts elements: 3 */
}
