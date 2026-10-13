# Whole program analysis: reachability, address-taken, naming, data layout
from pycparser import c_ast
from .front import err, CompileError, parse_string_literal
from .ctypes_ import *

AL_RESERVED = set('''
and array asserterror begin break case codeunit continue controladdin div do downto else end entitlement enum
enumextension event exit false for foreach if in interface internal label local mod not of or page pageextension
permissionset procedure profile protected query record repeat report reportextension table tableextension temporary
then to trigger true until var while with xmlport xor dotnet this namespace using rec xrec currpage currreport
action any automation bigtext blob boolean byte char code date dateformula datetime decimal dialog dictionary
duration errorinfo file filterpagebuilder guid httpclient instream integer biginteger list media mediaset
notification option outstream recordid recordref sessionsettings tablefilter testpage text textbuilder textconst
time variant version fieldref keyref none
abs power round random randomize error message confirm format evaluate strlen strpos copystr delchr incstr
lowercase uppercase padstr selectstr convertstr maxstrlen clear clearall sleep today workdate commit sessionid
userid companyname getlasterrortext clearlasterror guiallowed hyperlink currentdatetime createdatetime arraylen
copyarray compressarray strsubstno createguid isnullguid
mem sp bz b31 b32 sx8 pow2 b2i heap
'''.split())
import os as _os
# full AL keyword list (extracted from the AL compiler's syntax tokens)
_kw = _os.path.join(_os.path.dirname(_os.path.abspath(__file__)), 'al_keywords.txt')
AL_RESERVED |= set(open(_kw).read().split())
# names of procedures the AL emitter generates itself
AL_RESERVED |= {'initglobals', 'initdata', 'decodedata'} | {'datapart%d' % i for i in range(100)} | {'callfn%d' % i for i in range(20)} | {'callfnv%d' % i for i in range(20)}


class RefScanner(c_ast.NodeVisitor):
    """scope aware scan of a function body (or initializer) for global references"""

    def __init__(self, prog, func=None):
        self.prog = prog
        self.func = func
        self.scopes = [{}]
        self.funcs = set()      # functions referenced (call or address)
        self.fptrs = set()      # functions whose address is taken
        self.globals = set()    # global vars referenced
        self.gaddr = set()      # global vars whose address is taken
        self.laddr = set()      # id(decl) of address taken locals
        self.strings = 0
        if func is not None and func.node is not None:
            fd = func.node.decl.type
            if fd.args:
                for p in fd.args.params:
                    if isinstance(p, c_ast.Decl) and p.name:
                        self.scopes[0][p.name] = ('local', p)

    def lookup(self, name):
        for s in reversed(self.scopes):
            if name in s:
                return s[name]
        if name in self.prog.funcs:
            return ('func', name)
        if name in self.prog.globals:
            return ('global', name)
        return None

    def ref(self, name, addr):
        r = self.lookup(name)
        if r is None:
            return
        if r[0] == 'func':
            self.funcs.add(r[1])
            if addr:
                self.fptrs.add(r[1])
        elif r[0] == 'global':
            self.globals.add(r[1])
            if addr:
                self.gaddr.add(r[1])
        elif r[0] == 'local':
            if addr:
                self.laddr.add(id(r[1]))

    def visit_Compound(self, n):
        self.scopes.append({})
        for it in n.block_items or []:
            self.visit(it)
        self.scopes.pop()

    def visit_For(self, n):
        self.scopes.append({})
        for ch in (n.init, n.cond, n.next, n.stmt):
            if ch is not None:
                self.visit(ch)
        self.scopes.pop()

    def visit_Decl(self, n):
        if n.name is None:
            return
        if isinstance(n.type, c_ast.FuncDecl):
            return
        st = n.storage or []
        if 'extern' in st:
            self.scopes[-1][n.name] = ('global', n.name)
            return
        if 'static' in st and self.func is not None:
            g = self.func.static_locals[id(n)]
            self.scopes[-1][n.name] = ('global', g.name)
            self.globals.add(g.name)
            if n.init is not None:
                self.visit_init(n.init)
            return
        self.scopes[-1][n.name] = ('local', n)
        if n.init is not None:
            self.visit_init(n.init)
        # array dimensions may reference things (sizeof) - ignore

    def visit_init(self, init):
        self.visit(init)

    def visit_Typedef(self, n):
        pass

    def visit_Typename(self, n):
        pass

    def visit_ID(self, n):
        # bare identifier used as value: functions decay to pointers, arrays decay to addresses
        r = self.lookup(n.name)
        if r is None:
            return
        if r[0] == 'func':
            self.ref(n.name, True)
        elif r[0] == 'global':
            g = self.prog.globals[r[1]]
            self.ref(n.name, g.type.is_arr() or g.type.is_struct())
        else:
            self.ref(n.name, False)

    def visit_FuncCall(self, n):
        if isinstance(n.name, c_ast.ID):
            r = self.lookup(n.name.name)
            if r is not None and r[0] == 'func':
                self.funcs.add(r[1])
            else:
                self.visit(n.name)
        else:
            self.visit(n.name)
        if n.args:
            self.visit(n.args)

    def visit_UnaryOp(self, n):
        if n.op == '&':
            self.addr_of(n.expr)
            return
        if n.op == 'sizeof':
            return
        self.visit(n.expr)

    def addr_of(self, e):
        if isinstance(e, c_ast.ID):
            self.ref(e.name, True)
        elif isinstance(e, c_ast.StructRef) and e.type == '.':
            self.addr_of(e.name)
        elif isinstance(e, c_ast.ArrayRef):
            self.addr_of(e.name) if self.is_array_expr(e.name) else self.visit(e.name)
            self.visit(e.subscript)
        else:
            self.visit(e)

    def is_array_expr(self, e):
        # conservative: treat as array (forces memory residency of locals that are arrays anyway)
        return isinstance(e, (c_ast.ID, c_ast.StructRef, c_ast.ArrayRef))

    def visit_StructRef(self, n):
        if n.type == '.':
            # s.x where s is a struct: s must be in memory anyway
            self.addr_of(n.name)
        else:
            self.visit(n.name)

    def visit_NamedInitializer(self, n):
        self.visit(n.expr)

    def visit_Cast(self, n):
        self.visit(n.expr)

    def visit_Constant(self, n):
        if n.type == 'string':
            self.strings += 1

    def visit_Goto(self, n):
        err(n, 'goto not supported')


