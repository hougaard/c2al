# Intermediate representation: structured AL-like statements and typed expressions.
# Expression value kinds: 'I' Integer, 'B' BigInteger, 'D' Decimal, 'L' Boolean.

INT_MIN = -(1 << 31)
INT_MAX = (1 << 31) - 1


class X:
    __slots__ = ('t',)


class XC(X):
    __slots__ = ('v',)

    def __init__(self, v, t='I'):
        self.v = v
        self.t = t

    def __repr__(self): return 'C(%r)' % (self.v,)


class XV(X):
    __slots__ = ('name',)

    def __init__(self, name, t):
        self.name = name
        self.t = t

    def __repr__(self): return 'V(%s)' % self.name


class XB(X):
    __slots__ = ('op', 'a', 'b', 'line')

    def __init__(self, op, a, b, t, line=None):
        self.op = op
        self.a = a
        self.b = b
        self.t = t
        self.line = line

    def __repr__(self): return '(%r %s %r)' % (self.a, self.op, self.b)


class XU(X):
    __slots__ = ('op', 'a')

    def __init__(self, op, a, t):
        self.op = op  # 'neg' or 'not'
        self.a = a
        self.t = t


class XCall(X):
    __slots__ = ('name', 'args', 'pure')

    def __init__(self, name, args, t, pure=False):
        self.name = name
        self.args = args
        self.t = t  # None for void
        self.pure = pure


class XLoad(X):
    __slots__ = ('kind', 'addr')

    def __init__(self, kind, addr):
        self.kind = kind  # u8 s8 u16 s16 i32
        self.addr = addr
        self.t = 'I'


class XTab(X):
    __slots__ = ('tab', 'idx')

    def __init__(self, tab, idx):
        self.tab = tab
        self.idx = idx  # 1-based AL index
        self.t = 'I'


class XBig(X):
    """promote Integer to BigInteger"""
    __slots__ = ('a',)

    def __init__(self, a):
        self.a = a
        self.t = 'B'


# ------------------------------------------------------------ statements
class S:
    __slots__ = ()


class SAssign(S):
    __slots__ = ('name', 'x')

    def __init__(self, name, x):
        self.name = name
        self.x = x


class SStore(S):
    __slots__ = ('bits', 'addr', 'x')

    def __init__(self, bits, addr, x):
        self.bits = bits  # 8,16,32 ; x already normalised to unsigned range for 8/16
        self.addr = addr
        self.x = x


class STabSet(S):
    __slots__ = ('tab', 'idx', 'x')

    def __init__(self, tab, idx, x):
        self.tab = tab
        self.idx = idx
        self.x = x


class SCall(S):
    __slots__ = ('call',)

    def __init__(self, call):
        self.call = call


class SIf(S):
    __slots__ = ('c', 'a', 'b')

    def __init__(self, c, a, b=None):
        self.c = c
        self.a = a
        self.b = b or []


class SWhile(S):
    __slots__ = ('c', 'body')

    def __init__(self, c, body):
        self.c = c
        self.body = body


class SRepeat(S):
    __slots__ = ('body', 'c')

    def __init__(self, body, c):
        self.body = body
        self.c = c


class SCase(S):
    __slots__ = ('sel', 'arms', 'default')

    def __init__(self, sel, arms, default):
        self.sel = sel
        self.arms = arms  # list of (values, body)
        self.default = default  # list or None


class SBreak(S):
    __slots__ = ()


class SContinue(S):
    __slots__ = ()


class SExit(S):
    __slots__ = ('x',)

    def __init__(self, x=None):
        self.x = x


class SFrameRestore(S):
    """SP := fp_ + framesize (omitted when the function has no frame)"""
    __slots__ = ('fs',)

    def __init__(self, fs):
        self.fs = fs


class SComment(S):
    __slots__ = ('text',)

    def __init__(self, text):
        self.text = text


# ------------------------------------------------------------ helpers
def c(v):
    return XC(v, 'I')


def is_const(x):
    return isinstance(x, XC)


def is_simple(x):
    """cheap & side-effect free to duplicate"""
    if isinstance(x, (XC, XV)):
        return True
    if isinstance(x, XB) and x.op in ('+', '-') and isinstance(x.a, XV) and isinstance(x.b, XC):
        return True
    return False


