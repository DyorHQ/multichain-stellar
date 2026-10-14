#!/usr/bin/env python3
"""Writes ios/DyorKit/Sources/DyorKit/Services/LookAlikeLetters.swift: the letters of other scripts that Unicode's
confusables data (UTS #39, confusables.txt) says are drawn like one ASCII letter or digit, for WalletHoldings.visible and
SymbolSafety's look-alike rules.

The data is the confusables table the system's ICU compiles in, read through its spoof checker (uspoof_getSkeleton), so
nothing is fetched: the version comes from the ICU the Mac ships (its U_UNICODE_VERSION is printed into the file). Kept:
  - every letter (general category L*) or decimal digit (Nd) of every script but Latin, in planes 0-3: a skeleton of one
    ASCII letter or digit, followed by nothing but combining marks (Cherokee NA, U+13BE, is an O with a stroke laid over
    it; WalletHoldings.visible drops marks, so it reads as that letter). Cyrillic, Greek, Armenian, Cherokee and Lisu,
    and also Myanmar ဝ, Hebrew ס, Arabic ه, Tifinagh ⵔ, Ethiopic ዐ, Canadian syllabics ᑌ and the rest. A code point whose
    compatibility form (NFKC) is already one ASCII letter or digit (full-width and mathematical letters) is left out:
    WalletHoldings.visible folds those itself. A digit is read as its look-alike only where WalletHoldings compares
    whole symbols and names ("M०N" is MON); where it finds one inside other text, a digit is its value, no letter
    ("MON०" holds MON with a digit after it);
  - the Latin letters (L*) of the IPA, phonetic, small-capital and other extension blocks, and the Latin-1, Extended-A
    and Extended-B letters: a skeleton of exactly one ASCII letter or digit and nothing else, so an accented letter (é, whose
    skeleton is e and a combining acute) is never in the table: accents are Latin letters' own, and are folded where a
    reading needs it.
A skeleton that is the letter itself (Greek μ, π, Ω) is not a look-alike.

A second table, `marked`, holds the Latin letters whose skeleton is one ASCII letter or digit with marks laid over it or
hung from it (a stroke, bar or hook: Ø, Đ, Ł, Ħ, Ɵ, Ʉ) and whose canonical decomposition, if any, doesn't start with that
ASCII letter: the diacritic folding WalletHoldings.visible does leaves these alone (é decomposes to e and an acute, and
is folded; Ø has no decomposition). They stay Latin letters (SymbolSafety doesn't consult this table: ÐOGE and ØRE are
fine symbols), and only the look-alike readings read them as the ASCII letter. An uppercase letter whose skeleton is
"l" (Ɨ) reads as "I", as the letter it is drawn from.

Run it again after a macOS update and commit what changes:

  python3 scripts/dev/lookalike-letters.py > ios/DyorKit/Sources/DyorKit/Services/LookAlikeLetters.swift"""
import ctypes, re, subprocess, sys, unicodedata

icu = ctypes.CDLL("/usr/lib/libicucore.dylib")
icu.uspoof_open.restype = ctypes.c_void_p
icu.uspoof_open.argtypes = [ctypes.POINTER(ctypes.c_int)]
icu.uspoof_getSkeleton.restype = ctypes.c_int32
icu.uspoof_getSkeleton.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.POINTER(ctypes.c_uint16), ctypes.c_int32,
                                   ctypes.POINTER(ctypes.c_uint16), ctypes.c_int32, ctypes.POINTER(ctypes.c_int)]
icu.u_charType.restype = ctypes.c_int8
icu.u_charType.argtypes = [ctypes.c_int32]
icu.u_getUnicodeVersion.restype = None
icu.u_getUnicodeVersion.argtypes = [ctypes.POINTER(ctypes.c_uint8)]
icu.u_getVersion.restype = None
icu.u_getVersion.argtypes = [ctypes.POINTER(ctypes.c_uint8)]

icu.ublock_getCode.restype = ctypes.c_int
icu.ublock_getCode.argtypes = [ctypes.c_int32]
icu.u_getPropertyValueName.restype = ctypes.c_char_p
icu.u_getPropertyValueName.argtypes = [ctypes.c_int, ctypes.c_int32, ctypes.c_int]
icu.unorm2_getNFKCInstance.restype = ctypes.c_void_p
icu.unorm2_getNFKCInstance.argtypes = [ctypes.POINTER(ctypes.c_int)]
icu.unorm2_normalize.restype = ctypes.c_int32
icu.unorm2_normalize.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_uint16), ctypes.c_int32, ctypes.POINTER(ctypes.c_uint16), ctypes.c_int32,
                                 ctypes.POINTER(ctypes.c_int)]
