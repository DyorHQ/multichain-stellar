#!/usr/bin/env python3
"""Checks that the App Store build is still build 23: the internal (Stellar) work changes nothing it compiles.

From ios/, with Python's isolated mode:
    python3 -I Internal/check-build23.py --base d387a64                # the commits since build 23 (base..HEAD)
    python3 -I Internal/check-build23.py --base d387a64 --worktree     # the working tree, untracked files included
    python3 -I Internal/check-build23.py --base d387a64 --app <App Store build>/Release-iphonesimulator/DyorHQ.app

It diffs the whole repository against the base and checks every changed path:
    ios/DyorKit/**                          never changes (Package.resolved included)
    ios/Internal/**                         anything: the internal project only
    added ios/DyorHQ/Lite/**.swift          wholly inside #if STELLAR_LITE: outside it, blank lines and // comments only
    modified ios/DyorHQ/**.swift            with its #if STELLAR_LITE blocks stripped, byte for byte the base's file
    any other added .swift                  fails, as does a deleted or renamed app file (ios/DyorHQ/**)
    ios/project.yml, ios/DyorHQ/Info.plist  only the CFBundleVersion line
    ios/.gitignore                          only added project-internal.json and DerivedData* lines (and comments)
    anything else                           listed in Internal/unflagged-changes.txt with a reason, and within its rule
Stripping keeps a stack of #if frames: `#if STELLAR_LITE` drops its lines, its `#else` keeps the rest, `#endif`
closes it and the three directive lines go. Every other #if is kept as written. `#elseif` in a STELLAR_LITE frame, and
any other condition naming STELLAR_LITE (`#if !STELLAR_LITE`, `#if STELLAR_LITE && DEBUG`), fail as unsupported.

--app also looks inside a built App Store app: no symbol of DyorLite, StellarKit, StellarCore or LiteClient in any of
its binaries (nm -U), no bundle or framework of theirs, no Lite or Stellar* string table and nothing else from
Internal/Resources.

Prints paths and line numbers, never a file's contents. Exits 0 when clean, 1 on any finding, 2 when it can't run.
"""
import argparse
import difflib
import json
import re
import shlex
import subprocess
import sys
from pathlib import Path

IOS = Path(__file__).resolve().parent.parent
UNFLAGGED = IOS / "Internal" / "unflagged-changes.txt"
# Symbols of the Lite packages, as they appear in nm's (mangled) names.
LITE_SYMBOL = re.compile(r"DyorLite|StellarCore|LiteClient|StellarKit")
# A bundle, framework or library of a Lite package (SwiftPM names resource bundles <Package>_<Target>.bundle).
LITE_PRODUCT = re.compile(r"(DyorLite|StellarKit|StellarCore|LiteClient)[._]")
# The Lite string tables, as catalogs or compiled into an .lproj.
LITE_TABLE = re.compile(r"(Lite|Stellar.*)\.(xcstrings|strings|stringsdict)")
DIRECTIVE = re.compile(r"\s*#(if|elseif|else|endif)\b(.*)")
MACH_O = {b"\xfe\xed\xfa\xce", b"\xfe\xed\xfa\xcf", b"\xce\xfa\xed\xfe", b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe",
          b"\xbe\xba\xfe\xca"}

findings = []


def fail(where, message):
    findings.append(f"{where}: {message}")


def stop(message):
    print(f"check-build23: {message}", file=sys.stderr)
    sys.exit(2)


def git(*args):
    result = subprocess.run(["git", *args], cwd=IOS, capture_output=True)
    if result.returncode:
        reason = result.stderr.decode(errors="replace").strip().splitlines()
        stop(f"git {args[0]} failed: {reason[-1] if reason else result.returncode}")
    return result.stdout


ROOT = Path(git("rev-parse", "--show-toplevel").decode().strip())


# Stripping

class Unsupported(Exception):
    def __init__(self, line, message):
        super().__init__(message)
        self.line = line


