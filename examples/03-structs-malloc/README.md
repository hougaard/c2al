# 03 structs and malloc

A binary search tree built with `malloc`, plus value semantics of structs.

A struct field is a load or store at `address + offset`. `node_t` is
`{ int key; int count; node_t* left; node_t* right; }`, so `key` is at offset 0, `count` at 4, and `left` at 8:

```c
if (!n) {
    n = malloc(sizeof(node_t));
    n->key = key;
    n->count = 1;
    ...
if (key < n->key)
    n->left = insert(n->left, key);
```
```al
if n = 0 then begin
    n := c2al_malloc(16);
    if key_2 >= 0 then begin           // n->key = key   (4 byte store)
        Mem.Set(n + 1, key_2 mod 256);
        ...
    Mem.Set(n + 5, 1);                 // n->count = 1   (constant: 4 plain byte stores)
    Mem.Set(n + 6, 0);
    ...
if key_2 < (Mem.Get(n + 1) + 256 * (Mem.Get(n + 2) + 256 * (Mem.Get(n + 3) + 256 * SX8[Mem.Get(n + 4) + 1]))) then begin
    ti1 := insert((Mem.Get(n + 9) + ...), key_2);    // n->left at offset 8
```

`key` is an AL keyword, so the parameter becomes `key_2`.

- `rect_demo`: `rect_t b = a;` copies 24 bytes (`Rt_MemCpy`). `area(rect_t r)` receives a copy, so changing
  `r` does not change the caller's struct.
- `union_demo`: a union is one block of memory with several views. It shows the byte order is little endian.
- `sum_of_points`: an array of structs on the C stack, a pointer walking over it, and pointer
  difference (`&pts[4] - &pts[1]` = 3 elements).
- `tree_print` prints with `c2al_print_int` / `c2al_print`. Read the result in AL with `GetLog()`.
