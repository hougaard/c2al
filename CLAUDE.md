# c2al: notes for working on this repo

C → AL (Business Central) translator. Start with README.md and docs/architecture.md.

## Commands

```sh
python tests/run_tests.py            # all examples: JS build vs native zig build vs expected (must stay green)
python tests/gen_bc_app.py           # regenerate examples/bc-app (generated codeunits + test runner)
python -m c2al <project>/c2al.json   # translate one project
cd projects/doom && AL_OUT=<scratch>/doom.al python build.py   # DOOM (default AL_OUT writes into the BCDoom repo!)
```

Compile-check the AL (no BC server needed):
```sh
"$USERPROFILE/.vscode/extensions/ms-dynamics-smb.al-18.0.2819426/bin/alc.exe" /project:examples/bc-app /packagecachepath:C:/working/youtube2/BCDoom/.alpackages /out:<scratch>/examples.app
```
Running in BC is done by the user: ask them to publish examples/bc-app and press "Run all examples".

## Rules

- **DOOM is the regression test for the compiler.** After changing c2al/, rebuild DOOM to a scratch path and
  diff against the previous output. Changes must be intentional and explained. Never run build.py without `AL_OUT` unless
  the user wants BCDoom's DoomEngine.Codeunit.al overwritten.
- Keep `runtime/core.al` and `runtime/rt_core.js` in sync: same procedures, AL semantics in JS (overflow throws).
- New lowering features need an example (or a test in an existing one) with tests in c2al.json. Expected values should come
  from an independent source where possible. The native build is the reference.
- Generated AL in examples/bc-app/src/generated is committed. Regenerate it with gen_bc_app.py, never edit it by hand.
- Python style: match the existing modules (short names, few comments, no type hints).
