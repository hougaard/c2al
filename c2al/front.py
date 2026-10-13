# Front end: symbol tables, declaration types, constant evaluation
from pycparser import c_ast
from .ctypes_ import *


class CompileError(Exception):
    pass


def err(node, msg):
    raise CompileError('%s: %s' % (getattr(node, 'coord', '?'), msg))


class GVar:
    def __init__(self, name, type, coord):
        self.name = name
        self.type = type
        self.init = None
        self.coord = coord
        self.defined = False
        self.static = False
        self.reachable = False
        self.addr_taken = False
        self.mem = False  # lives in Mem (else AL global variable)
        self.addr = None
        self.alname = None
        self.owner = None  # function name for static locals


class Func:
    def __init__(self, name, type, coord):
        self.name = name
        self.type = type
        self.node = None  # FuncDef
        self.coord = coord
        self.reachable = False
        self.addr_taken = False
        self.fid = None
        self.alname = None
        self.native = False
        self.intrinsic = None
        self.static_locals = {}  # id(decl node) -> GVar


def parse_int_literal(s):
    s0 = s
    s = s.lower()
    suf = ''
    while s and s[-1] in 'ul':
        suf = s[-1] + suf
        s = s[:-1]
    if s.startswith('0x'):
        v = int(s, 16)
        base = 16
    elif s.startswith('0b'):
        v = int(s[2:], 2)
        base = 2
    elif len(s) > 1 and s.startswith('0'):
        v = int(s, 8)
        base = 8
    else:
        v = int(s)
        base = 10
    unsigned = 'u' in suf
    longs = suf.count('l')
    if longs >= 2:
        return v, (ULLONG if unsigned else LLONG)
    if unsigned:
        return v, (UINT if v < (1 << 32) else ULLONG)
    if v < (1 << 31):
        return v, INT
    if base != 10 and v < (1 << 32):
        return v, UINT
    return v, LLONG


ESC = {'n': 10, 't': 9, 'r': 13, '0': 0, '\\': 92, "'": 39, '"': 34, 'a': 7, 'b': 8, 'f': 12, 'v': 11, '?': 63}


def parse_char_body(s):
    """parse the inside of a char/string literal into list of byte values"""
    out = []
    i = 0
    while i < len(s):
        ch = s[i]
        if ch == '\\':
            i += 1
            e = s[i]
            if e == 'x':
                j = i + 1
                while j < len(s) and s[j] in '0123456789abcdefABCDEF':
                    j += 1
                out.append(int(s[i + 1:j], 16) & 255)
                i = j
                continue
            if e in '01234567':
                j = i
                while j < len(s) and j < i + 3 and s[j] in '01234567':
                    j += 1
                out.append(int(s[i:j], 8) & 255)
                i = j
                continue
            out.append(ESC[e])
            i += 1
            continue
        out.append(ord(ch) & 255)
        i += 1
    return out


def parse_char_literal(s):
    assert s[0] == "'" and s[-1] == "'", s
    b = parse_char_body(s[1:-1])
    v = b[0]
    if v >= 128:
        v -= 256  # plain char is signed
    return v


def parse_string_literal(s):
    assert s[0] == '"' and s[-1] == '"', s
    return parse_char_body(s[1:-1])


