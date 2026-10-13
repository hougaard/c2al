import sys, time, traceback
import pycparser
from .front import Program, CompileError
from .analysis import Analysis
from .lower import Compiler, FL


def build(ifile, cfg, stop_on_error=False):
    """translate one preprocessed C file (.i) to lowered procedures; returns (Compiler, [error text])"""
    t0 = time.time()
    ast = pycparser.CParser().parse(open(ifile, encoding='latin-1').read(), ifile)
    prog = Program(ast)
    an = Analysis(prog, cfg)
    an.run()
    comp = Compiler(prog, an)
    comp.layout_globals()
    errors = []
    for name in sorted(prog.funcs):
        f = prog.funcs[name]
        if not f.reachable or f.native or f.intrinsic:
            continue
        try:
            comp.procs.append(FL(comp, f).lower())
        except Exception as e:
            if stop_on_error:
                raise
            errors.append('%s: %s' % (name, e))
    nf = sum(1 for f in prog.funcs.values() if f.reachable)
    ng = sum(1 for g in prog.globals.values() if g.reachable)
    print('reachable funcs %d globals %d procs %d data %d bytes, %.1fs' % (
        nf, ng, len(comp.procs), len(comp.image), time.time() - t0), file=sys.stderr)
    return comp, errors