class Analysis:
    def __init__(self, prog, cfg):
        self.prog = prog
        self.cfg = cfg
        self.scans = {}
        self.data_scans = {}

    def run(self):
        prog = self.prog
        for name, f in prog.funcs.items():
            if name in self.cfg.intrinsics:
                f.intrinsic = self.cfg.intrinsics[name]
            elif f.node is None and self.cfg.is_native(name):
                f.native = True
        # reachability
        work = list(self.cfg.entry_points)
        seen_f = set()
        seen_g = set()
        missing = set()
        while work:
            item = work.pop()
            if isinstance(item, tuple):
                gname = item[1]
                if gname in seen_g:
                    continue
                seen_g.add(gname)
                g = prog.globals[gname]
                g.reachable = True
                if g.init is not None:
                    sc = RefScanner(prog, prog.funcs.get(g.owner) if g.owner else None)
                    if g.owner:
                        # static local initializer: resolve with global scope only
                        sc = RefScanner(prog, None)
                    sc.visit(g.init)
                    self.data_scans[gname] = sc
                    for fn in sc.funcs:
                        work.append(fn)
                    for fn in sc.fptrs:
                        prog.funcs[fn].addr_taken = True
                    for gn in sc.globals:
                        work.append(('g', gn))
                    for gn in sc.gaddr:
                        prog.globals[gn].addr_taken = True
                continue
            if item in seen_f:
                continue
            seen_f.add(item)
            f = prog.funcs.get(item)
            if f is None:
                missing.add(item)
                continue
            f.reachable = True
            if f.intrinsic or f.native:
                continue
            if f.node is None:
                missing.add(item)
                continue
            sc = RefScanner(prog, f)
            sc.visit(f.node.body)
            self.scans[item] = sc
            for fn in sc.funcs:
                work.append(fn)
            for fn in sc.fptrs:
                prog.funcs[fn].addr_taken = True
            for gn in sc.globals:
                work.append(('g', gn))
            for gn in sc.gaddr:
                prog.globals[gn].addr_taken = True
        if missing:
            raise CompileError('undefined functions reachable: %s' % sorted(missing))
        # memory residency of globals
        for g in prog.globals.values():
            if not g.reachable:
                continue
            t = g.type
            g.mem = g.addr_taken or t.is_arr() or t.is_struct()
            if not g.mem and t.alk() not in ('I', 'B'):
                raise CompileError('%s: unsupported global type %r for %s' % (g.coord, t, g.name))
        # function ids
        fid = 1
        for name in sorted(prog.funcs):
            f = prog.funcs[name]
            if f.reachable and f.addr_taken:
                f.fid = fid
                fid += 1
        self.assign_names()

    def assign_names(self):
        used = set(AL_RESERVED) | self.cfg.runtime_words()
        self.used_names = used

        def mk(name):
            n = name
            if n.startswith('_'):
                n = 'u' + n
            base = n
            k = 2
            while n.lower() in used:
                n = '%s_%d' % (base, k)
                k += 1
            used.add(n.lower())
            return n

        for name in sorted(self.prog.funcs):
            f = self.prog.funcs[name]
            if f.reachable:
                if f.intrinsic:
                    f.alname = f.intrinsic
                elif f.native:
                    f.alname = name
                    used.add(name.lower())
                else:
                    f.alname = mk(name)
        for name in sorted(self.prog.globals):
            g = self.prog.globals[name]
            if g.reachable and not g.mem:
                g.alname = mk('g_' + name if name.lower() in used else name)