class Program:
    def __init__(self, ast):
        self.ast = ast
        self.typedefs = {}
        self.tags = {}
        self.enums = {}
        self.globals = {}
        self.funcs = {}
        self.collect()

    # ------------------------------------------------------------ types
    def base_type(self, node):
        if isinstance(node, c_ast.IdentifierType):
            names = node.names
            if len(names) == 1 and names[0] in self.typedefs:
                return self.typedefs[names[0]]
            t = int_from_names(names)
            if t is None:
                err(node, 'unknown type %s' % names)
            return t
        if isinstance(node, (c_ast.Struct, c_ast.Union)):
            union = isinstance(node, c_ast.Union)
            if node.decls is None:
                key = ('u' if union else 's') + str(node.name)
                if node.name and key in self.tags:
                    return self.tags[key]
                t = TStruct(node.name, union)
                if node.name:
                    self.tags[key] = t
                return t
            key = ('u' if union else 's') + str(node.name)
            if node.name and key in self.tags and not self.tags[key].complete:
                t = self.tags[key]
            elif node.name and key in self.tags and self.tags[key].complete:
                return self.tags[key]
            else:
                t = TStruct(node.name, union)
                if node.name:
                    self.tags[key] = t
            members = []
            for d in node.decls:
                if d.bitsize:
                    err(d, 'bitfields not supported')
                members.append((d.name, self.decl_type(d.type)))
            t.layout(members)
            return t
        if isinstance(node, c_ast.Enum):
            if node.values:
                v = -1
                for e in node.values.enumerators:
                    if e.value is not None:
                        v = self.const_eval(e.value)
                        if v is None:
                            err(e, 'bad enum value')
                    else:
                        v += 1
                    self.enums[e.name] = v
            return INT
        err(node, 'unknown base type %s' % type(node).__name__)

    def decl_type(self, node):
        if isinstance(node, c_ast.TypeDecl):
            return self.base_type(node.type)
        if isinstance(node, c_ast.PtrDecl):
            return TPtr(self.decl_type(node.type))
        if isinstance(node, c_ast.ArrayDecl):
            elem = self.decl_type(node.type)
            n = None
            if node.dim is not None:
                n = self.const_eval(node.dim)
                if n is None:
                    err(node, 'non-constant array size')
            return TArr(elem, n)
        if isinstance(node, c_ast.FuncDecl):
            ret = self.decl_type(node.type)
            params = []
            varargs = False
            if node.args:
                for p in node.args.params:
                    if isinstance(p, c_ast.EllipsisParam):
                        varargs = True
                        continue
                    pt = self.decl_type(p.type)
                    if pt.is_void():
                        continue
                    params.append(self.adjust_param(pt))
            return TFunc(ret, params, varargs)
        if isinstance(node, c_ast.Typename):
            return self.decl_type(node.type)
        err(node, 'unknown declarator %s' % type(node).__name__)

    def adjust_param(self, t):
        if t.is_arr():
            return TPtr(t.elem)
        if t.is_func():
            return TPtr(t)
        return t

    # ------------------------------------------------------------ constants
    def const_eval(self, e, typer=None, shadow=None):
        """evaluate integer constant expression -> python int (C semantics) or None"""
        r = self.const_eval_t(e, typer, shadow)
        return None if r is None else r[0]

    def const_eval_t(self, e, typer=None, shadow=None):
        if isinstance(e, c_ast.Constant):
            if e.type in ('int', 'unsigned int', 'long int', 'unsigned long int', 'long long int', 'unsigned long long int'):
                return parse_int_literal(e.value)
            if e.type == 'char':
                return parse_char_literal(e.value), INT
            if e.type in ('float', 'double'):
                return float(e.value.rstrip('fFlL')), DOUBLE
            return None
        if isinstance(e, c_ast.ID):
            if shadow is not None and shadow(e.name):
                return None
            if e.name in self.enums:
                return self.enums[e.name], INT
            return None
        if isinstance(e, c_ast.UnaryOp):
            if e.op == 'sizeof':
                if isinstance(e.expr, c_ast.Typename):
                    return self.decl_type(e.expr.type).size(), UINT
                if typer is None:
                    return None
                t = typer(e.expr)
                return t.size(), UINT
            r = self.const_eval_t(e.expr, typer, shadow)
            if r is None:
                return None
            v, t = r
            t = promote(t)
            if t.is_float():
                if e.op == '-':
                    return -v, t
                if e.op == '+':
                    return v, t
                return None
            if e.op == '-':
                return wrap_to(t, -v), t
            if e.op == '+':
                return v, t
            if e.op == '~':
                return wrap_to(t, ~v), t
            if e.op == '!':
                return (0 if v else 1), INT
            return None
        if isinstance(e, c_ast.BinaryOp):
            ra = self.const_eval_t(e.left, typer, shadow)
            if ra is None:
                return None
            if e.op == '&&':
                if not ra[0]:
                    return 0, INT
                rb = self.const_eval_t(e.right, typer, shadow)
                return None if rb is None else ((1 if rb[0] else 0), INT)
            if e.op == '||':
                if ra[0]:
                    return 1, INT
                rb = self.const_eval_t(e.right, typer, shadow)
                return None if rb is None else ((1 if rb[0] else 0), INT)
            rb = self.const_eval_t(e.right, typer, shadow)
            if rb is None:
                return None
            a, at = ra
            b, bt = rb
            if e.op in ('<<', '>>'):
                t = promote(at)
                a = wrap_to(t, a)
                if e.op == '<<':
                    return wrap_to(t, a << b), t
                return wrap_to(t, a >> b), t
            t = arith_conv(at, bt)
            op = e.op
            if t.is_float():
                a = float(a)
                b = float(b)
                if op == '+': return a + b, t
                if op == '-': return a - b, t
                if op == '*': return a * b, t
                if op == '/': return a / b, t
                return None
            a = wrap_to(t, a)
            b = wrap_to(t, b)
            if op == '+': return wrap_to(t, a + b), t
            if op == '-': return wrap_to(t, a - b), t
            if op == '*': return wrap_to(t, a * b), t
            if op == '/':
                if b == 0: return None
                q = abs(a) // abs(b)
                return wrap_to(t, q if (a >= 0) == (b >= 0) else -q), t
            if op == '%':
                if b == 0: return None
                q = abs(a) // abs(b)
                q = q if (a >= 0) == (b >= 0) else -q
                return wrap_to(t, a - q * b), t
            if op == '&': return wrap_to(t, a & b), t
            if op == '|': return wrap_to(t, a | b), t
            if op == '^': return wrap_to(t, a ^ b), t
            if op == '==': return int(a == b), INT
            if op == '!=': return int(a != b), INT
            if op == '<': return int(a < b), INT
            if op == '>': return int(a > b), INT
            if op == '<=': return int(a <= b), INT
            if op == '>=': return int(a >= b), INT
            return None
        if isinstance(e, c_ast.TernaryOp):
            r = self.const_eval_t(e.cond, typer, shadow)
            if r is None:
                return None
            return self.const_eval_t(e.iftrue if r[0] else e.iffalse, typer, shadow)
        if isinstance(e, c_ast.Cast):
            t = self.decl_type(e.to_type.type)
            r = self.const_eval_t(e.expr, typer, shadow)
            if r is None:
                return None
            if t.is_float():
                return float(r[0]), t
            if not t.is_int():
                return None
            return wrap_to(t, int(r[0])), t
        return None

    # ------------------------------------------------------------ collect
    def collect(self):
        for ext in self.ast.ext:
            if isinstance(ext, c_ast.Typedef):
                self.typedefs[ext.name] = self.decl_type(ext.type)
            elif isinstance(ext, c_ast.Decl):
                self.collect_decl(ext)
            elif isinstance(ext, c_ast.FuncDef):
                d = ext.decl
                ft = self.decl_type(d.type)
                f = self.funcs.get(d.name)
                if f is None:
                    f = Func(d.name, ft, d.coord)
                    self.funcs[d.name] = f
                f.type = ft
                f.node = ext
                f.coord = d.coord
                self.collect_static_locals(f, ext.body)
            elif isinstance(ext, c_ast.Pragma):
                pass
            else:
                err(ext, 'unexpected top level %s' % type(ext).__name__)

    def collect_decl(self, d):
        if d.name is None:
            # struct / enum declaration
            self.base_type(d.type.type if isinstance(d.type, c_ast.TypeDecl) else d.type)
            return
        t = self.decl_type(d.type)
        if t.is_func():
            if d.name not in self.funcs:
                self.funcs[d.name] = Func(d.name, t, d.coord)
            return
        g = self.globals.get(d.name)
        if g is None:
            g = GVar(d.name, t, d.coord)
            self.globals[d.name] = g
        if 'extern' not in (d.storage or []) or d.init is not None:
            g.defined = True
        if t.is_arr() and t.n is None and d.init is not None:
            t = self.complete_array(t, d.init)
        if t.is_arr() and t.n is not None or not t.is_arr():
            if not (g.type.is_arr() and g.type.n is not None and t.is_arr() and t.n is None):
                g.type = t
        if d.init is not None:
            g.init = d.init
        if 'static' in (d.storage or []):
            g.static = True

    def complete_array(self, t, init):
        if isinstance(init, c_ast.InitList):
            n = 0
            idx = 0
            for e in init.exprs:
                if isinstance(e, c_ast.NamedInitializer):
                    idx = self.const_eval(e.name[0])
                idx += 1
                n = max(n, idx)
            return TArr(t.elem, n)
        if isinstance(init, c_ast.Constant) and init.type == 'string':
            return TArr(t.elem, len(parse_string_literal(init.value)) + 1)
        err(init, 'cannot size array')

    def collect_static_locals(self, f, node):
        if node is None:
            return
        if isinstance(node, c_ast.Decl) and 'static' in (node.storage or []) and not isinstance(node.type, c_ast.FuncDecl):
            name = '%s_%s' % (f.name, node.name)
            t = self.decl_type(node.type)
            if t.is_arr() and t.n is None and node.init is not None:
                t = self.complete_array(t, node.init)
            g = GVar(name, t, node.coord)
            g.defined = True
            g.init = node.init
            g.static = True
            g.owner = f.name
            self.globals[name] = g
            f.static_locals[id(node)] = g
            return
        for _, ch in node.children():
            self.collect_static_locals(f, ch)
