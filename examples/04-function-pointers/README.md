# 04 function pointers

A function pointer is an integer id. Calling through it goes to a generated dispatcher:

```c
typedef int (*binop_t)(int, int);
static const struct { char sym; binop_t fn; } ops[] = { { '+', add }, { '-', sub }, { '*', mul }, { 'M', max } };
...
return ops[i].fn(a, b);
```
```al
local procedure CallFn2(f: Integer; a0: Integer; a1: Integer): Integer
begin
    case f of
        1: exit(add_2(a0, a1));
        2: exit(by_age(a0, a1));
        3: exit(by_name(a0, a1));
        4: exit(by_value(a0, a1));
        5: exit(by_value_desc(a0, a1));
        6: exit(max_2(a0, a1));
        7: exit(mul(a0, a1));
        8: exit(sub(a0, a1));
    end;
    Error('C2AL: bad function pointer %1 in CallFn2', f);
end;
```

All address-taken functions with two parameters share `CallFn2`: the arithmetic ops and the sort
comparators. The `ops` table is in the data segment, with the ids written into it at compile time.
`add` and `max` collide with AL built-ins and become `add_2` / `max_2`.

`sort` is a generic insertion sort over `void*` elements of any size. Like `qsort`, it uses `memcpy` and a comparator.
`sort_people` sorts structs by a string field or by an int field.