def strip(text):
    """The lines of `text` the App Store build compiles, with their line numbers in `text`: every #if STELLAR_LITE
    block's lines dropped and its #else kept, the other #if blocks as written."""
    kept, numbers = [], []
    frames = []  # [is STELLAR_LITE, dropped, has had its #else, line of its #if]
    for number, line in enumerate(text.split("\n"), 1):
        directive = DIRECTIVE.match(line)
        if directive:
            word, condition = directive.group(1), directive.group(2).split("//")[0].strip()
            names_lite = re.search(r"\bSTELLAR_LITE\b", condition) is not None
            if word in ("if", "elseif") and names_lite and (word == "elseif" or condition != "STELLAR_LITE"):
                raise Unsupported(number, f"#{word} {condition}: only `#if STELLAR_LITE` (and its #else) is supported")
            if word != "if" and not frames:
                raise Unsupported(number, f"#{word} without an #if")
            if word == "if":
                frames.append([condition == "STELLAR_LITE", condition == "STELLAR_LITE", False, number])
                if frames[-1][0]:
                    continue
            elif frames[-1][0]:
                if word == "elseif":
                    raise Unsupported(number, "#elseif in a #if STELLAR_LITE block is unsupported")
                if word == "endif":
                    frames.pop()
                elif frames[-1][2]:
                    raise Unsupported(number, "a second #else in a #if STELLAR_LITE block")
                else:
                    frames[-1][1:3] = [False, True]
                continue
            elif word == "endif":
                frames.pop()
                if any(frame[1] for frame in frames):
                    continue
        if not any(frame[1] for frame in frames):
            kept.append(line)
            numbers.append(number)
    if frames:
        raise Unsupported(frames[-1][3], "#if without an #endif")
    return kept, numbers


def first_difference(ours, theirs):
    """The index of the first line where two lists of lines differ, or None when they are equal."""
    for index, (a, b) in enumerate(zip(ours, theirs)):
        if a != b:
            return index
    return None if len(ours) == len(theirs) else min(len(ours), len(theirs))


def stripped(path, new):
    """`new`'s stripped lines and their line numbers, or None after a finding."""
    try:
        return strip(new)
    except Unsupported as error:
        fail(f"{path}:{error.line}", str(error))
        return None


def line_of(numbers, index):
    """The line, in the file before stripping, of the stripped line at `index` (one past the end for a missing one)."""
    if index < len(numbers):
        return numbers[index]
    return numbers[-1] + 1 if numbers else 1


# The rules

def check_lite_file(path, new):
    result = stripped(path, new)
    if result is None:
        return
    for line, number in zip(*result):
        code = line.strip()
        if code and not code.startswith("//"):
            fail(f"{path}:{number}", "code outside #if STELLAR_LITE: a new file in Lite/ is wholly inside it")
            return


def check_app_swift(path, old, new):
    result = stripped(path, new)
    if result is None:
        return
    kept, numbers = result
    index = first_difference(kept, old.split("\n"))
    if index is not None:
        fail(f"{path}:{line_of(numbers, index)}",
             f"differs from build 23 outside #if STELLAR_LITE (base line {index + 1})")


def is_version_line(path, lines, index):
    if path == "ios/project.yml":
        return re.fullmatch(r'\s*CFBundleVersion:\s*"?\d+"?\s*', lines[index]) is not None
    return (index > 0 and re.fullmatch(r"\s*<key>CFBundleVersion</key>\s*", lines[index - 1]) is not None
            and re.fullmatch(r"\s*<string>\d+</string>\s*", lines[index]) is not None)


def check_version_only(path, old, new):
    old_lines, new_lines = old.split("\n"), new.split("\n")
    if len(old_lines) != len(new_lines):
        fail(f"{path}:{first_difference(new_lines, old_lines) + 1}", "only the CFBundleVersion line may change")
        return
    for index, (a, b) in enumerate(zip(old_lines, new_lines)):
        if a != b and not (is_version_line(path, old_lines, index) and is_version_line(path, new_lines, index)):
            fail(f"{path}:{index + 1}", "only the CFBundleVersion line may change")
            return


