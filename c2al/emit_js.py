# JavaScript back end: mirrors AL semantics exactly (used to test the lowering locally)
from .ir import *


class JSEmitter:
    def __init__(self, comp, checked=True, profile=False):
        self.profile = profile
        self.comp = comp
        self.checked = checked
        self.lines = []
        self.loop_labels = []
        self.label_id = 0

    def w(self, s, ind):
        self.lines.append('  ' * ind + s)

    def name(self, n):
        return '$' + n

    # -------------------------------------------------------- expressions
    def ex(self, x, want=None):
        """emit expression; want: required kind ('I','B','D','L') or None"""
        s = self._ex(x)
        if want == 'B' and x.t == 'I':
            return 'BigInt(%s)' % s
        if want == 'I' and x.t == 'B':
            return 'toI(%s)' % s
        if want == 'D' and x.t in ('I',):
            return s
        if want == 'D' and x.t == 'B':
            return 'Number(%s)' % s
        return s

    def _ex(self, x):
        if isinstance(x, XC):
            if x.t == 'B':
                return '%dn' % x.v
            if x.t == 'L':
                return 'true' if x.v else 'false'
            if x.t == 'D':
                return repr(float(x.v))
            return '(%d)' % x.v if x.v < 0 else str(x.v)
        if isinstance(x, XV):
            return self.name(x.name)
        if isinstance(x, XBig):
            return 'BigInt(%s)' % self.ex(x.a)
        if isinstance(x, XU):
            if x.op == 'not':
                return '(!%s)' % self.ex(x.a)
            if x.t == 'I' and self.checked:
                return 'ck(-%s)' % self.ex(x.a)
            return '(-%s)' % self.ex(x.a, x.t)
        if isinstance(x, XLoad):
            a = x.addr
            if x.kind == 'u8':
                return 'M[%s]' % self.ex(a)
            if x.kind == 's8':
                return 'SX8[M[%s] + 1]' % self.ex(a)
            if x.kind == 'u16':
                return '(M[%s] + 256 * M[%s])' % (self.ex(a), self.ex(addc(a, 1)))
            if x.kind == 's16':
                return '(M[%s] + 256 * SX8[M[%s] + 1])' % (self.ex(a), self.ex(addc(a, 1)))
            if x.kind == 'i32':
                return '(M[%s] + 256 * (M[%s] + 256 * (M[%s] + 256 * SX8[M[%s] + 1])))' % (
                    self.ex(a), self.ex(addc(a, 1)), self.ex(addc(a, 2)), self.ex(addc(a, 3)))
            raise Exception('bad load ' + x.kind)
        if isinstance(x, XTab):
            return '%s[%s]' % (x.tab, self.ex(x.idx, 'I'))
        if isinstance(x, XCall):
            args = ', '.join(self.ex(a) for a in x.args)
            return '%s(%s)' % (self.name(x.name), args)
        if isinstance(x, XB):
            op = x.op
            if x.t == 'L' and op in ('and', 'or', 'xor'):
                a = self.ex(x.a)
                b = self.ex(x.b)
                if op == 'and':
                    return '((%s & %s) !== 0)' % (a, b)
                if op == 'or':
                    return '((%s | %s) !== 0)' % (a, b)
                return '(%s !== %s)' % (a, b)
            if x.t == 'L':
                # comparison
                k = 'I'
                if x.a.t == 'B' or x.b.t == 'B':
                    k = 'B'
                if x.a.t == 'D' or x.b.t == 'D':
                    k = 'D'
                if x.a.t == 'L':
                    k = 'L'
                a = self.ex(x.a, k)
                b = self.ex(x.b, k)
                jop = {'=': '===', '<>': '!==', '<': '<', '>': '>', '<=': '<=', '>=': '>='}[op]
                return '(%s %s %s)' % (a, jop, b)
            k = x.t
            a = self.ex(x.a, k)
            b = self.ex(x.b, k)
            if k == 'I':
                if op == 'div':
                    return 'idiv(%s, %s)' % (a, b)
                if op == 'mod':
                    return 'imod(%s, %s)' % (a, b)
                if self.checked:
                    if op == '*':
                        return 'ckm(%s, %s, %d)' % (a, b, x.line or 0)
                    return 'ck(%s %s %s, %d)' % (a, op, b, x.line or 0)
                return '((%s %s %s) | 0)' % (a, op, b)
            if k == 'B':
                if op == 'div':
                    return 'bdiv(%s, %s)' % (a, b)
                if op == 'mod':
                    return 'bmod(%s, %s)' % (a, b)
                return 'ck64(%s %s %s)' % (a, op, b)
            if k == 'D':
                if op == 'div':
                    return 'Math.trunc(%s / %s)' % (a, b)
                return '(%s %s %s)' % (a, op, b)
        raise Exception('cannot emit %r' % (x,))

    # -------------------------------------------------------- statements
    def body(self, stmts, ind, kinds):
        for s in stmts:
            self.st(s, ind, kinds)

    def st(self, s, ind, kinds):
        if isinstance(s, SAssign):
            k = kinds.get(s.name.lower(), 'I')
            self.w('%s = %s;' % (self.name(s.name), self.ex(s.x, k)), ind)
        elif isinstance(s, SStore):
            a = self.ex(s.addr)
            if s.bits == 8:
                self.w('st8(%s, %s);' % (a, self.ex(s.x, 'I')), ind)
            elif s.bits == 16:
                self.w('st16(%s, %s);' % (a, self.ex(s.x, 'I')), ind)
            else:
                self.w('st32(%s, %s);' % (a, self.ex(s.x, 'I')), ind)
        elif isinstance(s, SCall):
            self.w(self.ex(s.call) + ';', ind)
        elif isinstance(s, SIf):
            self.w('if (%s) {' % self.ex(s.c), ind)
            self.body(s.a, ind + 1, kinds)
            if s.b:
                self.w('} else {', ind)
                self.body(s.b, ind + 1, kinds)
            self.w('}', ind)
        elif isinstance(s, SWhile):
            lab = self.new_label()
            self.w('%s: while (%s) {' % (lab, self.ex(s.c)), ind)
            self.loop_labels.append(lab)
            self.body(s.body, ind + 1, kinds)
            self.loop_labels.pop()
            self.w('}', ind)
        elif isinstance(s, SRepeat):
            lab = self.new_label()
            self.w('%s: do {' % lab, ind)
            self.loop_labels.append(lab)
            self.body(s.body, ind + 1, kinds)
            self.loop_labels.pop()
            self.w('} while (!%s);' % self.ex(s.c), ind)
        elif isinstance(s, SCase):
            self.w('switch (%s) {' % self.ex(s.sel, 'I'), ind)
            for vals, body in s.arms:
                self.w(' '.join('case %d:' % v for v in vals) + ' {', ind + 1)
                self.body(body, ind + 2, kinds)
                self.w('} break;', ind + 1)
            if s.default:
                self.w('default: {', ind + 1)
                self.body(s.default, ind + 2, kinds)
                self.w('}', ind + 1)
            self.w('}', ind)
        elif isinstance(s, SBreak):
            self.w('break %s;' % self.loop_labels[-1], ind)
        elif isinstance(s, SContinue):
            self.w('continue %s;' % self.loop_labels[-1], ind)
        elif isinstance(s, SExit):
            if s.x is None:
                self.w('return;', ind)
            else:
                self.w('return %s;' % self.ex(s.x, kinds['$ret']), ind)
        elif isinstance(s, SFrameRestore):
            if s.fs['size']:
                self.w('$SP = $fp_ + %d;' % s.fs['size'], ind)
        elif isinstance(s, SComment):
            self.w('// ' + s.text, ind)
        else:
            raise Exception('cannot emit stmt %r' % s)

    def new_label(self):
        self.label_id += 1
        return 'L%d' % self.label_id

    def default(self, k):
        return {'I': '0', 'B': '0n', 'L': 'false', 'D': '0'}[k]

    # -------------------------------------------------------- program
    def emit(self):
        comp = self.comp
        w = self.w
        w('"use strict";', 0)
        w('module.exports = function (rt) {', 0)
        w('const M = rt.M, SX8 = rt.SX8, Pow2 = rt.Pow2;', 1)
        w('const ck = rt.ck, ckm = rt.ckm, ck64 = rt.ck64, idiv = rt.idiv, imod = rt.imod, bdiv = rt.bdiv, bmod = rt.bmod, toI = rt.toI;', 1)
        w('const st8 = rt.st8, st16 = rt.st16, st32 = rt.st32;', 1)
        w('let $SP = 0;', 1)
        w('const $B31 = 2147483648n, $B32 = 4294967296n, $BZ = 0n;', 1)
        for name, k, v in comp.al_globals:
            init = ('%dn' % v) if k == 'B' else str(v)
            w('let %s = %s;' % (self.name(name), init), 1)
        for nat in sorted(rt_names(comp)):
            w('const %s = rt.%s;' % (self.name(nat), nat), 1)
        w('function $B2I(b) { return b ? 1 : 0; }', 1)
        for p in comp.procs:
            kinds = {n.lower(): k for n, k in p.locals}
            for n, k in p.params:
                kinds[n.lower()] = k
            for name, k, v in comp.al_globals:
                kinds.setdefault(name.lower(), k)
            kinds['sp'] = 'I'
            kinds['$ret'] = p.ret
            params = ', '.join(self.name(n) for n, k in p.params)
            w('function %s(%s) { // %s' % (self.name(p.name), params, p.comment), 1)
            if self.profile:
                w('rt.prof[%r] = (rt.prof[%r] || 0) + 1;' % (p.name, p.name), 2)
            pset = {n.lower() for n, k in p.params}
            locs = [(n, k) for n, k in p.locals if n.lower() not in pset]
            if locs:
                w('let ' + ', '.join('%s = %s' % (self.name(n), self.default(k)) for n, k in locs) + ';', 2)
            self.body(p.body, 2, kinds)
            w('}', 1)
        self.emit_dispatch()
        w('return {', 1)
        for p in comp.procs:
            if p.public:
                w('%s: %s,' % (p.name, self.name(p.name)), 2)
        w('getSP: () => $SP, setSP: (v) => { $SP = v; },', 2)
        w('};', 1)
        w('};', 0)
        return '\n'.join(self.lines) + '\n'

    def emit_dispatch(self):
        comp = self.comp
        prog = comp.prog
        procs = {p.name: p for p in comp.procs}
        targets = [f for f in prog.funcs.values() if f.reachable and f.fid is not None]
        for n, rk in sorted(comp.dispatch, key=lambda x: (x[0], str(x[1]))):
            args = ['a%d' % i for i in range(n)]
            name = ('CallFn%d' % n) if rk else ('CallFnV%d' % n)
            self.w('function %s(f%s) {' % (self.name(name), ''.join(', ' + a for a in args)), 1)
            self.w('switch (f) {', 2)
            for f in sorted(targets, key=lambda f: f.fid):
                if len(f.type.params) != n:
                    continue
                call = '%s(%s)' % (self.name(f.alname), ', '.join(args))
                if rk:
                    if f.type.ret.is_void():
                        self.w('case %d: %s; return 0;' % (f.fid, call), 3)
                    else:
                        self.w('case %d: return %s;' % (f.fid, call), 3)
                else:
                    self.w('case %d: %s; return;' % (f.fid, call), 3)
            self.w('}', 2)
            self.w('throw new Error("bad function pointer " + f + " in %s");' % name, 2)
            self.w('}', 1)


def rt_names(comp):
    names = set()
    for f in comp.prog.funcs.values():
        if f.reachable and (f.native or f.intrinsic):
            names.add(f.alname)

    def scan_x(x):
        if isinstance(x, XCall):
            if x.name.startswith('Rt_'):
                names.add(x.name)
            for a in x.args:
                scan_x(a)
        elif isinstance(x, XB):
            scan_x(x.a)
            scan_x(x.b)
        elif isinstance(x, (XU, XBig)):
            scan_x(x.a)
        elif isinstance(x, XLoad):
            scan_x(x.addr)
        elif isinstance(x, XTab):
            scan_x(x.idx)

    def scan_s(lst):
        for s in lst:
            for attr in ('x', 'c', 'addr', 'call', 'sel'):
                v = getattr(s, attr, None)
                if isinstance(v, X):
                    scan_x(v)
            for attr in ('a', 'b', 'body', 'default'):
                v = getattr(s, attr, None)
                if isinstance(v, list):
                    scan_s(v)
            if isinstance(s, SCase):
                for vals, b in s.arms:
                    scan_s(b)
    for p in comp.procs:
        scan_s(p.body)
    return names
