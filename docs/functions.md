# Functions

## Calling convention

A C function becomes an AL procedure with the same parameters, in order:

| C parameter | AL parameter | Notes |
|---|---|---|
| `int`, `char`, pointer, ... | `x: Integer` | by value |
| `long long` | `x: BigInteger` | |
| `double` | `x: Decimal` | |
| struct by value | `p_x: Integer` (its address) | the callee copies it into its own frame (`Rt_MemCpy`) in the prologue |
| scalar whose address is taken (`&x` inside) | `p_x: Integer` | copied into a frame slot in the prologue |

Return values are `Integer`/`BigInteger`/`Decimal`, or nothing for `void`. Struct returns are not
supported yet. Calls with fewer arguments than parameters (old style C) are padded with `0`.

Entry points (`entry_points` in `c2al.json`) are public procedures, everything else is
`local`. So the codeunit's public surface is exactly the C API you chose plus the runtime's host API.

## Names

C names are kept where possible. They are renamed with a `_2`, `_3` suffix when they collide with:

- an AL keyword or built-in (`area`, `max`, `add`, `message`, ... see `analysis.py` `AL_RESERVED` and `al_keywords.txt`)
- a global or procedure of the runtime (`Initialize`, `Heap`, `Rt_And`, ...)
- another C name that differs only in case (AL identifiers are case insensitive)

Global C variables that collide get a `g_` prefix (`grid` → `g_grid` in DOOM).
`build/entry_names.json` lists the AL name of each entry point. `examples/04-function-pointers`
has `add`/`max`, which become `add_2`/`max_2`.

## Function pointers

Every reachable function whose address is taken gets an id (1, 2, 3 ... in name order). A function
pointer is that id stored as an Integer. A call through a pointer becomes a call to a generated dispatcher
named after the call's argument count and whether it returns a value:

```al
// examples/04-function-pointers: ops[i].fn(a, b), cmp(x, y), f(init, a[i])
local procedure CallFn2(f: Integer; a0: Integer; a1: Integer): Integer
begin
    case f of
        1: exit(add_2(a0, a1));
        2: exit(by_age(a0, a1));
        ...
        8: exit(sub(a0, a1));
    end;
    Error('C2AL: bad function pointer %1 in CallFn2', f);
end;
```

Each dispatcher lists all address-taken functions with that many parameters. That works because every
argument is passed as Integer. A dispatcher for functions returning `long long` or
`double` is not distinguished yet: the IR kind check is `rk` (has a result) only. Programs that
call `long long`-returning function pointers need that refined (see [roadmap](roadmap.md)).

## Natives

A **native** is a C function declared but not defined, whose name starts with a native prefix
(`c2al_` by default, `bc_` in DOOM). The translation calls it like any other function, and the
runtime template must contain a procedure with that exact name and AL types:

```c
void c2al_print(const char* s);            // include/c2al.h
```
```al
local procedure c2al_print(s: Integer)    // runtime/core.al
begin
    LogText.Append(CStr(s));
end;
```

Natives are how translated code talks to BC: DOOM reads WAD lumps from a BC table
(`bc_wad_readlump`), stores save games in a table (`bc_file_*`), and reports sounds to the page
(`bc_sound`). See [runtime.md](runtime.md) for how to add your own.

## Intrinsics

An **intrinsic** replaces a C function, defined or not, by a runtime procedure: `memset` →
`Rt_MemSet`. Use it for functions that are much faster written directly in AL, or that C cannot express
cheaply in AL terms. DOOM maps its `FixedMul`/`FixedDiv` (64-bit multiply/divide with shifts) to
hand-written BigInteger AL. The default set is in `config.py` `DEFAULT_INTRINSICS`. A project
can replace it with `"intrinsics": {...}` in `c2al.json`.

## Varargs

Not supported: `varargs not supported` for a reachable variadic *definition*. Calls to an
undefined variadic native are possible (arguments are promoted). PureDOOM's `doom_print` family
was already non-variadic. A future `va_list` design would pass extra arguments in a block of `Mem`.