def check_gitignore(path, old, new):
    old_lines, new_lines = old.split("\n"), new.split("\n")
    matcher = difflib.SequenceMatcher(None, old_lines, new_lines, autojunk=False)
    for tag, _, _, start, end in matcher.get_opcodes():
        if tag == "equal":
            continue
        if tag != "insert":
            fail(f"{path}:{start + 1}", "changes or removes a line of build 23's")
            return
        for number in range(start, end):
            line = new_lines[number].strip()
            if line and not line.startswith("#") and line.lstrip("/") != "project-internal.json" \
                    and not line.lstrip("/").startswith("DerivedData"):
                fail(f"{path}:{number + 1}", "only project-internal.json and DerivedData* lines may be added")
                return


# unflagged-changes.txt

class Entry:
    """One listed change: `path rule [arguments…]` (shell quoting), then its reason on indented lines."""

    def __init__(self, number, words):
        self.number, self.path, self.rule, self.arguments = number, words[0], words[1], words[2:]
        self.reason = []

    def check(self, old, new):
        if self.rule == "any":
            return
        if old is None or new is None:
            fail(self.path, f"{'added' if old is None else 'deleted'}, but its entry in "
                            f"{UNFLAGGED.name} (line {self.number}) lists a change to the file")
            return
        if self.rule == "literal":
            self.check_literal(old, new)
        else:
            self.check_keys(old, new)

    def check_literal(self, old, new):
        """Only lines that swap the old text for the new one differ (a Swift file's after stripping)."""
        before, after = self.arguments
        if self.path.endswith(".swift"):
            result = stripped(self.path, new)
            if result is None:
                return
            lines, numbers = result
        else:
            lines = new.split("\n")
            numbers = list(range(1, len(lines) + 1))
        base = old.split("\n")
        if len(lines) != len(base):
            index = first_difference(lines, base)
            fail(f"{self.path}:{line_of(numbers, index)}",
                 f"differs from build 23 beyond its entry in {UNFLAGGED.name}")
            return
        for index, (a, b) in enumerate(zip(base, lines)):
            if a != b and (before not in a or a.replace(before, after) != b):
                fail(f"{self.path}:{numbers[index]}", f"differs from build 23 beyond its entry in {UNFLAGGED.name}")
                return

    def check_keys(self, old, new):
        """A String Catalog with exactly the listed keys removed and added; everything else equal, key by key."""
        try:
            base, catalog = json.loads(old), json.loads(new)
        except ValueError:
            fail(self.path, "not a JSON String Catalog")
            return
        removed = {key[1:] for key in self.arguments if key.startswith("-")}
        added = {key[1:] for key in self.arguments if key.startswith("+")}
        if {k: v for k, v in base.items() if k != "strings"} != {k: v for k, v in catalog.items() if k != "strings"}:
            fail(self.path, "differs from build 23 outside its strings")
            return
        base_strings, strings = base.get("strings") or {}, catalog.get("strings") or {}
        for key in sorted(removed):
            if key not in base_strings or key in strings:
                fail(self.path, f"a key that {UNFLAGGED.name} (line {self.number}) lists as removed isn't")
        for key in sorted(added):
            if key in base_strings or key not in strings:
                fail(f"{self.path}:{key_line(new, key)}",
                     f"a key that {UNFLAGGED.name} (line {self.number}) lists as added isn't")
        for key in sorted((set(base_strings) | set(strings)) - removed - added):
            if key not in strings:
                fail(self.path, f"a key is removed that {UNFLAGGED.name} doesn't list")
                return
            if base_strings.get(key) != strings[key]:
                change = "added" if key not in base_strings else "changed"
                fail(f"{self.path}:{key_line(new, key)}", f"a key is {change} that {UNFLAGGED.name} doesn't list")
                return


def key_line(text, key):
    """The line where a catalog's entry for `key` starts (0 when it can't be found)."""
    match = re.search(r"^\s*" + re.escape(json.dumps(key)) + r"\s*:", text, re.M)
    return text.count("\n", 0, match.start()) + 1 if match else 0


