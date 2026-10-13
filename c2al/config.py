# Translation settings: everything that used to be hard coded for DOOM
import re


class Config:
    """
    entry_points      C functions that become public AL procedures (roots of the reachability scan)
    intrinsics        C function name -> AL runtime procedure that replaces it (memset -> Rt_MemSet)
    native_prefixes   bodiless C functions with these prefixes are implemented by hand in the AL runtime
    runtime_text      AL runtime template (see runtime/core.al); its identifiers are reserved
    reserve_exclude   identifiers in the runtime starting with these prefixes are not reserved
    reserve_all_words True: reserve every identifier in the runtime text (DOOM's original behaviour),
                      False: only the runtime's global variables and procedure names
    wrap_sites        {(function, line offset)}: signed + - * that must wrap like unsigned (see docs/arithmetic.md)
    wrap_all_signed   wrap every signed + - * (always correct, slower)
    error_tag         prefix of runtime error messages in the generated AL
    """

    def __init__(self, entry_points, runtime_text='', intrinsics=None, native_prefixes=('c2al_',),
                 reserve_exclude=None, reserve_all_words=False, wrap_sites=(), wrap_all_signed=False,
                 error_tag='C2AL'):
        self.entry_points = list(entry_points)
        self.runtime_text = runtime_text
        self.intrinsics = dict(DEFAULT_INTRINSICS if intrinsics is None else intrinsics)
        self.native_prefixes = tuple(native_prefixes)
        self.reserve_exclude = tuple(self.native_prefixes if reserve_exclude is None else reserve_exclude)
        self.reserve_all_words = reserve_all_words
        self.wrap_sites = {tuple(x) for x in wrap_sites}
        self.wrap_all_signed = wrap_all_signed
        self.error_tag = error_tag

    def is_native(self, name):
        return name.startswith(self.native_prefixes)

    def runtime_words(self):
        """identifiers used by the runtime, lower case (generated names must not collide with them)"""
        if self.reserve_all_words:
            words = re.findall(r'[A-Za-z_][A-Za-z0-9_]*', self.runtime_text)
        else:
            # the variable declarations at the top of the template, and every procedure name
            head = re.split(r'^\s*(?:local\s+)?procedure', self.runtime_text, maxsplit=1, flags=re.M)[0]
            words = re.findall(r'^\s*([A-Za-z_][A-Za-z0-9_]*)\s*:', head, flags=re.M)
            words += re.findall(r'procedure\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(', self.runtime_text)
        return {w.lower() for w in words if not w.startswith(self.reserve_exclude)}

    def runtime_procedures(self):
        return {m.lower() for m in re.findall(r'procedure\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(', self.runtime_text)}


# C library functions the generic runtime implements directly on the Mem list
DEFAULT_INTRINSICS = {
    'memset': 'Rt_MemSet',
    'memcpy': 'Rt_MemCpy',
    'memmove': 'Rt_MemCpy',
    'strlen': 'Rt_StrLen',
}
