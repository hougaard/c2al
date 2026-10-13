# AL back end: prints the IR as one AL codeunit
from .ir import *

ATOMIC = (XV, XCall, XLoad, XTab)


class ALEmitter:
    def __init__(self, comp, layout, runtime_text, header):
        self.comp = comp
        self.layout = layout
        self.runtime = runtime_text
        self.header = header
        self.lines = []
        self.bigconsts = {}

    def w(self, s, ind):
        self.lines.append('    ' * ind + s)

    # -------------------------------------------------------- expressions
    def ex(self, x):
        if isinstance(x, XC):
            if x.t == 'L':
                return 'true' if x.v else 'false'
            if x.t == 'D':
                return repr(float(x.v))
            v = x.v
            if v < INT_MIN or v > INT_MAX:
                return self.bigconst(v)
            if v == INT_MIN:
                return '(-2147483647 - 1)'
            return str(v) if v >= 0 else '(%d)' % v
        if isinstance(x, XV):
            return x.name
        if isinstance(x, XBig):
            return '(BZ + %s)' % self.sub(x.a)
        if isinstance(x, XU):
            if x.op == 'not':
                return 'not %s' % self.sub(x.a)
            return '-%s' % self.sub(x.a)
        if isinstance(x, XLoad):
            a = x.addr
            g = lambda k: 'Mem.Get(%s)' % self.ex(addc(a, k + 1))
            if x.kind == 'u8':
                return g(0)
            if x.kind == 's8':
                return 'SX8[%s + 1]' % g(0)
            if x.kind == 'u16':
                return '(%s + 256 * %s)' % (g(0), g(1))
            if x.kind == 's16':
                return '(%s + 256 * SX8[%s + 1])' % (g(0), g(1))
            if x.kind == 'i32':
                return '(%s + 256 * (%s + 256 * (%s + 256 * SX8[%s + 1])))' % (g(0), g(1), g(2), g(3))
            raise Exception('bad load ' + x.kind)
        if isinstance(x, XTab):
            return '%s[%s]' % (x.tab, self.ex(x.idx))
        if isinstance(x, XCall):
            return '%s(%s)' % (x.name, ', '.join(self.ex(a) for a in x.args))
        if isinstance(x, XB):
            op = x.op
            if op == '/':
                op = '/'
            return '%s %s %s' % (self.sub(x.a), op, self.sub(x.b))
        raise Exception('cannot emit %r' % (x,))

    def sub(self, x):
        """sub-expression, parenthesised unless atomic"""
        s = self.ex(x)
        if isinstance(x, ATOMIC) or (isinstance(x, XC) and not s.startswith('-')):
            return s
        if s.startswith('(') and s.endswith(')') and self.balanced(s[1:-1]):
            return s
        return '(%s)' % s

    def balanced(self, s):
        d = 0
        for ch in s:
            if ch == '(':
                d += 1
            elif ch == ')':
                d -= 1
                if d < 0:
                    return False
        return d == 0

    def bigconst(self, v):
        n = self.bigconsts.get(v)
        if n is None:
            if v == 1 << 31:
                n = 'B31'
            elif v == 1 << 32:
                n = 'B32'
            else:
                n = 'BigK%d' % (len(self.bigconsts) + 1)
            self.bigconsts[v] = n
        return n

    # -------------------------------------------------------- statements
    def body(self, stmts, ind):
        for s in stmts:
            self.st(s, ind)

    def block(self, head, stmts, ind, tail=';'):
        self.w(head + ' begin', ind)
        self.body(stmts, ind + 1)
        self.w('end' + tail, ind)

    def st(self, s, ind):
        if isinstance(s, SAssign):
            self.w('%s := %s;' % (s.name, self.ex(s.x)), ind)
        elif isinstance(s, SStore):
            a = s.addr
            m = lambda k: self.ex(addc(a, k + 1))
            v = self.ex(s.x)
            if isinstance(s.x, XC) and s.bits in (16, 32):
                u = s.x.v & ((1 << s.bits) - 1)
                for k in range(s.bits // 8):
                    self.w('Mem.Set(%s, %d);' % (m(k), (u >> (8 * k)) & 255), ind)
                return
            if s.bits == 8:
                self.w('Mem.Set(%s, %s);' % (m(0), v), ind)
            elif s.bits == 16:
                vs = self.sub(s.x)
                self.w('Mem.Set(%s, %s mod 256);' % (m(0), vs), ind)
                self.w('Mem.Set(%s, %s div 256);' % (m(1), vs), ind)
            else:
                vs = self.sub(s.x)
                if nonneg(s.x):
                    self.store32_pos(m, vs, ind)
                else:
                    self.w('if %s >= 0 then begin' % vs, ind)
                    self.store32_pos(m, vs, ind + 1)
                    self.w('end else begin', ind)
                    nv = '(-1 - %s)' % vs
                    self.w('Mem.Set(%s, 255 - %s mod 256);' % (m(0), nv), ind + 1)
                    self.w('Mem.Set(%s, 255 - (%s div 256) mod 256);' % (m(1), nv), ind + 1)
                    self.w('Mem.Set(%s, 255 - (%s div 65536) mod 256);' % (m(2), nv), ind + 1)
                    self.w('Mem.Set(%s, 255 - %s div 16777216);' % (m(3), nv), ind + 1)
                    self.w('end;', ind)
        elif isinstance(s, SCall):
            self.w(self.ex(s.call) + ';', ind)
        elif isinstance(s, SIf):
            c = self.ex(s.c)
            if s.b:
                self.w('if %s then begin' % c, ind)
                self.body(s.a, ind + 1)
                self.w('end else begin', ind)
                self.body(s.b, ind + 1)
                self.w('end;', ind)
            else:
                self.block('if %s then' % c, s.a, ind)
        elif isinstance(s, SWhile):
            self.block('while %s do' % self.ex(s.c), s.body, ind)
        elif isinstance(s, SRepeat):
            self.w('repeat', ind)
            self.body(s.body, ind + 1)
            self.w('until %s;' % self.ex(s.c), ind)
        elif isinstance(s, SCase):
            self.w('case %s of' % self.ex(s.sel), ind)
            for vals, body in s.arms:
                self.w(', '.join(str(v) for v in vals) + ':', ind + 1)
                self.block('', body, ind + 2)
            if s.default:
                self.w('else begin', ind + 1)
                self.body(s.default, ind + 2)
                self.w('end;', ind + 1)
            self.w('end;', ind)
        elif isinstance(s, SBreak):
            self.w('break;', ind)
        elif isinstance(s, SContinue):
            self.w('continue;', ind)
        elif isinstance(s, SExit):
            if s.x is None:
                self.w('exit;', ind)
            else:
                self.w('exit(%s);' % self.ex(s.x), ind)
        elif isinstance(s, SFrameRestore):
            if s.fs['size']:
                self.w('SP := fp_ + %d;' % s.fs['size'], ind)
        elif isinstance(s, SComment):
            self.w('// ' + s.text, ind)
        else:
            raise Exception('cannot emit stmt %r' % s)

    def store32_pos(self, m, vs, ind):
        self.w('Mem.Set(%s, %s mod 256);' % (m(0), vs), ind)
        self.w('Mem.Set(%s, (%s div 256) mod 256);' % (m(1), vs), ind)
        self.w('Mem.Set(%s, (%s div 65536) mod 256);' % (m(2), vs), ind)
        self.w('Mem.Set(%s, %s div 16777216);' % (m(3), vs), ind)

    # -------------------------------------------------------- program
    ALTYPE = {'I': 'Integer', 'B': 'BigInteger', 'L': 'Boolean', 'D': 'Decimal'}

    def proc(self, p):
        self.w('', 1)
        self.w('// %s' % p.comment, 1)
        params = '; '.join('%s: %s' % (n, self.ALTYPE[k]) for n, k in p.params)
        ret = (': ' + self.ALTYPE[p.ret]) if p.ret else ''
        self.w('%sprocedure %s(%s)%s' % ('' if p.public else 'local ', p.name, params, ret), 1)
        pset = {n.lower() for n, k in p.params}
        locs = [(n, k) for n, k in p.locals if n.lower() not in pset]
        if locs:
            self.w('var', 1)
            for n, k in locs:
                self.w('%s: %s;' % (n, self.ALTYPE[k]), 2)
        self.w('begin', 1)
        self.body(p.body, 2)
        self.w('end;', 1)

    def emit(self, object_id, object_name):
        comp = self.comp
        body_start = len(self.lines)
        for p in comp.procs:
            self.proc(p)
        self.emit_dispatch()
        self.emit_globals_init()
        self.emit_data()
        body = self.lines[body_start:]
        self.lines = self.lines[:body_start]
        w = self.w
        for l in self.header:
            w('// ' + l, 0)
        w('codeunit %d "%s"' % (object_id, object_name), 0)
        w('{', 0)
        w('var', 1)
        w('Mem: List of [Integer];', 2)
        w('SP: Integer;', 2)
        w('BZ: BigInteger;', 2)
        w('B31: BigInteger;', 2)
        w('B32: BigInteger;', 2)
        for v, n in sorted(self.bigconsts.items(), key=lambda kv: kv[1]):
            if n not in ('B31', 'B32'):
                w('%s: BigInteger;' % n, 2)
        w('SX8: array[256] of Integer;', 2)
        w('Pow2: array[32] of Integer;', 2)
        for name, k, v in comp.al_globals:
            w('%s: %s;' % (name, self.ALTYPE[k]), 2)
        rt = self.runtime
        rt = rt.replace('%MEMSIZE%', str(self.layout['memsize']))
        rt = rt.replace('%STACKTOP%', str(self.layout['stack_top']))
        rt = rt.replace('%HEAPSTART%', str(self.layout['heap_start']))
        rt = rt.replace('%DATASTART%', str(self.layout['data_start']))
        bc = []
        for v, n in sorted(self.bigconsts.items(), key=lambda kv: kv[1]):
            if n not in ('B31', 'B32'):
                bc.append("        Evaluate(%s, '%d');" % (n, v))
        rt = rt.replace('        // %BIGCONSTS%', '\n'.join(bc))
        self.lines.extend(rt.rstrip('\n').split('\n'))
        self.lines.extend(body)
        w('}', 0)
        return '\n'.join(self.lines) + '\n'

    def emit_dispatch(self):
        comp = self.comp
        prog = comp.prog
        targets = [f for f in prog.funcs.values() if f.reachable and f.fid is not None]
        for n, rk in sorted(comp.dispatch, key=lambda x: (x[0], str(x[1]))):
            args = ['a%d' % i for i in range(n)]
            name = ('CallFn%d' % n) if rk else ('CallFnV%d' % n)
            params = '; '.join(['f: Integer'] + ['%s: Integer' % a for a in args])
            self.w('', 1)
            self.w('// call through a C function pointer', 1)
            self.w('local procedure %s(%s)%s' % (name, params, ': Integer' if rk else ''), 1)
            self.w('begin', 1)
            self.w('case f of', 2)
            for f in sorted(targets, key=lambda f: f.fid):
                if len(f.type.params) != n:
                    continue
                call = '%s(%s)' % (f.alname, ', '.join(args))
                if rk and not f.type.ret.is_void():
                    self.w('%d:' % f.fid, 3)
                    self.w('exit(%s);' % call, 4)
                else:
                    self.w('%d:' % f.fid, 3)
                    self.w('begin', 4)
                    self.w('%s;' % call, 5)
                    self.w('exit%s;' % ('(0)' if rk else ''), 5)
                    self.w('end;', 4)
            self.w('end;', 2)
            self.w("Error('%s: bad function pointer %%1 in %s', f);" % (comp.cfg.error_tag, name), 2)
            self.w('end;', 1)

    def emit_globals_init(self):
        self.w('', 1)
        self.w('local procedure InitGlobals()', 1)
        self.w('begin', 1)
        for name, k, v in self.comp.al_globals:
            if v:
                self.w('%s := %s;' % (name, self.ex(XC(v, k))), 2)
        self.w('end;', 1)

    def emit_data(self):
        """initial data segment, run length encoded: hex bytes, 'Z'+4 hex = run of zeros"""
        img = self.comp.image
        out = []
        i = 0
        n = len(img)
        while i < n:
            if img[i] == 0:
                j = i
                while j < n and img[j] == 0 and j - i < 0xffff:
                    j += 1
                if j - i >= 3:
                    out.append('Z%04X' % (j - i))
                    i = j
                    continue
            out.append('%02X' % img[i])
            i += 1
        s = ''.join(out)
        chunks = [s[k:k + 1000] for k in range(0, len(s), 1000)]
        per = 400
        groups = [chunks[k:k + per] for k in range(0, len(chunks), per)]
        self.w('', 1)
        self.w('local procedure InitData()', 1)
        self.w('var', 1)
        self.w('D: TextBuilder;', 2)
        self.w('begin', 1)
        for gi in range(len(groups)):
            self.w('DataPart%d(D);' % gi, 2)
        self.w('DecodeData(D.ToText(), %d);' % self.comp.data_start, 2)
        self.w('end;', 1)
        for gi, g in enumerate(groups):
            self.w('', 1)
            self.w('local procedure DataPart%d(var D: TextBuilder)' % gi, 1)
            self.w('begin', 1)
            for ch in g:
                self.w("D.Append('%s');" % ch, 2)
            self.w('end;', 1)
