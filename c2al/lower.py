# Lowering of C functions to the structured IR
from pycparser import c_ast
from .front import err, CompileError, parse_string_literal, parse_char_literal
from .ctypes_ import *
from .ir import *

WRAP = True  # assume AL Integer arithmetic traps on overflow: wrap unsigned arithmetic explicitly

BIG31 = XV('B31', 'B')
BIG32 = XV('B32', 'B')


def lowmask_bits(u):
    """u == 2^k - 1  -> k"""
    if u > 0 and (u & (u + 1)) == 0:
        return u.bit_length()
    return None


def contiguous(u):
    """u has a single run of ones -> (lo, hi)"""
    if u == 0:
        return None
    lo = (u & -u).bit_length() - 1
    v = u >> lo
    k = lowmask_bits(v)
    if k is None:
        return None
    return lo, lo + k - 1


def floormod(x, m):
    """x mod m with non-negative result, m > 0 constant"""
    if nonneg(x):
        return XB('mod', x, c(m), 'I')
    return XB('mod', XB('+', XB('mod', x, c(m), 'I'), c(m), 'I'), c(m), 'I')


class Local:
    def __init__(self, name, type, mem, alname=None, off=None):
        self.name = name
        self.type = type
        self.mem = mem
        self.alname = alname
        self.off = off


class LVar:
    def __init__(self, alname, type):
        self.alname = alname
        self.type = type


class LMem:
    def __init__(self, addr, type):
        self.addr = addr
        self.type = type


class LoopCtx:
    def __init__(self, kind, cont=None):
        self.kind = kind          # 'loop', 'wrap' (switch in repeat), 'case' (switch as AL case)
        self.cont = cont          # for loops: statements to run before AL continue
        self.flag = None          # for 'wrap': continue flag variable


def load_kind(t):
    if t.is_ptr():
        return 'i32'
    if t.is_int():
        s = t.size()
        if s == 1:
            return 's8' if t.signed else 'u8'
        if s == 2:
            return 's16' if t.signed else 'u16'
        if s == 4:
            return 'i32'
        if s == 8:
            return 'i64'
    raise CompileError('cannot load type %r' % t)


class Compiler:
    """holds program wide state while lowering"""

    def __init__(self, prog, analysis, data_start=4096):
        self.prog = prog
        self.an = analysis
        self.cfg = analysis.cfg
        self.image = bytearray()
        self.data_start = data_start
        self.strings = {}
        self.dispatch = set()   # (nargs, retkind)
        self.procs = []         # lowered procedures
        self.al_globals = []    # (alname, kind, initial value)

    # ------------------------------------------------------------ data segment
    def alloc(self, size, align=4):
        cur = self.data_start + len(self.image)
        pad = (-cur) % align
        self.image.extend(b'\0' * pad)
        addr = self.data_start + len(self.image)
        self.image.extend(b'\0' * size)
        return addr

    def write(self, addr, size, v):
        o = addr - self.data_start
        v &= (1 << (size * 8)) - 1
        for i in range(size):
            self.image[o + i] = (v >> (8 * i)) & 255

    def string_addr(self, s):
        """s: string literal source text"""
        b = bytes(parse_string_literal(s)) + b'\0'
        a = self.strings.get(b)
        if a is None:
            a = self.alloc(len(b), 1)
            self.image[a - self.data_start:a - self.data_start + len(b)] = b
            self.strings[b] = a
        return a

    def layout_globals(self):
        prog = self.prog
        for name, g in prog.globals.items():
            if g.reachable and g.mem:
                t = g.type
                if t.is_arr() and t.n is None:
                    raise CompileError('%s: unsized array %s' % (g.coord, name))
                g.addr = self.alloc(max(t.size(), 1), max(t.align(), 4 if t.size() >= 4 else 1))
        for name, g in prog.globals.items():
            if not g.reachable:
                continue
            if g.mem:
                if g.init is not None:
                    self.init_data(g.addr, g.type, g.init)
            else:
                v = 0
                if g.init is not None:
                    init = g.init
                    if isinstance(init, c_ast.InitList):
                        init = init.exprs[0]
                    v = self.const_value(g.type, init)
                if g.type.alk() == 'I':
                    v = wrap_to(INT, v)
                self.al_globals.append((g.alname, g.type.alk(), v))

    def const_value(self, t, e):
        if t.is_float():
            v = self.prog.const_eval(e)
            if v is None:
                err(e, 'non-constant float initializer')
            return v
        v = self.prog.const_eval(e, self.gtypeof)
        if v is not None:
            return wrap_to(t, v) if t.is_int() else v
        a = self.addr_const(e)
        if a is None:
            err(e, 'non-constant initializer')
        return a

    def gtypeof(self, e):
        from pycparser import c_ast as ca
        if isinstance(e, ca.ID) and e.name in self.prog.globals:
            return self.prog.globals[e.name].type
        if isinstance(e, ca.ArrayRef):
            t = self.gtypeof(e.name)
            return t.elem
        raise CompileError('%s: cannot type global expression' % e.coord)

    def addr_const(self, e):
        prog = self.prog
        if isinstance(e, c_ast.Constant) and e.type == 'string':
            return self.string_addr(e.value)
        if isinstance(e, c_ast.ID):
            if e.name in prog.funcs:
                f = prog.funcs[e.name]
                return f.fid
            g = prog.globals.get(e.name)
            if g is not None and (g.type.is_arr()):
                return g.addr
            return None
        if isinstance(e, c_ast.Cast):
            v = prog.const_eval(e.expr)
            if v is not None:
                return v
            return self.addr_const(e.expr)
        if isinstance(e, c_ast.UnaryOp) and e.op == '&':
            r = self.addr_lv_const(e.expr)
            return None if r is None else r[0]
        if isinstance(e, (c_ast.ArrayRef, c_ast.StructRef)):
            r = self.addr_lv_const(e)
            if r is not None and r[1].is_arr():
                return r[0]
            return None
        if isinstance(e, c_ast.BinaryOp) and e.op in ('+', '-'):
            a = self.addr_const(e.left)
            k = prog.const_eval(e.right)
            if a is not None and k is not None:
                t = self.const_ptr_type(e.left)
                sz = t.to.size() if t is not None and t.is_ptr() else 1
                return a + k * sz if e.op == '+' else a - k * sz
        return None

    def const_ptr_type(self, e):
        if isinstance(e, c_ast.ID):
            g = self.prog.globals.get(e.name)
            if g is not None and g.type.is_arr():
                return TPtr(g.type.elem)
        if isinstance(e, c_ast.Constant) and e.type == 'string':
            return TPtr(CHAR)
        if isinstance(e, c_ast.UnaryOp) and e.op == '&':
            r = self.addr_lv_const(e.expr)
            return TPtr(r[1]) if r else None
        return None

    def addr_lv_const(self, e):
        """address constant of an lvalue -> (addr, type)"""
        prog = self.prog
        if isinstance(e, c_ast.ID):
            g = prog.globals.get(e.name)
            if g is None:
                if e.name in prog.funcs:
                    return prog.funcs[e.name].fid, prog.funcs[e.name].type
                return None
            return g.addr, g.type
        if isinstance(e, c_ast.ArrayRef):
            r = self.addr_lv_const(e.name)
            k = prog.const_eval(e.subscript)
            if r is None or k is None:
                return None
            a, t = r
            if not t.is_arr():
                return None
            return a + k * t.elem.size(), t.elem
        if isinstance(e, c_ast.StructRef) and e.type == '.':
            r = self.addr_lv_const(e.name)
            if r is None:
                return None
            a, t = r
            ft, off = t.field(e.field.name)
            return a + off, ft
        return None

    def init_data(self, addr, t, init):
        items = []
        flatten_init(self.prog, t, init, 0, items, None)
        for off, it, node in items:
            if it == 'str':
                b, n = node
                b = b[:n]
                o = addr + off - self.data_start
                self.image[o:o + len(b)] = b
                continue
            if it.is_struct() or it.is_arr():
                err(node, 'unsupported aggregate initializer')
            v = self.const_value(it, node)
            if it.is_float():
                err(node, 'float data not supported')
            self.write(addr + off, it.size(), v)

    def anon_data(self, t, init):
        addr = self.alloc(max(t.size(), 1), 4)
        self.init_data(addr, t, init)
        return addr