def split_off(x):
    """x -> (base, const offset)"""
    if isinstance(x, XC) and x.t == 'I':
        return None, x.v
    if isinstance(x, XB) and x.t == 'I' and isinstance(x.b, XC):
        if x.op == '+':
            b, o = split_off(x.a)
            return b, o + x.b.v
        if x.op == '-':
            b, o = split_off(x.a)
            return b, o - x.b.v
    return x, 0


def add(a, b):
    """address / integer add with constant folding (no overflow semantics)"""
    if isinstance(b, XC) and not isinstance(a, XC):
        base, off = split_off(a)
        off += b.v
        if base is None:
            return c(off)
        if off == 0:
            return base
        if off < 0:
            return XB('-', base, c(-off), 'I')
        return XB('+', base, c(off), 'I')
    if isinstance(a, XC) and isinstance(b, XC):
        return c(a.v + b.v)
    if isinstance(a, XC):
        return add(b, a)
    return XB('+', a, b, 'I')


def addc(a, k):
    return add(a, c(k))


def mul(a, k):
    if k == 1:
        return a
    if isinstance(a, XC):
        return c(a.v * k)
    if k == 0:
        return c(0)
    return XB('*', a, c(k), 'I')


def has_call(x):
    if isinstance(x, XCall):
        return not x.pure or any(has_call(a) for a in x.args)
    if isinstance(x, XB):
        return has_call(x.a) or has_call(x.b)
    if isinstance(x, (XU, XBig)):
        return has_call(x.a)
    if isinstance(x, XLoad):
        return has_call(x.addr)
    if isinstance(x, XTab):
        return has_call(x.idx)
    return False


def eager_safe(x):
    """can be evaluated even when it would not be evaluated in C (no side effects, no traps)"""
    if isinstance(x, (XC, XV)):
        return True
    if isinstance(x, XCall):
        return x.pure and all(eager_safe(a) for a in x.args)
    if isinstance(x, XB):
        if x.op in ('div', 'mod') and not (isinstance(x.b, XC) and x.b.v != 0):
            return False
        return eager_safe(x.a) and eager_safe(x.b)
    if isinstance(x, (XU, XBig)):
        return eager_safe(x.a)
    if isinstance(x, XLoad):
        return eager_safe(x.addr)
    if isinstance(x, XTab):
        return x.tab == 'SX8' and isinstance(x.idx, XB) and isinstance(x.idx.a, XLoad)
    return False


def rng(x):
    """value range (lo, hi) or None"""
    if isinstance(x, XC):
        if x.t in ('I', 'B'):
            return (x.v, x.v)
        return None
    if isinstance(x, XLoad):
        return {'u8': (0, 255), 's8': (-128, 127), 'u16': (0, 65535), 's16': (-32768, 32767)}.get(x.kind)
    if isinstance(x, XTab):
        if x.tab == 'SX8':
            return (-128, 127)
        return None
    if isinstance(x, XB) and x.t in ('I', 'B'):
        ra = rng(x.a)
        rb = rng(x.b)
        if x.op == 'mod' and rb and rb[0] == rb[1] and rb[0] > 0:
            m = rb[0]
            if ra and ra[0] >= 0:
                return (0, min(m - 1, ra[1]))
            return (-(m - 1), m - 1)
        if ra is None or rb is None:
            return None
        if x.op == '+':
            return (ra[0] + rb[0], ra[1] + rb[1])
        if x.op == '-':
            return (ra[0] - rb[1], ra[1] - rb[0])
        if x.op == '*':
            ps = [ra[0] * rb[0], ra[0] * rb[1], ra[1] * rb[0], ra[1] * rb[1]]
            return (min(ps), max(ps))
        if x.op == 'div' and rb[0] == rb[1] and rb[0] > 0:
            return (int(ra[0] / rb[0]), int(ra[1] / rb[0]))
    return None


def nonneg(x):
    r = rng(x)
    return r is not None and r[0] >= 0


def in_range(x, lo, hi):
    r = rng(x)
    return r is not None and r[0] >= lo and r[1] <= hi