def read_unflagged():
    entries = {}
    if not UNFLAGGED.exists():
        return entries
    entry = None

    def bad(number, message):
        stop(f"{UNFLAGGED.relative_to(IOS)}:{number}: {message}")

    def close(entry):
        if entry and not entry.reason:
            bad(entry.number, "an entry needs a reason, on the indented lines after it")

    for number, line in enumerate(UNFLAGGED.read_text(encoding="utf-8").split("\n"), 1):
        if line[:1].isspace():
            if line.strip():
                if entry is None:
                    bad(number, "an indented line with no entry above it")
                entry.reason.append(line.strip())
            continue
        if not line or line.startswith("#"):
            close(entry)
            entry = None
            continue
        close(entry)
        try:
            words = shlex.split(line)
        except ValueError as error:
            bad(number, str(error))
        if len(words) < 2:
            bad(number, "an entry is `<path> <rule> [arguments…]`")
        entry = Entry(number, words)
        path, rule, arguments = entry.path, entry.rule, entry.arguments
        if path in entries:
            bad(number, f"{path} is listed twice")
        if path.startswith("ios/DyorKit/") or path.startswith("ios/Internal/"):
            bad(number, f"{path} can't be listed: ios/DyorKit never changes and ios/Internal always may")
        if rule == "any":
            if arguments:
                bad(number, "`any` takes no arguments")
            if path.startswith("ios/DyorHQ/") and path.endswith(".swift"):
                bad(number, "an app Swift file can't change in any way: list the change with `literal`")
        elif rule == "literal":
            if len(arguments) != 2 or not arguments[0] or arguments[0] == arguments[1]:
                bad(number, "`literal` takes the old text and the new one")
        elif rule == "keys":
            if not arguments or any(len(key) < 2 or key[0] not in "+-" for key in arguments):
                bad(number, "`keys` takes the removed keys as -\"key\" and the added ones as +\"key\"")
        else:
            bad(number, f"unknown rule {rule!r}: any, literal or keys")
        entries[path] = entry
    close(entry)
    return entries


# The diff

def changed_paths(base, worktree):
    """(status, path) for every path that differs from the base: A added, D deleted, M modified, T type changed."""
    args = ["diff", "--name-status", "--no-renames", "--no-ext-diff", "-z", base] + ([] if worktree else ["HEAD"])
    words = git(*args).decode().split("\0")
    changes = [(words[i][:1], words[i + 1]) for i in range(0, len(words) - 1, 2)]
    if worktree:
        untracked = git("ls-files", "--others", "--exclude-standard", "-z", "--full-name", ":/").decode().split("\0")
        changes += [("A", path) for path in untracked if path]
    return sorted(changes, key=lambda change: change[1])


class Blobs:
    """Files at a commit, read through one `git cat-file --batch` (a git process per file is slow)."""

    def __init__(self):
        self.process = None

    def read(self, rev, path):
        if self.process is None:
            self.process = subprocess.Popen(["git", "cat-file", "--batch"], cwd=IOS, stdin=subprocess.PIPE,
                                            stdout=subprocess.PIPE)
        self.process.stdin.write(f"{rev}:{path}\n".encode())
        self.process.stdin.flush()
        header = self.process.stdout.readline().split()
        if len(header) != 3 or header[1] != b"blob":
            stop(f"can't read {path} at {rev}")
        data = self.process.stdout.read(int(header[2]))
        self.process.stdout.read(1)  # the newline after each object
        return data


blobs = Blobs()


def contents(rev, path):
    """A file's text at `rev`, or in the working tree when `rev` is None (empty for a directory: a nested repository)."""
    if rev is None:
        file = ROOT / path
        data = b"" if file.is_dir() else file.read_bytes()
    else:
        data = blobs.read(rev, path)
    return data.decode("utf-8", errors="surrogateescape")


