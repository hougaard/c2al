# Debug build: inserts trace calls into doom_patched.h -> doom_debug.h; builds C ref + JS from it.
import sys, subprocess, re, json, os
sys.path.insert(0, '../..')
from build import doom_config
TRACES = json.load(open('traces.json')) if os.path.exists('traces.json') else []
src = open('doom_patched.h', encoding='latin-1').read()
src = src.replace('/* ---- BC natives', 'void bc_trace(const char* tag, int v);\n/* ---- BC natives', 1)
for t in TRACES:
    anchor, code = t[0], t[1]
    nth = t[2] if len(t) > 2 else None
    if nth is None:
        assert src.count(anchor) == 1, ('anchor count', src.count(anchor), anchor)
        src = src.replace(anchor, anchor + code)
    else:
        i = -1
        for _ in range(nth + 1):
            i = src.index(anchor, i + 1)
        src = src[:i + len(anchor)] + code + src[i + len(anchor):]
open('doom_debug.h', 'w', encoding='latin-1').write(src)
g = open('bc_glue.c').read().replace('doom_patched.h', 'doom_debug.h')
g += '\nvoid bc_trace(const char* tag, int v) { doom_print(tag); doom_print(" "); doom_print(doom_itoa(v, 10)); doom_print("\\n"); }\n'
open('dbg_glue.c', 'w').write(g)
subprocess.check_call([sys.executable, '-m', 'ziglang', 'cc', '-O1', '-m32', '-target', 'x86-windows-gnu', '-w', 'dbg_glue.c', 'ref_natives.c', 'ref_main3.c', '-o', 'dbg_ref.exe'])
subprocess.check_call([sys.executable, '-m', 'ziglang', 'cc', '-E', '-m32', '-target', 'x86-windows-gnu', 'dbg_glue.c', '-o', 'dbg.i'])
from c2al.main import build
from c2al.emit_js import JSEmitter
comp, errors = build('dbg.i', doom_config())
assert not errors, errors
data_end = comp.data_start + len(comp.image)
stack_top = (data_end + 256 * 1024 + 15) // 16 * 16
os.makedirs('dbuild', exist_ok=True)
open('dbuild/image.bin', 'wb').write(bytes(comp.image))
json.dump({'data_start': comp.data_start, 'data_end': data_end, 'stack_top': stack_top, 'heap_start': stack_top + 16}, open('dbuild/layout.json', 'w'))
open('dbuild/doom.js', 'w').write(JSEmitter(comp, True).emit())