def flatten_init(prog, t, init, base, out, typer):
    """flatten an initializer into (offset, scalar type, expr) items. ('str', (bytes, n)) for strings"""
    if isinstance(init, c_ast.Constant) and init.type == 'string' and t.is_arr() and t.elem.size() == 1:
        b = bytes(parse_string_literal(init.value)) + b'\0'
        out.append((base, 'str', (b, t.n if t.n is not None else len(b))))
        return
    if t.is_scalar():
        while isinstance(init, c_ast.InitList):
            init = init.exprs[0]
        out.append((base, t, init))
        return
    if isinstance(init, c_ast.InitList):
        pos = [0]
        flatten_list(prog, t, init.exprs, pos, base, out, typer)
        return
    # aggregate from expression (struct copy)
    out.append((base, t, init))


def flatten_list(prog, t, exprs, pos, base, out, typer):
    if t.is_arr():
        idx = 0
        es = t.elem.size()
        while pos[0] < len(exprs) and (t.n is None or idx < t.n):
            e = exprs[pos[0]]
            if isinstance(e, c_ast.NamedInitializer):
                d = e.name[0]
                if isinstance(d, c_ast.ID):
                    return  # field designator for an outer struct
                idx = prog.const_eval(d)
                pos[0] += 1
                flatten_init(prog, t.elem, e.expr, base + idx * es, out, typer)
                idx += 1
                continue
            flatten_elem(prog, t.elem, exprs, pos, base + idx * es, out, typer)
            idx += 1
    elif t.is_struct():
        fi = 0
        fields = t.fields[:1] if t.union else t.fields
        while pos[0] < len(exprs) and fi < len(fields):
            e = exprs[pos[0]]
            if isinstance(e, c_ast.NamedInitializer):
                d = e.name[0]
                if not isinstance(d, c_ast.ID):
                    return
                names = [f.name for f in t.fields]
                fi = names.index(d.name)
                f = t.fields[fi]
                pos[0] += 1
                flatten_init(prog, f.type, e.expr, base + f.offset, out, typer)
                fi += 1
                continue
            f = fields[fi]
            flatten_elem(prog, f.type, exprs, pos, base + f.offset, out, typer)
            fi += 1
    else:
        raise CompileError('bad aggregate')


def flatten_elem(prog, et, exprs, pos, off, out, typer):
    e = exprs[pos[0]]
    if et.is_scalar():
        pos[0] += 1
        flatten_init(prog, et, e, off, out, typer)
        return
    if isinstance(e, c_ast.InitList):
        pos[0] += 1
        flatten_init(prog, et, e, off, out, typer)
        return
    if isinstance(e, c_ast.Constant) and e.type == 'string' and et.is_arr():
        pos[0] += 1
        flatten_init(prog, et, e, off, out, typer)
        return
    if typer is not None and et.is_struct():
        tt = typer(e)
        if tt is et:
            pos[0] += 1
            out.append((off, et, e))
            return
    # brace elision
    flatten_list(prog, et, exprs, pos, off, out, typer)


class Proc:
    def __init__(self, name, params, ret, locals_, body, public, comment):
        self.name = name
        self.params = params    # list of (alname, kind)
        self.ret = ret          # kind or None
        self.locals = locals_   # list of (alname, kind)
        self.body = body
        self.public = public
        self.comment = comment


