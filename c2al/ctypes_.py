# C type model (ILP32: int/long/pointers are 4 bytes)


class CType:
    def is_int(self): return False
    def is_float(self): return False
    def is_ptr(self): return False
    def is_arr(self): return False
    def is_struct(self): return False
    def is_func(self): return False
    def is_void(self): return False
    def is_arith(self): return self.is_int() or self.is_float()
    def is_scalar(self): return self.is_int() or self.is_float() or self.is_ptr()

    def alk(self):
        """AL value kind: I=Integer, B=BigInteger, D=Decimal, None=aggregate"""
        if self.is_int():
            return 'B' if self.size() == 8 else 'I'
        if self.is_ptr():
            return 'I'
        if self.is_float():
            return 'D'
        return None


class TVoid(CType):
    def is_void(self): return True
    def size(self): return 1
    def align(self): return 1
    def __repr__(self): return 'void'


class TInt(CType):
    def __init__(self, name, sz, signed):
        self.name = name
        self.sz = sz
        self.signed = signed

    def is_int(self): return True
    def size(self): return self.sz
    def align(self): return min(self.sz, 4)
    def __repr__(self): return self.name

    def bits(self): return self.sz * 8

    def minmax(self):
        b = self.sz * 8
        if self.signed:
            return -(1 << (b - 1)), (1 << (b - 1)) - 1
        return 0, (1 << b) - 1


class TFloat(CType):
    def __init__(self, name, sz):
        self.name = name
        self.sz = sz

    def is_float(self): return True
    def size(self): return self.sz
    def align(self): return 4
    def __repr__(self): return self.name


class TPtr(CType):
    def __init__(self, to):
        self.to = to

    def is_ptr(self): return True
    def size(self): return 4
    def align(self): return 4
    def __repr__(self): return '%r*' % (self.to,)


class TArr(CType):
    def __init__(self, elem, n):
        self.elem = elem
        self.n = n

    def is_arr(self): return True
    def size(self): return self.elem.size() * (self.n or 0)
    def align(self): return self.elem.align()
    def __repr__(self): return '%r[%s]' % (self.elem, self.n)


class Field:
    def __init__(self, name, type, offset):
        self.name = name
        self.type = type
        self.offset = offset


class TStruct(CType):
    def __init__(self, tag, union):
        self.tag = tag
        self.union = union
        self.fields = []
        self.sz = 0
        self.al = 1
        self.complete = False

    def is_struct(self): return True
    def size(self):
        if not self.complete:
            raise Exception('size of incomplete struct %s' % self.tag)
        return self.sz

    def align(self): return self.al
    def __repr__(self): return '%s %s' % ('union' if self.union else 'struct', self.tag)

    def layout(self, members):
        off = 0
        al = 1
        for name, t in members:
            a = t.align()
            al = max(al, a)
            if self.union:
                self.fields.append(Field(name, t, 0))
                off = max(off, t.size())
            else:
                off = (off + a - 1) // a * a
                self.fields.append(Field(name, t, off))
                off += t.size()
        self.sz = (off + al - 1) // al * al
        self.al = al
        self.complete = True

    def field(self, name):
        for f in self.fields:
            if f.name == name:
                return f.type, f.offset
            if f.name is None and f.type.is_struct():
                r = f.type.field(name)
                if r:
                    return r[0], r[1] + f.offset
        return None


class TFunc(CType):
    def __init__(self, ret, params, varargs):
        self.ret = ret
        self.params = params
        self.varargs = varargs

    def is_func(self): return True
    def size(self): return 1
    def align(self): return 1
    def __repr__(self): return 'fn(%s)->%r' % (','.join(map(repr, self.params)), self.ret)


VOID = TVoid()
CHAR = TInt('char', 1, True)
SCHAR = TInt('signed char', 1, True)
UCHAR = TInt('unsigned char', 1, False)
SHORT = TInt('short', 2, True)
USHORT = TInt('unsigned short', 2, False)
INT = TInt('int', 4, True)
UINT = TInt('unsigned int', 4, False)
LONG = TInt('long', 4, True)
ULONG = TInt('unsigned long', 4, False)
LLONG = TInt('long long', 8, True)
ULLONG = TInt('unsigned long long', 8, False)
BOOL = TInt('_Bool', 1, False)
FLOAT = TFloat('float', 4)
DOUBLE = TFloat('double', 8)


def int_from_names(names):
    n = [x for x in names if x not in ('const', 'volatile', 'register')]
    s = ' '.join(sorted(n))
    signed = 'unsigned' not in n
    if 'char' in n:
        if 'unsigned' in n:
            return UCHAR
        if 'signed' in n:
            return SCHAR
        return CHAR
    if 'short' in n:
        return SHORT if signed else USHORT
    if n.count('long') >= 2:
        return LLONG if signed else ULLONG
    if 'long' in n and 'double' in n:
        return DOUBLE
    if 'long' in n:
        return LONG if signed else ULONG
    if 'int' in n or 'signed' in n or 'unsigned' in n:
        return INT if signed else UINT
    if '_Bool' in n:
        return BOOL
    if 'float' in n:
        return FLOAT
    if 'double' in n:
        return DOUBLE
    if 'void' in n:
        return VOID
    return None


def promote(t):
    """integer promotion"""
    if t.is_int() and t.size() < 4:
        return INT
    return t


def arith_conv(a, b):
    """usual arithmetic conversions"""
    if a.is_float() or b.is_float():
        return DOUBLE
    a = promote(a)
    b = promote(b)
    if a.size() == 8 or b.size() == 8:
        if (a.size() == 8 and not a.signed) or (b.size() == 8 and not b.signed):
            return ULLONG
        return LLONG
    if not a.signed or not b.signed:
        return UINT
    return INT


def wrap_to(t, v):
    """wrap a python int to the range of integer type t"""
    b = t.size() * 8
    v &= (1 << b) - 1
    if t.signed and v >= (1 << (b - 1)):
        v -= 1 << b
    return v