icu.unorm2_getNFDInstance.restype = ctypes.c_void_p
icu.unorm2_getNFDInstance.argtypes = [ctypes.POINTER(ctypes.c_int)]
icu.unorm2_getDecomposition.restype = ctypes.c_int32
icu.unorm2_getDecomposition.argtypes = [ctypes.c_void_p, ctypes.c_int32, ctypes.POINTER(ctypes.c_uint16), ctypes.c_int32,
                                        ctypes.POINTER(ctypes.c_int)]

status = ctypes.c_int(0)
checker = icu.uspoof_open(ctypes.byref(status))
if status.value > 0:
    sys.exit(f"uspoof_open failed: {status.value}")
nfd = icu.unorm2_getNFDInstance(ctypes.byref(status))
nfkc_instance = icu.unorm2_getNFKCInstance(ctypes.byref(status))
if status.value > 0:
    sys.exit(f"unorm2 instances failed: {status.value}")


def version(fn):
    out = (ctypes.c_uint8 * 4)()
    fn(out)
    parts = list(out)
    while len(parts) > 2 and parts[-1] == 0:
        parts.pop()
    return ".".join(map(str, parts))


def utf16(cp):
    return [cp] if cp < 0x10000 else [0xD800 + ((cp - 0x10000) >> 10), 0xDC00 + ((cp - 0x10000) & 0x3FF)]


def skeleton(cp):
    units = utf16(cp)
    source = (ctypes.c_uint16 * len(units))(*units)
    out = (ctypes.c_uint16 * 64)()
    st = ctypes.c_int(0)
    n = icu.uspoof_getSkeleton(checker, 0, source, len(units), out, 64, ctypes.byref(st))
    if st.value > 0:
        return None
    return bytes(bytearray(ctypes.string_at(out, 2 * n))).decode("utf-16-le")


# ICU's UCharCategory values for the letter categories (Lu, Ll, Lt, Lm, Lo), the marks (Mn, Me, Mc) and decimal
# digits (Nd).
LETTERS = {1, 2, 3, 4, 5}
MARKS = {6, 7, 8}
DIGIT = 9
# UCHAR_BLOCK and U_LONG_PROPERTY_NAME, for a block's name.
UCHAR_BLOCK, LONG_NAME = 0x1001, 1

LATIN = [
    ("Latin-1 Supplement", 0x00C0, 0x00FF), ("Latin Extended-A", 0x0100, 0x017F), ("Latin Extended-B", 0x0180, 0x024F),
    ("IPA Extensions", 0x0250, 0x02AF), ("Phonetic Extensions", 0x1D00, 0x1D7F), ("Phonetic Extensions Supplement", 0x1D80, 0x1DBF),
    ("Latin Extended Additional", 0x1E00, 0x1EFF), ("Latin Extended-C", 0x2C60, 0x2C7F), ("Latin Extended-D", 0xA720, 0xA7FF),
    ("Latin Extended-E", 0xAB30, 0xAB6F), ("Latin Extended-F", 0x10780, 0x107BF), ("Latin Extended-G", 0x1DF00, 0x1DFFF),
]


def ascii_alnum(ch):
    return len(ch) == 1 and ch.isascii() and ch.isalnum()


def nfkc(cp):
    units = utf16(cp)
    source = (ctypes.c_uint16 * len(units))(*units)
    out = (ctypes.c_uint16 * 64)()
    st = ctypes.c_int(0)
    n = icu.unorm2_normalize(nfkc_instance, source, len(units), out, 64, ctypes.byref(st))
    if st.value > 0:
        return None
    return bytes(bytearray(ctypes.string_at(out, 2 * n))).decode("utf-16-le")


def block(cp):
    name = icu.u_getPropertyValueName(UCHAR_BLOCK, icu.ublock_getCode(cp), LONG_NAME)
    return name.decode().replace("_", " ") if name else "Unnamed block"


def is_latin(cp):
    return cp < 0x80 or any(start <= cp <= end for _, start, end in LATIN)


def other_scripts():
    """Every letter or digit outside ASCII and the Latin blocks that `target` keeps, grouped by block in code point order."""
    out = []
    for cp in range(0x80, 0x40000):
        if 0xD800 <= cp <= 0xDFFF or is_latin(cp) or (icu.u_charType(cp) not in LETTERS and icu.u_charType(cp) != DIGIT):
            continue
        t = target(cp, False)
        if not t or ascii_alnum(nfkc(cp) or ""):
            continue
        name = block(cp)
        if out and out[-1][0] == name:
            out[-1][1].append((cp, t))
        else:
            out.append((name, [(cp, t)]))
    return out


