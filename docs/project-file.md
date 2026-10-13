# c2al.json reference

A project file describes one C program → one AL codeunit. Paths are relative to the file.

```json
{
  "name": "c2al example 05: checksums",
  "sources": ["checksums.c"],
  "entry_points": ["crc32", "crc32_hex"],
  "object_id": 50105,
  "object_name": "C2AL Checksums",
  "out_al": "../bc-app/src/generated/Checksums.Codeunit.al",
  "tests": [
    {"call": "crc32_hex", "args": [{"text": "123456789"}], "expect": {"text": "cbf43926"}}
  ]
}
```

| Key | Default | Meaning |
|---|---|---|
| `name` | required | first line of the generated header comment, and the test report |
| `sources` | required | C files, `#include`d in this order into one translation unit |
| `entry_points` | required | C functions that become public AL procedures. They are the roots of reachability |
| `object_id` | required | codeunit id |
| `object_name` | required | codeunit name |
| `out_al` | `<ObjectName>.Codeunit.al` | where to write the codeunit |
| `stack` | `65536` | C stack size in bytes |
| `include` | `[]` | extra include directories (`include/` with `c2al.h` is always on the path) |
| `defines` | `{}` | preprocessor defines, `{"NAME": "value"}` or `{"NAME": null}` |
| `runtime` | `[runtime/core.al]` | runtime template files (replaces the core runtime) |
| `runtime_extra` | `[]` | extra runtime files added after `runtime` (your natives) |
| `intrinsics` | memset/memcpy/memmove/strlen | `{"c_name": "Rt_Procedure"}`, replaces the default map |
| `native_prefixes` | `["c2al_"]` | bodiless functions with these prefixes are natives |
| `wrap_all_signed` | `false` | wrap every signed `+ - *` (see [arithmetic.md](arithmetic.md)) |
| `wrap_sites` | none | JSON file with `[[function, line offset], ...]` signed operations to wrap |
| `header` | `[]` | extra lines for the generated header comment (credits, license) |
| `tests` | `[]` | see below |

## tests

Tests run in order against **one** program instance, so state carries over (see `push` /
`sum_history` in example 01). Each test is one call:

| Key | Meaning |
|---|---|
| `call` | C function name (must be in `entry_points`) |
| `args` | list of: integer, `{"text": "..."}` (allocated as a C string), `{"big": "123"}` (long long) |
| `expect` | integer result, `{"text": "..."}` (the result is a `char*`), `{"big": "..."}` (long long result) |
| `expect_log` | instead of `expect`: the text the call printed with `c2al_print*` |
| `expect_error` | instead of `expect`: the call must fail in AL/JS with a message containing this text (not run natively) |
| neither | void call, only run for its side effects |

The same tests drive `tests/run_tests.py` (JS and native) and `tests/gen_bc_app.py` (AL in BC).