class FL:
    """lowers one C function"""

    def __init__(self, comp, f):
        self.comp = comp
        self.prog = comp.prog
        self.f = f
        self.scan = comp.an.scans.get(f.name)
        self.laddr = self.scan.laddr if self.scan else set()
        self.out = []
        self.scopes = [{}]
        self.alnames = {}       # lower -> kind
        self.al_locals = []
        self.temps_free = {'I': [], 'B': [], 'L': [], 'D': []}
        self.temps_busy = []
        self.tmp_count = 0
        self.frame = 0
        self.loops = []
        self.ret = f.type.ret
        self.fs = {'size': 0}

    # ------------------------------------------------------------ names & temps
    def new_local(self, cname, kind):
        base = cname
        if base.startswith('_'):
            base = 'u' + base
        n = base
        k = 2
        used = self.comp.an.used_names
        while n.lower() in used or n.lower() in self.alnames:
            n = '%s_%d' % (base, k)
            k += 1
        self.alnames[n.lower()] = kind
        self.al_locals.append((n, kind))
        return n

    def tmp(self, kind):
        if self.temps_free[kind]:
            n = self.temps_free[kind].pop()
        else:
            self.tmp_count += 1
            n = self.new_local('t%s%d' % (kind.lower(), self.tmp_count), kind)
        self.temps_busy.append((kind, n))
        return n

    def release(self):
        for kind, n in self.temps_busy:
            self.temps_free[kind].append(n)
        self.temps_busy = []

    def emit(self, s):
        self.out.append(s)

    def capture(self, fn):
        saved = self.out
        self.out = []
        try:
            r = fn()
            return self.out, r
        finally:
            self.out = saved

    def simplify(self, x):
        if is_simple(x):
            return x
        t = self.tmp(x.t)
        self.emit(SAssign(t, x))
        return XV(t, x.t)

    def to_temp(self, x):
        if isinstance(x, (XC, XV)):
            return x
        t = self.tmp(x.t)
        self.emit(SAssign(t, x))
        return XV(t, x.t)

    def big_to_int(self, x):
        """BigInteger expression whose value fits Integer -> Integer"""
        t = self.tmp('I')
        self.emit(SAssign(t, x))
        return XV(t, 'I')

    # ------------------------------------------------------------ scopes
    def lookup(self, name):
        for s in reversed(self.scopes):
            if name in s:
                return s[name]
        if name in self.prog.funcs:
            return ('func', self.prog.funcs[name])
        if name in self.prog.globals:
            return ('global', self.prog.globals[name])
        if name in self.prog.enums:
            return ('enum', self.prog.enums[name])
        return None

    def declare_local(self, d):
        t = self.prog.decl_type(d.type)
        if t.is_arr() and t.n is None and d.init is not None:
            t = self.prog.complete_array(t, d.init)
        mem = id(d) in self.laddr or t.is_arr() or t.is_struct()
        if mem:
            al = max(t.align(), 1)
            self.frame = (self.frame + al - 1) // al * al
            off = self.frame
            self.frame += max(t.size(), 1)
            loc = Local(d.name, t, True, off=off)
        else:
            k = t.alk()
            if k is None:
                err(d, 'bad local type %r' % t)
            loc = Local(d.name, t, False, alname=self.new_local(d.name, k))
        self.scopes[-1][d.name] = ('local', loc)
        return loc

    def frame_addr(self, off):
        return addc(XV('fp_', 'I'), off)

    # ------------------------------------------------------------ typing (no code)
    def typeof(self, e):
        p = self.prog
        if isinstance(e, c_ast.Constant):
            if e.type == 'string':
                return TArr(CHAR, len(parse_string_literal(e.value)) + 1)
            if e.type == 'char':
                return INT
            if e.type in ('float', 'double'):
                return DOUBLE
            r = p.const_eval_t(e)
            return r[1]
        if isinstance(e, c_ast.ID):
            r = self.lookup(e.name)
            if r is None:
                err(e, 'unknown identifier %s' % e.name)
            if r[0] == 'local':
                return r[1].type
            if r[0] == 'global':
                return r[1].type
            if r[0] == 'func':
                return r[1].type
            return INT
        if isinstance(e, c_ast.UnaryOp):
            if e.op == 'sizeof':
                return UINT
            if e.op == '&':
                return TPtr(self.typeof(e.expr))
            if e.op == '*':
                t = self.decay(self.typeof(e.expr))
                return t.to if t.is_ptr() else t
            if e.op == '!':
                return INT
            if e.op in ('-', '+', '~'):
                return promote(self.typeof(e.expr))
            return self.typeof(e.expr)
        if isinstance(e, c_ast.BinaryOp):
            if e.op in ('==', '!=', '<', '>', '<=', '>=', '&&', '||'):
                return INT
            a = self.decay(self.typeof(e.left))
            b = self.decay(self.typeof(e.right))
            if e.op in ('<<', '>>'):
                return promote(a)
            if e.op in ('+', '-'):
                if a.is_ptr() and b.is_ptr():
                    return INT
                if a.is_ptr():
                    return a
                if b.is_ptr():
                    return b
            return arith_conv(a, b)
        if isinstance(e, c_ast.Assignment):
            return self.typeof(e.lvalue)
        if isinstance(e, c_ast.TernaryOp):
            a = self.decay(self.typeof(e.iftrue))
            b = self.decay(self.typeof(e.iffalse))
            if a.is_arith() and b.is_arith():
                return arith_conv(a, b)
            if a.is_ptr():
                return a
            return b
        if isinstance(e, c_ast.FuncCall):
            ft = self.decay(self.typeof(e.name))
            if ft.is_ptr():
                ft = ft.to
            return ft.ret
        if isinstance(e, c_ast.ArrayRef):
            a = self.decay(self.typeof(e.name))
            if a.is_ptr():
                return a.to
            b = self.decay(self.typeof(e.subscript))
            return b.to
        if isinstance(e, c_ast.StructRef):
            t = self.typeof(e.name)
            if e.type == '->':
                t = self.decay(t).to
            r = t.field(e.field.name)
            if r is None:
                err(e, 'no field %s' % e.field.name)
            return r[0]
        if isinstance(e, c_ast.Cast):
            return self.prog.decl_type(e.to_type.type)
        if isinstance(e, c_ast.ExprList):
            return self.typeof(e.exprs[-1])
        err(e, 'cannot type %s' % type(e).__name__)

    def decay(self, t):
        if t.is_arr():
            return TPtr(t.elem)
        if t.is_func():
            return TPtr(t)
        return t

    def const_eval_t(self, e):
        return self.prog.const_eval_t(e, self.typeof, self.shadowed)

    def shadowed(self, name):
        for s in reversed(self.scopes):
            if name in s:
                return s[name][0] != 'enum'
        return False

    # ------------------------------------------------------------ conversions
    def as_int(self, x):
        if x.t == 'L':
            if isinstance(x, XC):
                return c(1 if x.v else 0)
            return XCall('B2I', [x], 'I', pure=True)
        return x

    def as_cond(self, x, t=None):
        if x.t == 'L':
            return x
        if isinstance(x, XC):
            return XC(bool(x.v), 'L')
        if x.t == 'B':
            return XB('<>', x, XC(0, 'B'), 'L')
        if x.t == 'D':
            return XB('<>', x, XC(0, 'D'), 'L')
        return XB('<>', x, c(0), 'L')

    def conv(self, x, ft, tt):
        """convert value x of C type ft to C type tt"""
        if tt.is_void():
            return x
        if tt.is_struct() or tt.is_arr():
            return x
        ft = self.decay(ft) if ft is not None else INT
        if x.t == 'L':
            x = self.as_int(x)
            ft = INT
        tk = tt.alk()
        fk = x.t
        if tk == 'D':
            if fk == 'D':
                return x
            return XB('+', XC(0, 'D'), x, 'D')
        if fk == 'D':
            err(None, 'float to int conversion not supported')
        if tk == 'B':
            if fk == 'B':
                return x
            if isinstance(x, XC):
                v = x.v
                if ft.is_int() and not ft.signed and v < 0:
                    v += 1 << 32
                return XC(v, 'B')
            if ft.is_int() and not ft.signed and not nonneg(x):
                return XB('mod', XB('+', XBig(x), BIG32, 'B'), BIG32, 'B')
            return XBig(x)
        # target Integer
        if fk == 'B':
            if isinstance(x, XC):
                x = c(wrap_to(INT, x.v))
            else:
                x = self.big_to_int(self.wrap32(x))
            fk = 'I'
        if tt.is_ptr() or tt.size() == 4:
            return x
        return self.narrow(x, tt)

    def narrow(self, x, tt):
        lo, hi = tt.minmax()
        if isinstance(x, XC):
            return c(wrap_to(tt, x.v))
        if in_range(x, lo, hi):
            return x
        if tt is BOOL:
            return self.as_int(XB('<>', x, c(0), 'L'))
        m = 1 << (tt.size() * 8)
        if not tt.signed:
            return floormod(x, m)
        h = m // 2
        return XB('-', XB('mod', XB('+', XB('mod', x, c(m), 'I'), c(m + h), 'I'), c(m), 'I'), c(h), 'I')

    def wrap32(self, xb):
        """BigInteger expression -> BigInteger expression wrapped to int32 range"""
        return XB('-', XB('mod', XB('+', XB('mod', XB('+', xb, BIG31, 'B'), BIG32, 'B'), BIG32, 'B'), BIG32, 'B'), BIG31, 'B')

    # ------------------------------------------------------------ lvalues
    def lv(self, e):
        if isinstance(e, c_ast.ID):
            r = self.lookup(e.name)
            if r is None:
                err(e, 'unknown %s' % e.name)
            if r[0] == 'local':
                loc = r[1]
                if loc.mem:
                    return LMem(self.frame_addr(loc.off), loc.type)
                return LVar(loc.alname, loc.type)
            if r[0] == 'global':
                g = r[1]
                if g.mem:
                    return LMem(c(g.addr), g.type)
                return LVar(g.alname, g.type)
            err(e, 'not an lvalue: %s' % e.name)
        if isinstance(e, c_ast.UnaryOp) and e.op == '*':
            p, pt = self.rv(e.expr)
            pt = self.decay(pt)
            return LMem(p, pt.to)
        if isinstance(e, c_ast.ArrayRef):
            b, bt = self.rv(e.name)
            i, it = self.rv(e.subscript)
            if not bt.is_ptr():
                b, bt, i, it = i, it, b, bt
            i = self.conv(i, it, INT)
            el = bt.to
            return LMem(add(b, mul(i, el.size())), el)
        if isinstance(e, c_ast.StructRef):
            if e.type == '->':
                p, pt = self.rv(e.name)
                st = self.decay(pt).to
            else:
                if isinstance(e.name, (c_ast.FuncCall, c_ast.TernaryOp, c_ast.Assignment)):
                    p, st = self.rv(e.name)
                else:
                    l = self.lv(e.name)
                    if not isinstance(l, LMem):
                        err(e, 'struct not in memory')
                    p, st = l.addr, l.type
            r = st.field(e.field.name)
            if r is None:
                err(e, 'no field %s in %r' % (e.field.name, st))
            ft, off = r
            return LMem(addc(p, off), ft)
        if isinstance(e, c_ast.Cast):
            return self.lv(e.expr)
        err(e, 'not an lvalue %s' % type(e).__name__)

    def stabilize(self, l):
        if isinstance(l, LMem):
            return LMem(self.simplify(l.addr), l.type)
        return l

    def load(self, l):
        t = l.type
        if isinstance(l, LVar):
            return XV(l.alname, t.alk()), t
        if t.is_arr():
            return l.addr, TPtr(t.elem)
        if t.is_struct():
            return l.addr, t
        if t.is_func():
            return l.addr, TPtr(t)
        if t.is_float():
            raise CompileError('float load not supported')
        k = load_kind(t)
        if k == 'i64':
            return XCall('Rt_Load64', [l.addr], 'B', pure=True), t
        a = l.addr
        if k in ('u16', 's16', 'i32'):
            a = self.simplify(a)
        return XLoad(k, a), t

    def store(self, l, x, want):
        """store already converted value x into lvalue l; returns value if want"""
        t = l.type
        if isinstance(l, LVar):
            self.emit(SAssign(l.alname, x))
            return XV(l.alname, x.t) if want else None
        if t.is_struct():
            self.emit(SCall(XCall('Rt_MemCpy', [l.addr, x, c(t.size())], 'I')))
            return l.addr if want else None
        a = self.simplify(l.addr)
        sz = t.size()
        if want:
            x = self.to_temp(x)
        if sz == 1:
            v = x
            if isinstance(v, XTab) and v.tab == 'SX8' and isinstance(v.idx, XB) and isinstance(v.idx.a, XLoad):
                v = v.idx.a  # storing a sign-extended byte: store the raw byte
            if not in_range(v, 0, 255):
                v = floormod(v, 256)
            self.emit(SStore(8, a, v))
        elif sz == 2:
            v = x
            if not in_range(v, 0, 65535):
                v = floormod(v, 65536)
            v = self.simplify(v)
            self.emit(SStore(16, a, v))
        elif sz == 4:
            v = self.simplify(x)
            self.emit(SStore(32, a, v))
        elif sz == 8:
            self.emit(SCall(XCall('Rt_Store64', [a, x], None)))
        else:
            raise CompileError('bad store size')
        return x if want else None

    # ------------------------------------------------------------ rvalues
    def rv(self, e):
        if isinstance(e, (c_ast.BinaryOp, c_ast.UnaryOp, c_ast.Constant, c_ast.ID, c_ast.Cast, c_ast.TernaryOp)):
            if not (isinstance(e, c_ast.Constant) and e.type in ('string', 'float', 'double')):
                k = self.const_eval_t(e)
                if k is not None:
                    v, t = k
                    if t.alk() == 'B':
                        return XC(v, 'B'), t
                    return c(wrap_to(INT, v)), t
        m = getattr(self, 'rv_' + type(e).__name__, None)
        if m is None:
            err(e, 'unsupported expression %s' % type(e).__name__)
        return m(e)

    def rv_Constant(self, e):
        if e.type == 'string':
            return c(self.comp.string_addr(e.value)), TPtr(CHAR)
        if e.type in ('float', 'double'):
            return XC(float(e.value.rstrip('fF')), 'D'), DOUBLE
        err(e, 'bad constant')

    def rv_ID(self, e):
        r = self.lookup(e.name)
        if r is None:
            err(e, 'unknown identifier %s' % e.name)
        if r[0] == 'func':
            f = r[1]
            if f.fid is None:
                err(e, 'function %s used as pointer but has no id' % f.name)
            return c(f.fid), TPtr(f.type)
        if r[0] == 'enum':
            return c(r[1]), INT
        return self.load(self.lv(e))

    def rv_StructRef(self, e):
        return self.load(self.lv(e))

    def rv_ArrayRef(self, e):
        return self.load(self.lv(e))

    def rv_Cast(self, e):
        tt = self.prog.decl_type(e.to_type.type)
        if tt.is_void():
            self.effect(e.expr)
            return c(0), VOID
        x, xt = self.rv(e.expr)
        return self.conv(x, xt, tt), tt

    def rv_ExprList(self, e):
        for x in e.exprs[:-1]:
            self.effect(x)
        return self.rv(e.exprs[-1])

    def rv_Assignment(self, e):
        return self.assign(e, True)

    def rv_FuncCall(self, e):
        return self.call(e, True)

    def rv_TernaryOp(self, e):
        rt = self.decay(self.typeof(e))
        cnd = self.cond(e.cond)

        def side(x):
            def f():
                v, vt = self.rv(x)
                return self.conv(v, vt, rt) if not rt.is_struct() else v
            return f
        sa, xa = self.capture(side(e.iftrue))
        sb, xb = self.capture(side(e.iffalse))
        if isinstance(cnd, XC):
            self.out.extend(sa if cnd.v else sb)
            return (xa if cnd.v else xb), rt
        k = 'I' if rt.is_struct() else (rt.alk() or 'I')
        xa = self.as_int(xa) if k == 'I' else xa
        xb = self.as_int(xb) if k == 'I' else xb
        t = self.tmp(k)
        self.emit(SIf(cnd, sa + [SAssign(t, xa)], sb + [SAssign(t, xb)]))
        return XV(t, k), rt

    def rv_UnaryOp(self, e):
        op = e.op
        if op == '&':
            return self.addr_of(e.expr), TPtr(self.typeof(e.expr))
        if op == '*':
            p, pt = self.rv(e.expr)
            pt = self.decay(pt)
            if pt.to.is_func():
                return p, pt
            return self.load(LMem(p, pt.to))
        if op == 'sizeof':
            if isinstance(e.expr, c_ast.Typename):
                return c(self.prog.decl_type(e.expr.type).size()), UINT
            return c(self.typeof(e.expr).size()), UINT
        if op in ('++', '--', 'p++', 'p--'):
            return self.incdec(e, True)
        if op == '!':
            return self.lnot(self.cond(e.expr)), INT
        x, t = self.rv(e.expr)
        t = promote(self.decay(t))
        x = self.conv(x, None, t) if x.t == 'L' else x
        if op == '+':
            return x, t
        if op == '-':
            if x.t == 'B':
                return XU('neg', x, 'B'), t
            if x.t == 'D':
                return XU('neg', x, 'D'), t
            if not t.signed and WRAP and not isinstance(x, XC):
                return self.big_to_int(self.wrap32(XU('neg', XBig(x), 'B'))), t
            return XU('neg', x, 'I'), t
        if op == '~':
            if x.t == 'B':
                return XB('-', XC(-1, 'B'), x, 'B'), t
            return XB('-', c(-1), x, 'I'), t
        err(e, 'bad unary %s' % op)

    def lnot(self, cnd):
        if isinstance(cnd, XC):
            return XC(not cnd.v, 'L')
        if isinstance(cnd, XU) and cnd.op == 'not':
            return cnd.a
        if isinstance(cnd, XB) and cnd.op in ('=', '<>', '<', '>', '<=', '>='):
            inv = {'=': '<>', '<>': '=', '<': '>=', '>=': '<', '>': '<=', '<=': '>'}
            return XB(inv[cnd.op], cnd.a, cnd.b, 'L')
        return XU('not', cnd, 'L')

    def addr_of(self, e):
        if isinstance(e, c_ast.ID):
            r = self.lookup(e.name)
            if r and r[0] == 'func':
                return c(r[1].fid)
        if isinstance(e, c_ast.UnaryOp) and e.op == '*':
            return self.rv(e.expr)[0]
        l = self.lv(e)
        if not isinstance(l, LMem):
            err(e, 'address of register variable')
        return l.addr

    def rv_BinaryOp(self, e):
        op = e.op
        if op in ('&&', '||', '==', '!=', '<', '>', '<=', '>='):
            return self.cond(e), INT
        a, at = self.rv(e.left)
        b, bt = self.rv(e.right)
        return self.binop(op, a, at, b, bt, e)

    def binop(self, op, a, at, b, bt, node=None):
        at = self.decay(at)
        bt = self.decay(bt)
        a = self.as_int(a)
        b = self.as_int(b)
        if op in ('+', '-') and (at.is_ptr() or bt.is_ptr()):
            if op == '+':
                if bt.is_ptr():
                    a, at, b, bt = b, bt, a, at
                b = self.conv(b, bt, INT)
                return add(a, mul(b, at.to.size())), at
            if bt.is_ptr():
                d = XB('-', a, b, 'I')
                sz = at.to.size()
                return (XB('div', d, c(sz), 'I') if sz != 1 else d), INT
            b = self.conv(b, bt, INT)
            return add(a, mul(XU('neg', b, 'I') if not isinstance(b, XC) else c(-b.v), at.to.size())), at
        if op in ('<<', '>>'):
            rt = promote(at)
            a = self.conv(a, at, rt)
            b = self.conv(b, bt, INT)
            if rt.alk() == 'B':
                return XCall('Rt_Shl64' if op == '<<' else ('Rt_Shr64' if rt.signed else 'Rt_UShr64'), [a, b], 'B', pure=True), rt
            if op == '<<':
                return self.shl(a, b, rt), rt
            return self.shr(a, b, rt), rt
        rt = arith_conv(at, bt)
        a = self.conv(a, at, rt)
        b = self.conv(b, bt, rt)
        k = rt.alk()
        if k == 'D':
            if op in ('+', '-', '*'):
                return XB(op, a, b, 'D'), rt
            if op == '/':
                return XB('/', a, b, 'D'), rt
            err(node, 'bad float op')
        if k == 'B':
            if op in ('+', '-', '*'):
                return XB(op, a, b, 'B'), rt
            if op == '/':
                return XB('div', a, b, 'B'), rt
            if op == '%':
                return XB('mod', a, b, 'B'), rt
            return XCall({'&': 'Rt_And64', '|': 'Rt_Or64', '^': 'Rt_Xor64'}[op], [a, b], 'B', pure=True), rt
        uns = not rt.signed
        line = node.coord.line if node is not None and node.coord else None
        if op in ('+', '-', '*'):
            if isinstance(a, XC) and isinstance(b, XC):
                v = {'+': a.v + b.v, '-': a.v - b.v, '*': a.v * b.v}[op]
                return c(wrap_to(INT, v)), rt
            if WRAP and not uns and (self.comp.cfg.wrap_all_signed or line is not None and
                                     (self.f.name, line - self.f.coord.line) in self.comp.cfg.wrap_sites):
                uns = True  # signed arithmetic that overflows in practice: wrap it (see docs/arithmetic.md)
            if uns and WRAP:
                r = rng(XB(op, a, b, 'I'))
                if r is not None and r[0] >= INT_MIN and r[1] <= INT_MAX:
                    return XB(op, a, b, 'I'), rt
                return self.big_to_int(self.wrap32(XB(op, XBig(a), b, 'B'))), rt
            return XB(op, a, b, 'I', line), rt
        if op in ('/', '%'):
            alop = 'div' if op == '/' else 'mod'
            if not uns or (nonneg(a) and nonneg(b)):
                return XB(alop, a, b, 'I'), rt
            return XCall('Rt_UDiv' if op == '/' else 'Rt_UMod', [a, b], 'I', pure=True), rt
        if op == '&':
            return self.band(a, b), rt
        if op == '|':
            return self.bor(a, b), rt
        if op == '^':
            return XCall('Rt_Xor', [a, b], 'I', pure=True), rt
        err(node, 'bad binary op %s' % op)

    # ------------------------------------------------------------ bit operations
    def shl(self, a, b, rt):
        if isinstance(b, XC):
            k = b.v
            if k == 0:
                return a
            if isinstance(a, XC):
                return c(wrap_to(INT, a.v << k))
            r = rng(a)
            if r is not None and (r[0] << k) >= INT_MIN and (r[1] << k) <= INT_MAX:
                return XB('*', a, c(1 << k), 'I')
            if not WRAP:
                return XB('*', a, c(wrap_to(INT, 1 << k)), 'I')
            m = c(1 << k) if k < 31 else BIG31
            return self.big_to_int(self.wrap32(XB('*', XBig(a), m, 'B')))
        if not WRAP:
            return XB('*', a, XTab('Pow2', add(b, c(1))), 'I')
        return self.big_to_int(self.wrap32(XB('*', XBig(a), XTab('Pow2', add(b, c(1))), 'B')))

    def shr(self, a, b, rt):
        if isinstance(b, XC):
            k = b.v
            if k == 0:
                return a
            if isinstance(a, XC):
                v = a.v if rt.signed else a.v & 0xffffffff
                return c(wrap_to(INT, v >> k))
            if k >= 31:
                if rt.signed:
                    return XU('neg', self.as_int(XB('<', a, c(0), 'L')), 'I')
                return self.as_int(XB('<', a, c(0), 'L'))
            m = 1 << k
            if nonneg(a):
                return XB('div', a, c(m), 'I')
            if rt.signed:
                a = self.simplify(a)
                return XB('div', XB('-', a, floormod(a, m), 'I'), c(m), 'I')
            # unsigned: reinterpret as 0..2^32-1
            return self.big_to_int(XB('div', XB('mod', XB('+', XBig(a), BIG32, 'B'), BIG32, 'B'), c(m), 'B'))
        return XCall('Rt_Shr' if rt.signed else 'Rt_UShr', [a, b], 'I', pure=True)

    def band(self, a, b):
        if isinstance(a, XC) and not isinstance(b, XC):
            a, b = b, a
        if isinstance(b, XC):
            if isinstance(a, XC):
                return c(wrap_to(INT, a.v & b.v))
            u = b.v & 0xffffffff
            if u == 0:
                return c(0)
            if u == 0xffffffff:
                return a
            cr = contiguous(u)
            if cr is not None:
                lo, hi = cr
                if hi <= 29:
                    x = floormod(a, 1 << (hi + 1))
                    if lo:
                        x = XB('*', XB('div', x, c(1 << lo), 'I'), c(1 << lo), 'I')
                    return x
                if hi == 31 and lo > 0:
                    a = self.simplify(a)
                    return XB('-', a, floormod(a, 1 << lo), 'I')
            inv = (~u) & 0xffffffff
            cr = contiguous(inv)
            if cr is not None and cr[1] <= 29:
                # clear a contiguous run of bits
                a = self.simplify(a)
                return XB('-', a, self.band(a, c(wrap_to(INT, inv))), 'I')
        return XCall('Rt_And', [a, b], 'I', pure=True)

    def bor(self, a, b):
        if isinstance(a, XC) and not isinstance(b, XC):
            a, b = b, a
        if isinstance(b, XC):
            if isinstance(a, XC):
                return c(wrap_to(INT, a.v | b.v))
            u = b.v & 0xffffffff
            if u == 0:
                return a
            if u & (u - 1) == 0 and u < (1 << 30):
                # set single bit
                a = self.simplify(a)
                return XB('+', a, XB('-', c(u), XB('*', XB('div', floormod(a, u * 2), c(u), 'I'), c(u), 'I'), 'I'), 'I')
        if nonneg(a) and nonneg(b):
            ra = rng(a)
            rb = rng(b)
            # disjoint small ranges (e.g. combining bytes) still need general or
        return XCall('Rt_Or', [a, b], 'I', pure=True)

    def bit_test(self, a, u):
        """(a & u) != 0 as Boolean for constant mask u"""
        u &= 0xffffffff
        if u == 0x80000000:
            return XB('<', a, c(0), 'L')
        cr = contiguous(u)
        if cr is not None and cr[1] <= 29:
            lo, hi = cr
            return XB('>=', floormod(a, 1 << (hi + 1)), c(1 << lo), 'L')
        return XB('<>', XCall('Rt_And', [a, c(wrap_to(INT, u))], 'I', pure=True), c(0), 'L')

    # ------------------------------------------------------------ conditions
    def cond(self, e):
        if isinstance(e, c_ast.BinaryOp):
            op = e.op
            if op in ('&&', '||'):
                return self.logical(op, e.left, e.right)
            if op in ('==', '!=', '<', '>', '<=', '>='):
                k = self.const_eval_t(e)
                if k is not None:
                    return XC(bool(k[0]), 'L')
                a, at = self.rv(e.left)
                b, bt = self.rv(e.right)
                return self.compare(op, a, at, b, bt)
            if op == '&':
                k = self.const_eval_t(e.right)
                k2 = self.const_eval_t(e.left)
                if k is not None or k2 is not None:
                    other = e.left if k is not None else e.right
                    kv = k if k is not None else k2
                    a, at = self.rv(other)
                    rt = arith_conv(self.decay(at), kv[1])
                    if rt.alk() == 'I':
                        a = self.conv(self.as_int(a), at, rt)
                        return self.bit_test(a, kv[0])
        if isinstance(e, c_ast.UnaryOp) and e.op == '!':
            return self.lnot(self.cond(e.expr))
        x, t = self.rv(e)
        return self.as_cond(x, t)

    def logical(self, op, l, r):
        ca = self.cond(l)
        if isinstance(ca, XC):
            if op == '&&' and not ca.v:
                return ca
            if op == '||' and ca.v:
                return ca
            return self.cond(r)
        sb, cb = self.capture(lambda: self.cond(r))
        if not sb and eager_safe(cb):
            if isinstance(cb, XC):
                if op == '&&':
                    return ca if cb.v else XC(False, 'L')
                return XC(True, 'L') if cb.v else ca
            return XB('and' if op == '&&' else 'or', ca, cb, 'L')
        t = self.tmp('L')
        self.emit(SAssign(t, ca))
        tv = XV(t, 'L')
        self.emit(SIf(tv if op == '&&' else XU('not', tv, 'L'), sb + [SAssign(t, cb)]))
        return tv

    def compare(self, op, a, at, b, bt):
        at = self.decay(at)
        bt = self.decay(bt)
        a = self.as_int(a)
        b = self.as_int(b)
        alop = {'==': '=', '!=': '<>', '<': '<', '>': '>', '<=': '<=', '>=': '>='}[op]
        if at.is_ptr() or bt.is_ptr():
            return XB(alop, a, b, 'L')
        rt = arith_conv(at, bt)
        a = self.conv(a, at, rt)
        b = self.conv(b, bt, rt)
        k = rt.alk()
        if k in ('B', 'D') or rt.signed or alop in ('=', '<>'):
            return XB(alop, a, b, 'L')
        if nonneg(a) and nonneg(b):
            return XB(alop, a, b, 'L')
        # unsigned comparison
        if alop == '<':
            return self.ult(a, b)
        if alop == '>':
            return self.ult(b, a)
        if alop == '<=':
            return self.lnot(self.ult(b, a))
        return self.lnot(self.ult(a, b))

    def ult(self, a, b):
        if isinstance(b, XC):
            if b.v == 0:
                return XC(False, 'L')
            if b.v > 0:
                a = self.simplify(a)
                return XB('and', XB('>=', a, c(0), 'L'), XB('<', a, b, 'L'), 'L')
            a = self.simplify(a)
            return XB('or', XB('>=', a, c(0), 'L'), XB('<', a, b, 'L'), 'L')
        if isinstance(a, XC):
            b = self.simplify(b)
            if a.v >= 0:
                return XB('or', XB('<', b, c(0), 'L'), XB('>', b, a, 'L'), 'L')
            return XB('and', XB('<', b, c(0), 'L'), XB('>', b, a, 'L'), 'L')
        a = self.simplify(a)
        b = self.simplify(b)
        return XB('xor', XB('<', a, b, 'L'), XB('xor', XB('<', a, c(0), 'L'), XB('<', b, c(0), 'L'), 'L'), 'L')

    # ------------------------------------------------------------ assignment
    def assign(self, e, want):
        lt = self.typeof(e.lvalue)
        if e.op == '=':
            if lt.is_struct():
                dst = self.addr_of(e.lvalue)
                src, st = self.rv(e.rvalue)
                dst = self.simplify(dst)
                self.emit(SCall(XCall('Rt_MemCpy', [dst, src, c(lt.size())], 'I')))
                return dst, lt
            l = self.lv(e.lvalue)
            x, xt = self.rv(e.rvalue)
            x = self.conv(x, xt, lt)
            return self.store(l, x, want), lt
        op = e.op[:-1]
        l = self.stabilize(self.lv(e.lvalue))
        cur, ct = self.load(l)
        r, rt = self.rv(e.rvalue)
        x, xt = self.binop(op, cur, lt, r, rt, e)
        x = self.conv(x, xt, lt)
        return self.store(l, x, want), lt

    def incdec(self, e, want):
        post = e.op in ('p++', 'p--')
        delta = 1 if e.op in ('++', 'p++') else -1
        l = self.stabilize(self.lv(e.expr))
        cur, t = self.load(l)
        if post and want:
            t0 = self.tmp(cur.t)
            self.emit(SAssign(t0, cur))
            cur = XV(t0, cur.t)
        if t.is_ptr():
            new = addc(cur, delta * t.to.size())
        else:
            new, nt = self.binop('+', cur, t, c(delta), INT, e)
            new = self.conv(new, nt, t)
        if post:
            self.store(l, new, False)
            return (cur if want else None), t
        return self.store(l, new, want), t

    # ------------------------------------------------------------ calls
    def call(self, e, want):
        fn = e.name
        args = e.args.exprs if e.args else []
        direct = None
        if isinstance(fn, c_ast.ID):
            r = self.lookup(fn.name)
            if r is not None and r[0] == 'func':
                direct = r[1]
        if direct is not None:
            ft = direct.type
        else:
            fp, fpt = self.rv(fn)
            fpt = self.decay(fpt)
            ft = fpt.to if fpt.is_ptr() else fpt
            if not ft.is_func():
                err(e, 'call of non-function')
        xs = []
        for i, a in enumerate(args):
            x, xt = self.rv(a)
            if i < len(ft.params):
                pt = ft.params[i]
            else:
                pt = promote(self.decay(xt))
            if pt.is_struct():
                xs.append(x)
                continue
            x = self.conv(x, xt, pt)
            xs.append(self.as_int(x) if x.t == 'L' else x)
        rk = None if ft.ret.is_void() else ft.ret.alk()
        if ft.ret.is_struct():
            err(e, 'struct return not supported')
        if direct is not None:
            if direct.alname is None:
                err(e, 'call to unreachable function %s' % direct.name)
            # pad missing args
            nparams = len(ft.params)
            while len(xs) < nparams:
                xs.append(c(0))
            call = XCall(direct.alname, xs, rk)
        else:
            n = len(xs)
            self.comp.dispatch.add((n, rk))
            name = ('CallFn%d' % n) if rk else ('CallFnV%d' % n)
            call = XCall(name, [self.conv(fp, fpt, INT)] + xs, rk)
        if want:
            if rk is None:
                return c(0), VOID
            return call, ft.ret
        self.emit(SCall(call))
        return None, ft.ret

    # ------------------------------------------------------------ effects
    def effect(self, e):
        if isinstance(e, c_ast.Assignment):
            self.assign(e, False)
        elif isinstance(e, c_ast.UnaryOp) and e.op in ('++', '--', 'p++', 'p--'):
            self.incdec(e, False)
        elif isinstance(e, c_ast.FuncCall):
            self.call(e, False)
        elif isinstance(e, c_ast.ExprList):
            for x in e.exprs:
                self.effect(x)
        elif isinstance(e, c_ast.Cast):
            self.effect(e.expr)
        elif isinstance(e, c_ast.TernaryOp):
            cnd = self.cond(e.cond)
            sa, _ = self.capture(lambda: self.effect(e.iftrue))
            sb, _ = self.capture(lambda: self.effect(e.iffalse))
            self.emit(SIf(cnd, sa, sb))
        elif isinstance(e, c_ast.BinaryOp) and e.op in ('&&', '||'):
            ca = self.cond(e.left)
            sb, _ = self.capture(lambda: self.effect(e.right))
            self.emit(SIf(ca if e.op == '&&' else self.lnot(ca), sb))
        else:
            x, t = self.rv(e)
            if x is not None and has_call(x):
                t2 = self.tmp(x.t)
                self.emit(SAssign(t2, x))

    # ------------------------------------------------------------ statements
    def block(self, items):
        for it in items or []:
            self.stmt(it)

    def stmt(self, s):
        m = getattr(self, 'st_' + type(s).__name__, None)
        if m is None:
            err(s, 'unsupported statement %s' % type(s).__name__)
        m(s)
        self.release()

    def st_Compound(self, s):
        self.scopes.append({})
        self.block(s.block_items)
        self.scopes.pop()

    def st_EmptyStatement(self, s):
        pass

    def st_Pragma(self, s):
        pass

    def st_Typedef(self, s):
        self.prog.typedefs[s.name] = self.prog.decl_type(s.type)

    def st_Label(self, s):
        self.stmt(s.stmt)

    def st_DeclList(self, s):
        for d in s.decls:
            self.st_Decl(d)

    def st_Decl(self, d):
        if d.name is None:
            self.prog.base_type(d.type.type if isinstance(d.type, c_ast.TypeDecl) else d.type)
            return
        if isinstance(d.type, c_ast.FuncDecl):
            return
        st = d.storage or []
        if 'extern' in st:
            self.scopes[-1][d.name] = ('global', self.prog.globals[d.name])
            return
        if 'static' in st:
            self.scopes[-1][d.name] = ('global', self.f.static_locals[id(d)])
            return
        loc = self.declare_local(d)
        if d.init is not None:
            self.init_local(loc, d.init)

    def init_local(self, loc, init):
        t = loc.type
        if not loc.mem:
            if isinstance(init, c_ast.InitList):
                init = init.exprs[0]
            x, xt = self.rv(init)
            x = self.conv(x, xt, t)
            self.emit(SAssign(loc.alname, x))
            return
        base = self.frame_addr(loc.off)
        if t.is_scalar():
            if isinstance(init, c_ast.InitList):
                init = init.exprs[0]
            x, xt = self.rv(init)
            self.store(LMem(base, t), self.conv(x, xt, t), False)
            return
        if t.is_struct() and not isinstance(init, c_ast.InitList):
            src, st = self.rv(init)
            self.emit(SCall(XCall('Rt_MemCpy', [base, src, c(t.size())], 'I')))
            return
        items = []
        flatten_init(self.prog, t, init, 0, items, self.typeof)
        if self.all_const(items):
            blob = self.comp.anon_data(t, init)
            self.emit(SCall(XCall('Rt_MemCpy', [base, c(blob), c(t.size())], 'I')))
            return
        self.emit(SCall(XCall('Rt_MemSet', [base, c(0), c(t.size())], 'I')))
        for off, it, node in items:
            if it == 'str':
                b, n = node
                for i, ch in enumerate(b[:n]):
                    if ch:
                        self.emit(SStore(8, addc(base, off + i), c(ch)))
                continue
            if it.is_struct():
                src, st = self.rv(node)
                self.emit(SCall(XCall('Rt_MemCpy', [addc(base, off), src, c(it.size())], 'I')))
                continue
            x, xt = self.rv(node)
            self.store(LMem(addc(base, off), it), self.conv(x, xt, it), False)

    def all_const(self, items):
        for off, it, node in items:
            if it == 'str':
                continue
            if it.is_struct() or it.is_arr():
                return False
            if self.prog.const_eval(node, self.typeof, self.shadowed) is None and self.comp.addr_const(node) is None:
                return False
        return True

    def st_Assignment(self, s):
        self.effect(s)

    def st_UnaryOp(self, s):
        self.effect(s)

    def st_FuncCall(self, s):
        self.effect(s)

    def st_ExprList(self, s):
        self.effect(s)

    def st_Cast(self, s):
        self.effect(s)

    def st_BinaryOp(self, s):
        self.effect(s)

    def st_TernaryOp(self, s):
        self.effect(s)

    def st_ID(self, s):
        pass

    def st_Constant(self, s):
        pass

    def st_StructRef(self, s):
        pass

    def st_Return(self, s):
        if s.expr is not None and not self.ret.is_void():
            x, xt = self.rv(s.expr)
            x = self.conv(x, xt, self.ret)
            x = self.as_int(x) if x.t == 'L' else x
            if has_call(x):
                x = self.to_temp(x)
            self.emit(SFrameRestore(self.fs))
            self.emit(SExit(x))
            return
        if s.expr is not None:
            self.effect(s.expr)
        self.emit(SFrameRestore(self.fs))
        if self.ret.is_void():
            self.emit(SExit(None))
        else:
            self.emit(SExit(c(0) if self.ret.alk() == 'I' else XC(0, self.ret.alk())))

    def st_If(self, s):
        cnd = self.cond(s.cond)
        self.release()
        sa, _ = self.capture(lambda: self.stmt(s.iftrue))
        sb = []
        if s.iffalse is not None:
            sb, _ = self.capture(lambda: self.stmt(s.iffalse))
        if isinstance(cnd, XC):
            self.out.extend(sa if cnd.v else sb)
            return
        if not sa and sb:
            self.emit(SIf(self.lnot(cnd), sb))
            return
        self.emit(SIf(cnd, sa, sb))

    def loop_body(self, ctx, body):
        self.loops.append(ctx)
        try:
            out, _ = self.capture(lambda: self.stmt(body))
        finally:
            self.loops.pop()
        return out

    def st_While(self, s):
        pre, cnd = self.capture(lambda: self.cond(s.cond))
        self.release()
        ctx = LoopCtx('loop', [])
        body = self.loop_body(ctx, s.stmt)
        if not pre:
            self.emit(SWhile(cnd, body))
        else:
            self.emit(SWhile(XC(True, 'L'), pre + [SIf(self.lnot(cnd), [SBreak()])] + body))

    def st_DoWhile(self, s):
        pre, cnd = self.capture(lambda: self.cond(s.cond))
        self.release()
        if not pre:
            ctx = LoopCtx('loop', [])
            body = self.loop_body(ctx, s.stmt)
            self.emit(SRepeat(body, self.lnot(cnd)))
        else:
            tail = pre + [SIf(self.lnot(cnd), [SBreak()])]
            ctx = LoopCtx('loop', tail)
            body = self.loop_body(ctx, s.stmt)
            self.emit(SWhile(XC(True, 'L'), body + tail))

    def st_For(self, s):
        self.scopes.append({})
        if s.init is not None:
            if isinstance(s.init, c_ast.DeclList):
                self.st_DeclList(s.init)
            else:
                self.effect(s.init)
            self.release()
        pre, cnd = [], XC(True, 'L')
        if s.cond is not None:
            pre, cnd = self.capture(lambda: self.cond(s.cond))
            self.release()
        step = []
        if s.next is not None:
            step, _ = self.capture(lambda: self.effect(s.next))
            self.release()
        ctx = LoopCtx('loop', step)
        body = self.loop_body(ctx, s.stmt)
        if not pre:
            self.emit(SWhile(cnd, body + step))
        else:
            self.emit(SWhile(XC(True, 'L'), pre + [SIf(self.lnot(cnd), [SBreak()])] + body + step))
        self.scopes.pop()

    def st_Break(self, s):
        ctx = self.loops[-1]
        if ctx.kind == 'case':
            return  # trailing break of an AL case arm
        self.emit(SBreak())

    def st_Continue(self, s):
        self.emit_continue(len(self.loops) - 1)

    def emit_continue(self, level):
        ctx = self.loops[level]
        if ctx.kind == 'loop':
            self.out.extend(clone_stmts(ctx.cont))
            self.emit(SContinue())
        elif ctx.kind == 'case':
            self.emit_continue(level - 1)
        else:
            if ctx.flag is None:
                ctx.flag = self.new_local('cont%d' % len(self.al_locals), 'L')
            self.emit(SAssign(ctx.flag, XC(True, 'L')))
            self.emit(SBreak())

    def st_Switch(self, s):
        sel, st = self.rv(s.cond)
        sel = self.conv(self.as_int(sel), st, promote(self.decay(st)))
        if sel.t != 'I':
            err(s, 'switch on non-int')
        items = s.stmt.block_items if isinstance(s.stmt, c_ast.Compound) else [s.stmt]
        groups = []  # (labels, stmts)
        labels = []
        for it in items or []:
            if isinstance(it, (c_ast.Case, c_ast.Default)):
                lab = 'default' if isinstance(it, c_ast.Default) else self.prog.const_eval(it.expr, self.typeof, self.shadowed)
                if lab is None:
                    err(it, 'non-constant case')
                labels.append(lab)
                if it.stmts:
                    groups.append((labels, list(it.stmts)))
                    labels = []
            else:
                if not groups:
                    err(it, 'statement before first case')
                groups[-1][1].append(it)
        if labels:
            groups.append((labels, []))
        if self.case_ok(groups):
            self.switch_case(sel, groups)
        else:
            self.switch_wrapped(sel, groups)

    def case_ok(self, groups):
        for gi, (labels, stmts) in enumerate(groups):
            last = gi == len(groups) - 1
            if stmts and isinstance(stmts[-1], c_ast.Break):
                body = stmts[:-1]
            elif not last and not (stmts and isinstance(stmts[-1], (c_ast.Return, c_ast.Continue))):
                return False
            else:
                body = stmts
            for b in body:
                if has_switch_break(b):
                    return False
        return True

    def switch_case(self, sel, groups):
        sel = self.to_temp(sel)
        self.release()
        ctx = LoopCtx('case')
        self.loops.append(ctx)
        arms = []
        default = None
        try:
            for labels, stmts in groups:
                body, _ = self.capture(lambda: self.scoped_block(stmts))
                vals = [wrap_to(INT, l) for l in labels if l != 'default']
                if 'default' in labels:
                    default = body
                    if vals:
                        arms.append((vals, clone_stmts(body)))
                else:
                    arms.append((vals, body))
        finally:
            self.loops.pop()
        if not arms:
            self.out.extend(default or [])
            return
        self.emit(SCase(sel, arms, default))

    def scoped_block(self, stmts):
        self.scopes.append({})
        self.block(stmts)
        self.scopes.pop()

    def switch_wrapped(self, sel, groups):
        idx = self.new_local('sw%d' % len(self.al_locals), 'I')
        arms = []
        default_idx = len(groups) + 1
        for gi, (labels, stmts) in enumerate(groups):
            vals = [wrap_to(INT, l) for l in labels if l != 'default']
            if 'default' in labels:
                default_idx = gi + 1
            if vals:
                arms.append((vals, [SAssign(idx, c(gi + 1))]))
        self.emit(SCase(sel, arms, [SAssign(idx, c(default_idx))]) if arms else SAssign(idx, c(default_idx)))
        self.release()
        ctx = LoopCtx('wrap')
        self.loops.append(ctx)
        body = []
        try:
            for gi, (labels, stmts) in enumerate(groups):
                b, _ = self.capture(lambda: self.scoped_block(stmts))
                body.append(SIf(XB('<=', XV(idx, 'I'), c(gi + 1), 'L'), b))
        finally:
            self.loops.pop()
        if ctx.flag:
            self.emit(SAssign(ctx.flag, XC(False, 'L')))
        self.emit(SRepeat(body, XC(True, 'L')))
        if ctx.flag:
            cont, _ = self.capture(lambda: self.emit_continue(len(self.loops) - 1))
            self.emit(SIf(XV(ctx.flag, 'L'), cont))

    # ------------------------------------------------------------ function
    def lower(self):
        f = self.f
        fd = f.node.decl.type
        params = []
        prologue = []
        pnodes = []
        if fd.args:
            for p in fd.args.params:
                if isinstance(p, c_ast.EllipsisParam):
                    err(p, 'varargs not supported')
                if isinstance(p, c_ast.Typename) or p.name is None:
                    t = self.prog.decl_type(p.type)
                    if t.is_void():
                        continue
                    err(p, 'unnamed parameter')
                pnodes.append(p)
        for p in pnodes:
            t = self.prog.adjust_param(self.prog.decl_type(p.type))
            if id(p) in self.laddr or t.is_struct():
                pal = self.new_local('p_' + p.name, 'I' if t.is_struct() else t.alk())
                params.append((pal, 'I' if t.is_struct() else t.alk()))
                al = max(t.align(), 1)
                self.frame = (self.frame + al - 1) // al * al
                off = self.frame
                self.frame += t.size()
                loc = Local(p.name, t, True, off=off)
                self.scopes[0][p.name] = ('local', loc)
                prologue.append((loc, pal, t))
            else:
                pal = self.new_local(p.name, t.alk())
                params.append((pal, t.alk()))
                self.scopes[0][p.name] = ('local', Local(p.name, t, False, alname=pal))
        self.al_locals.append(('fp_', 'I'))
        self.alnames['fp_'] = 'I'
        body_out, _ = self.capture(lambda: self.stmt(f.node.body))
        frame = (self.frame + 3) // 4 * 4
        self.fs['size'] = frame
        if frame == 0:
            self.al_locals = [(n, k) for n, k in self.al_locals if n != 'fp_']
            body = body_out
        else:
            body = [SAssign('fp_', XB('-', XV('SP', 'I'), c(frame), 'I')), SAssign('SP', XV('fp_', 'I'))]
            for loc, pal, t in prologue:
                a = self.frame_addr(loc.off)
                if t.is_struct():
                    body.append(SCall(XCall('Rt_MemCpy', [a, XV(pal, 'I'), c(t.size())], 'I')))
                else:
                    body.extend(self.capture(lambda: self.store(LMem(a, t), XV(pal, t.alk()), False))[0])
            body += body_out
            if not ends_with_exit(body):
                body.append(SFrameRestore(self.fs))
        if not self.ret.is_void() and not ends_with_exit(body):
            body.append(SExit(c(0) if self.ret.alk() == 'I' else XC(0, self.ret.alk())))
        rk = None if self.ret.is_void() else self.ret.alk()
        if self.ret.is_struct():
            err(f.node, 'struct return')
        return Proc(f.alname, params, rk, list(self.al_locals), body, f.name in self.comp.cfg.entry_points,
                    '%s:%s' % (f.coord.file.split('/')[-1], f.coord.line))


def ends_with_exit(body):
    return bool(body) and isinstance(body[-1], SExit)


def has_switch_break(n):
    """does statement contain a break that targets the enclosing switch"""
    if isinstance(n, c_ast.Break):
        return True
    if isinstance(n, (c_ast.For, c_ast.While, c_ast.DoWhile, c_ast.Switch)):
        return False
    for _, ch in n.children():
        if has_switch_break(ch):
            return True
    return False


def clone_stmts(lst):
    return list(lst)