def target(cp, latin):
    if icu.u_charType(cp) not in LETTERS and (latin or icu.u_charType(cp) != DIGIT):
        return None
    s = skeleton(cp)
    if not s or s == chr(cp):
        return None
    if latin:
        return s if ascii_alnum(s) else None
    if not ascii_alnum(s[0]):
        return None
    return s[0] if all(icu.u_charType(ord(c)) in MARKS for c in s[1:]) else None


def decomposition(cp):
    """The canonical decomposition of `cp` (ICU's NFD data), or "" when it has none."""
    out = (ctypes.c_uint16 * 32)()
    st = ctypes.c_int(0)
    n = icu.unorm2_getDecomposition(nfd, cp, out, 32, ctypes.byref(st))
    if n < 0 or st.value > 0:
        return ""
    return bytes(bytearray(ctypes.string_at(out, 2 * n))).decode("utf-16-le")


UPPERCASE = 1


def marked(cp):
    """The ASCII letter or digit a Latin letter with a stroke, bar or hook is drawn from, or None (see `marked` above)."""
    if icu.u_charType(cp) not in LETTERS:
        return None
    s = skeleton(cp)
    if not s or len(s) < 2 or not ascii_alnum(s[0]) or not all(icu.u_charType(ord(c)) in MARKS for c in s[1:]):
        return None
    base = decomposition(cp)[:1]
    if base and base.isascii():
        return None
    return "I" if s[0] == "l" and icu.u_charType(cp) == UPPERCASE else s[0]


def marked_rows(blocks):
    out = []
    for name, start, end in blocks:
        found = [(cp, marked(cp)) for cp in range(start, end + 1)]
        found = [(cp, t) for cp, t in found if t]
        if found:
            out.append((name, found))
    return out


def rows(blocks, latin):
    out = []
    for name, start, end in blocks:
        found = [(cp, target(cp, latin)) for cp in range(start, end + 1)]
        found = [(cp, t) for cp, t in found if t]
        if found:
            out.append((name, found))
    return out


def swift(ch):
    return '"\\\\"' if ch == "\\" else f'"{ch}"'


def emit(sections):
    lines = []
    for name, found in sections:
        lines.append(f"        // {name}.")
        entries = [f"(0x{cp:04X}, {swift(t)})" for cp, t in found]
        line = "        "
        for entry in entries:
            if len(line) + len(entry) + 2 > 120:
                lines.append(line.rstrip())
                line = "        "
            line += entry + ", "
        lines.append(line.rstrip())
    return "\n".join(lines)


others, latin, strokes = other_scripts(), rows(LATIN, True), marked_rows(LATIN)
count = sum(len(f) for _, f in others + latin)
marked_count = sum(len(f) for _, f in strokes)
print(f"""// Generated by scripts/dev/lookalike-letters.py: do not edit by hand.
// Source: Unicode confusables.txt (UTS #39), Unicode {version(icu.u_getUnicodeVersion)}, as compiled into ICU {version(icu.u_getVersion)} (macOS libicucore).

/// The letters of other scripts drawn like one ASCII letter or digit, by Unicode's confusables data (UTS #39): each
/// letter or digit of every script but Latin whose skeleton is one ASCII letter or digit (with only combining marks after
/// it) — Cyrillic, Greek, Coptic, Armenian, Cherokee, Lisu, Hebrew, Arabic, Myanmar, Tifinagh, Ethiopic, Canadian
/// syllabics and more; full-width and mathematical letters, which compatibility folding already makes ASCII, left out —
/// and each Latin letter outside ASCII whose skeleton is exactly one (dotless ı, small capital ᴏ, script ɡ; never an
/// accented letter). {count} in all. `WalletHoldings.visible` reads each as that letter, a digit (a Devanagari ०, an
/// Arabic-Indic ٥) only where whole symbols and names are compared: where one is found inside other text, a digit is
/// read as its value, which is no letter (`WalletHoldings.Digits`). `SymbolSafety` counts a letter from outside the
/// everyday Latin letters as a letter that can pass for a Latin one.
enum LookAlikeLetters {{
    static let confusables: [(UInt32, Character)] = [
{emit(others)}
{emit(latin)}
    ]

    /// The Latin letters drawn as one ASCII letter or digit with a stroke, bar or hook (Ø, Đ, Ł, Ħ, Ɵ, Ʉ), whose
    /// decomposition, if any, doesn't start with that letter, so folding accents leaves them as they are: {marked_count} in
    /// all. They are Latin letters for display safety (`SymbolSafety` doesn't read this table), and
    /// `WalletHoldings.visible` reads each as that letter, so "MØN" and "USĐC" read as MON and USDC.
    static let marked: [(UInt32, Character)] = [
{emit(strokes)}
    ]
}}""")