def check_path(status, path, base, worktree, unflagged):
    if path.startswith("ios/DyorKit/"):
        fail(path, "ios/DyorKit is build 23's and never changes")
        return
    if path.startswith("ios/Internal/"):
        return
    if status not in "ADMT":
        fail(path, f"git status {status!r}: resolve it first")
        return
    old = None if status == "A" else contents(base, path)
    new = None if status == "D" else contents(None if worktree else "HEAD", path)
    if path in unflagged:
        unflagged[path].check(old, new)
    elif status == "A" and path.startswith("ios/DyorHQ/Lite/") and path.endswith(".swift"):
        check_lite_file(path, new)
    elif status in "MT" and path.startswith("ios/DyorHQ/") and path.endswith(".swift"):
        check_app_swift(path, old, new)
    elif status == "A" and path.endswith(".swift"):
        fail(path, "a new Swift file outside ios/DyorHQ/Lite")
    elif status == "D" and path.startswith("ios/DyorHQ/"):
        fail(path, "a build-23 app file is deleted or renamed")
    elif status in "MT" and path in ("ios/project.yml", "ios/DyorHQ/Info.plist"):
        check_version_only(path, old, new)
    elif status in "MT" and path == "ios/.gitignore":
        check_gitignore(path, old, new)
    else:
        fail(path, f"{'added' if status == 'A' else 'deleted' if status == 'D' else 'changed'} outside the rules: "
                   f"list it in Internal/{UNFLAGGED.name} with a reason")


# The built app

def is_mach_o(path):
    with path.open("rb") as f:
        return f.read(4) in MACH_O


def check_app(app):
    if not (app / "Info.plist").is_file():
        stop(f"{app} is not an app bundle")
    internal = {name for path in (IOS / "Internal" / "Resources").iterdir() if not path.name.startswith(".")
                for name in resource_names(path.name)}
    for path in sorted(app.rglob("*")):
        where = f"{app.name}/{path.relative_to(app)}"
        if LITE_PRODUCT.match(path.name):
            fail(where, "a Lite package's bundle or binary")
        elif LITE_TABLE.fullmatch(path.name) or path.name in internal:
            fail(where, "a resource of the internal build")
        elif path.is_file() and not path.is_symlink() and is_mach_o(path):
            result = subprocess.run(["nm", "-U", str(path)], capture_output=True, text=True, errors="replace")
            if result.returncode:
                stop(f"nm -U failed on {where}")
            count = sum(1 for line in result.stdout.splitlines() if LITE_SYMBOL.search(line))
            if count:
                fail(where, f"{count} symbols of the Lite packages (nm -U)")


def resource_names(name):
    """The names a resource of Internal/Resources has in a built app: a catalog's tables, any other file as it is."""
    stem, _, extension = name.rpartition(".")
    return [f"{stem}.strings", f"{stem}.stringsdict"] if extension == "xcstrings" else [name]


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--base", required=True, help="build 23's commit, d387a64")
    ap.add_argument("--worktree", action="store_true", help="check the working tree, not the commits up to HEAD")
    ap.add_argument("--app", type=Path, help="an App Store build's DyorHQ.app (DyorHQ.xcodeproj, Release) to look in")
    args = ap.parse_args()

    found = subprocess.run(["git", "rev-parse", "--verify", "--quiet", f"{args.base}^{{commit}}"], cwd=IOS,
                           capture_output=True, text=True)
    if found.returncode:
        stop(f"no commit {args.base} in this repository")
    base = found.stdout.strip()
    unflagged = read_unflagged()
    changes = changed_paths(base, args.worktree)
    for status, path in changes:
        check_path(status, path, base, args.worktree, unflagged)
    if args.app:
        check_app(args.app.resolve())

    for finding in findings:
        print(f"check-build23: {finding}")
    against = "the working tree" if args.worktree else "HEAD"
    app = f", app {args.app.name}" if args.app else ""
    print(f"check-build23: {len(changes)} paths differ from {args.base} in {against}{app}: "
          f"{len(findings)} finding{'s' if len(findings) != 1 else ''}")
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
