# Case study: DOOM in Business Central

This is the project c2al was written for: [PureDOOM](https://github.com/Daivuk/PureDOOM)
(DOOM in a single C header, ~48,600 lines) translated into one AL codeunit, `codeunit 66600 "DOOM Engine"`,
used by the "Can BC run DOOM" app (`C:\working\youtube2\BCDoom`).

| | |
|---|---|
| reachable C | 748 functions, 813 globals |
| data segment | 547 KB (WAD lumps are *not* in it: they live in a BC table) |
| generated AL | ~45,300 lines, 2.4 MB |
| JS harness speed | ~1.5 ms per frame under node (300 frames of the attract demo) |

## Pipeline

```
PureDOOM_orig.h ─► patch.py ─► doom_patched.h ─┐
                                 bc_glue.c ─────┴► zig cc -E ─► glue.i ─► c2al (build.py) ─► DoomEngine.Codeunit.al
                                                                                          └► build/doom.js (+ image.bin, layout.json)
```

```sh
cd projects/doom
python build.py                    # writes C:/working/youtube2/BCDoom/src/DoomEngine.Codeunit.al
AL_OUT=out.al python build.py      # write somewhere else
python build.py --unchecked        # JS build without overflow checks (faster)
python build.py --profile          # JS build that counts calls per function (prof.js)
```

`build.py` holds the DOOM configuration: 12 entry points, 5 intrinsics, natives prefix `bc_`,
`runtime.al`, `wrap_sites.json`, and `reserve_all_words=True` (the original naming behaviour).

## patch.py: making PureDOOM translatable

`patch.py` edits PureDOOM's C source with checked text replacements (`replace_func`, `patch_in_func`,
`insert_before_func`). Every pattern must match, so an upstream change fails loudly.

| Section | Why |
|---|---|
| natives | declares the `bc_*` functions implemented in AL: print, exit, malloc/free, time, WAD access, sound, files |
| gotos | all ~20 `goto` lines rewritten by hand (`NetUpdate`, `F_CastTicker`, `A_Look`, `A_Chase`, `PTR_SlideTraverse`, `P_SlideMove`, `PTR_ShootTraverse`, `R_ClipSolidWallSegment`, `R_AddLine`). See [docs/control-flow.md](../../docs/control-flow.md) |
| `NetUpdate` | in single tic mode, don't build tic commands here. They would consume mouse motion |
| `FixedDiv2` | exact integer math instead of doubles (`FixedMul`/`FixedDiv` themselves are AL intrinsics) |
| WAD | `W_AddFile`, `W_ReadLump`, `IdentifyVersion`: lumps come from table "DOOM WAD Lump" through `bc_wad_*`. The 4 MB WAD is never in `Mem` as a whole |
| sound | mixing 11 kHz audio in AL is far too slow. `I_StartSound` etc. report start/update/stop events with `bc_sound`, and the control add-in plays the WAD's DS* lumps itself |
| music | `S_ChangeMusic` and friends report the MUS lump to the host, and the engine never loads it |

## bc_glue.c: the host loop

Compiled together with PureDOOM, so it is translated too. `bc_doom_init()` installs the natives as
PureDOOM's callbacks, sets WASD key bindings, and calls `doom_init`. `bc_doom_frame()` runs all game
tics that are due since the last call and renders once. It builds each tic's command from the
input just received, which avoids the up-to-5-tics input lag of `TryRunTics`. `bc_get_screen` /
`bc_get_palette` give the page the frame buffer address.

## runtime.al: the DOOM runtime

The runtime predates `runtime/core.al`. It has the same core (memory, bit ops, unsigned helpers),
plus:

- **host API** for the page: `SetGame`, `Initialize`, `Tick(ElapsedMs)`, `KeyDown/KeyUp`, `MouseMove`, ...
- **frame transfer**: `GetFrame` (base64 of 64,000 palette indexes), `GetFrameDelta` (only changed rows),
  `GetPaletteIfChanged`
- `RunBenchmark`, `GetLog`, `GetSoundEvents`, `GetMusicState`
- **natives**: WAD lumps from table "DOOM WAD Lump", save games and the config file in tables
  "DOOM Save Game" / "DOOM Settings" (one open file at a time), the sound event queue
- `Rt_FixedMul` / `Rt_FixedDiv`: DOOM's 16.16 fixed point multiply and divide in BigInteger

**Note:** this file is a snapshot. The BCDoom project kept evolving (sound and music work was in
progress on 2026-10-07). If you rebuild DOOM from here, compare `runtime.al` and `patch.py` with
the latest versions first.

## Testing tools

See [docs/testing.md](../../docs/testing.md#how-doom-was-validated-projectsdoom). In short: identical
frame hashes between the native C build and the JS build over long scripted games
(`genscript.py`, `DOOM_SCRIPT`), plus trace injection (`dbg.py`), pixel watchpoints (`watch.js`),
and a call profiler (`prof.js`). The JS scripts expect `doom1.wad` (the shareware WAD) in this
folder. Copy it from `BCDoom/resources`. It is not committed.

```sh
node run2.js 2000 100              # 2000 frames, print a frame hash every 100
node run2.js 2000 100 -c           # collect signed overflow sites instead of failing
DOOM_SCRIPT=script.txt node run2.js 20000 100   # scripted gameplay (python genscript.py 1 20000 writes script.txt)
node run3.js                       # frame-at-a-time loop like the BC page (bc_doom_frame)
node sndtest.js                    # sound events over a minute of demo
```

### Known issues

- The native reference build (`ref_main3.c` + `ref_natives.c`) predates the sound and file patches. Stub
  natives were added, and it builds with
  `python -m ziglang cc -O1 -fno-sanitize=all -m32 -target x86-windows-gnu -w bc_glue.c ref_natives.c ref_main3.c -o ref.exe`,
  but it currently **crashes right after `ST_Init`**, while the JS build runs fine. To investigate:
  probably a host assumption in the newer patches (file/config handling or the sound slots) that the stubs don't meet.
  Use `-fno-sanitize=all`: zig's default UB sanitizer stops at DOOM's (harmless on x86) unaligned reads.
- Rebuilding with this compiler renames DOOM's global `grid` to `g_grid` (the keyword list now
  includes AL page keywords like `grid` and `area`). The behaviour is identical.

## Files

| File | |
|---|---|
| `PureDOOM_orig.h` | upstream PureDOOM (GPL v2), the input |
| `patch.py` | source patches → `doom_patched.h` |
| `bc_glue.c` | host loop, translated with DOOM |
| `build.py` | DOOM's c2al configuration and build |
| `runtime.al` | DOOM runtime template |
| `wrap_sites.json` | 9 signed operations that overflow in practice: `[function, line offset]` |
| `rt.js`, `run*.js`, `watch.js`, `prof.js`, `lagtest.js`, `sndtest.js` | JS harness |
| `ref_main*.c`, `ref_natives.c` | native reference build |
| `genscript.py`, `dbg.py`, `traces.json`, `topng.py` | input scripts, trace injection, frame dumps |
