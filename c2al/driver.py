# Project driver: c2al.json -> preprocess -> translate -> AL codeunit + JS test build
import json, os, subprocess, sys
from .config import Config
from .main import build
from .front import CompileError
from .emit_al import ALEmitter
from .emit_js import JSEmitter, rt_names

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
INCLUDE_DIR = os.path.join(ROOT, 'include')
RUNTIME_DIR = os.path.join(ROOT, 'runtime')
PROC_MARKER = '// ---- procedures ----'


class Project:
    """a c2al.json file; paths in it are relative to its directory"""

    def __init__(self, path):
        self.path = os.path.abspath(path)
        self.dir = os.path.dirname(self.path)
        p = json.load(open(self.path))
        self.raw = p
        self.name = p['name']
        self.sources = p['sources']
        self.entry_points = p['entry_points']
        self.object_id = p['object_id']
        self.object_name = p['object_name']
        self.out_al = p.get('out_al', p['object_name'].replace(' ', '') + '.Codeunit.al')
        self.stack = p.get('stack', 64 * 1024)
        self.include = p.get('include', [])
        self.defines = p.get('defines', {})
        self.runtime = p.get('runtime', [os.path.join(RUNTIME_DIR, 'core.al')])
        self.runtime_extra = p.get('runtime_extra', [])
        self.intrinsics = p.get('intrinsics')
        self.native_prefixes = p.get('native_prefixes', ['c2al_'])
        self.wrap_all_signed = p.get('wrap_all_signed', False)
        self.wrap_sites = p.get('wrap_sites')
        self.header = p.get('header', [])
        self.tests = p.get('tests', [])
        self.build_dir = os.path.join(self.dir, 'build')

    def file(self, rel):
        return rel if os.path.isabs(rel) else os.path.join(self.dir, rel)


def runtime_text(files):
    """concatenate runtime templates: each file is '<var declarations> PROC_MARKER <procedures>'"""
    vars_, procs = [], []
    for f in files:
        t = open(f).read()
        if PROC_MARKER in t:
            v, p = t.split(PROC_MARKER, 1)
        else:
            v, p = '', t
        vars_.append(v.rstrip('\n') + '\n' if v.strip() else '')
        procs.append(p.strip('\n') + '\n')
    return ''.join(vars_) + '\n' + '\n'.join(procs)


def preprocess(proj, out_i):
    """preprocess all sources as one unit (unity build) with zig cc (clang), 32 bit target"""
    unity = os.path.join(proj.build_dir, 'unity.c')
    with open(unity, 'w') as u:
        for s in proj.sources:
            u.write('#include "%s"\n' % os.path.relpath(proj.file(s), proj.build_dir).replace('\\', '/'))
    cmd = [sys.executable, '-m', 'ziglang', 'cc', '-E', '-m32', '-target', 'x86-windows-gnu', '-nostdinc',
           '-I', INCLUDE_DIR]
    for inc in proj.include:
        cmd += ['-I', proj.file(inc)]
    for k, v in proj.defines.items():
        cmd.append('-D%s=%s' % (k, v) if v is not None else '-D%s' % k)
    cmd += [unity, '-o', out_i]
    subprocess.check_call(cmd)


def make_config(proj):
    files = [proj.file(f) for f in proj.runtime] + [proj.file(f) for f in proj.runtime_extra]
    wrap_sites = json.load(open(proj.file(proj.wrap_sites))) if proj.wrap_sites else []
    return Config(entry_points=proj.entry_points, runtime_text=runtime_text(files), intrinsics=proj.intrinsics,
                  native_prefixes=proj.native_prefixes, wrap_sites=wrap_sites,
                  wrap_all_signed=proj.wrap_all_signed)


def entry_names(comp, entry_points):
    return {n: comp.prog.funcs[n].alname for n in entry_points}


def check_runtime(comp, cfg):
    """every runtime procedure the translation calls must exist in the runtime template"""
    have = cfg.runtime_procedures()
    missing = sorted(n for n in rt_names(comp) if n.lower() not in have)
    if missing:
        raise SystemExit('the runtime does not implement: %s (see docs/limitations.md)' % ', '.join(missing))


def build_project(path, al_out=None, checked=True, quiet=False):
    """returns (proj, comp). Writes build/{unity.c,program.i,image.bin,layout.json,program.js} and the AL codeunit"""
    proj = Project(path)
    os.makedirs(proj.build_dir, exist_ok=True)
    out_i = os.path.join(proj.build_dir, 'program.i')
    preprocess(proj, out_i)
    cfg = make_config(proj)
    try:
        comp, errors = build(out_i, cfg)
    except CompileError as e:  # whole program errors (analysis): goto, undefined functions, unsupported globals
        raise SystemExit('error: %s' % e)
    if errors:
        raise SystemExit('translation failed:\n  ' + '\n  '.join(errors))
    check_runtime(comp, cfg)
    data_end = comp.data_start + len(comp.image)
    stack_top = (data_end + proj.stack + 15) // 16 * 16
    layout = {'data_start': comp.data_start, 'data_end': data_end, 'stack_top': stack_top, 'heap_start': stack_top + 16}
    layout['memsize'] = (layout['heap_start'] + 4095) // 4096 * 4096
    open(os.path.join(proj.build_dir, 'image.bin'), 'wb').write(bytes(comp.image))
    json.dump(layout, open(os.path.join(proj.build_dir, 'layout.json'), 'w'))
    open(os.path.join(proj.build_dir, 'program.js'), 'w').write(JSEmitter(comp, checked).emit())
    # C entry point name -> AL procedure name (they differ when the C name collides with an AL keyword)
    json.dump(entry_names(comp, proj.entry_points), open(os.path.join(proj.build_dir, 'entry_names.json'), 'w'), indent=1)
    header = [proj.name] + proj.header + [
        'Translated from C to AL by c2al - do not edit by hand.',
        'C memory is emulated by the Mem list (one element per byte), C pointers are indexes into Mem.',
        'Call Initialize() once before calling any of the C functions.',
    ]
    al = ALEmitter(comp, layout, cfg.runtime_text, header).emit(proj.object_id, proj.object_name)
    out = al_out or proj.file(proj.out_al)
    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
    open(out, 'w', newline='\r\n').write(al)
    if not quiet:
        print('%s: %d AL lines -> %s' % (proj.name, al.count('\n'), out))
    return proj, comp
