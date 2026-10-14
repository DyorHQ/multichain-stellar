#!/usr/bin/env python3
"""PreToolUse guard for every tool call (wired in .claude/settings.json with the matcher ".*").

1. Keeps secret files out of Claude transcripts. Denies a call that would read, print, edit, copy, publish, send or
   open the CONTENTS of a secret file:
     .env and every .env* / *.env / *.env.* / .envrc / .dev.vars* name, Secrets*.xcconfig* (Secrets.xcconfig and its
     copies), *.p8, *.p12, *.pfx, *.pem, *.key, *.mobileprovision, *.provisionprofile, *.keystore, *.jks, *.kdbx (also
     renamed, e.g. deployer.key.txt), geth UTC--* keystores, ~/.ssh/id_*, foundry keystores, and credential stores
     (~/.aws/credentials, gh's hosts.yml, .npmrc, .netrc, .git-credentials, .pgpass, ~/.docker/config.json).
   Templates are allowed by exact name: .env.example / .sample / .template (also .env.<x>.example), .dev.vars.example,
   Secrets.example.xcconfig.
   Only inputs that reference files are checked: Read/Edit/Write/NotebookEdit paths, Grep's path and glob, the path
   fields and one-word values of other tools (file_path, path, url, …), and shell commands (Bash and any tool with a
   "command" field, e.g. an MCP terminal). Prose is not: the prompts, scripts and args of Agent, Workflow, SendMessage,
   Skill and the like (their agents' own tool calls are checked when they run).
   In a command, a word names a file after the shell's own quote and escape removal (.e''nv, \\.env, $'\\x2eenv'),
   after an --opt= / VAR= / @ prefix, and a glob that can name one (.en?, *.env, .e*) counts. Code (python -c, node -e,
   a heredoc script) names a file only in a string literal ('.env', "deploy.key", spliced '.e'+'nv'): a property access
   (t.key, process.env.X) is not a file, nor is a regex with a backslash before the dot (\\.env). Shell code (bash -c,
   eval, a heredoc or echo piped into sh) is checked as a command. Text is not a file argument: a heredoc fed to
   cat/tee/wc/jq or to git commit -F - (unless its unquoted body runs $( ) or `…`, checked as commands), echo/printf
   text, commit/tag -m and gh --title/--body text, grep/rg patterns, and # comments.
   Allowed shell forms that name a secret file: ls / stat / test / [ (metadata), find without -exec, git check-ignore /
   ls-files / status / rm --cached, chmod, the env-names helper, and `cp <…>.example.xcconfig <…>Secrets.xcconfig`, as
   long as their output (a secret file's name) is not piped into xargs, a loop, a shell or an interpreter or used in a
   $( ). Leading shell words (if, then, else, do, !, time, env, …) are skipped first, so `if [ -f .env ]; then cat
   .env; fi` is denied.
2. Denies searches that can print a secret file's lines: grep -r / -R, rg --hidden / --no-ignore / -u, ag, ack,
   git grep --no-index / --untracked, and find | xargs <reader> or find -exec <reader> without a name filter, over a
   directory that holds a secret file (tracked-file tools such as `git grep` and plain `rg` skip them), unless the
   command prints file names only (-l, -L, -c, -q) or its grep --include / rg -g globs cannot match a secret file
   (*.swift, *.{sol,md}); tar / zip of such a directory; and the Grep tool printing lines that match a secret-looking
   name (TREASURY_KEY, PRIVATE_KEY, …).
3. Denies bypassing the git leak guard in commands that run git: --no-verify (and its abbreviations --no-veri/-verif),
   `git commit -n`, core.hooksPath (git -c, --config-env, git config writes and aliases), HUSKY=0 and GIT_CONFIG_*
   assignments; also inside bash -c, eval, echo … | sh and interpreter code. Words in a commit message, echo text or a
   heredoc note are not commands.
4. Keeps agents from switching off their own guards: no Write/Edit, and no shell command but reading (cat, grep,
   git diff/log/add/commit, …, with no redirection into a guard file), of ~/.claude/ settings and hooks or of a
   project's .claude/settings*.json and .claude/hooks/ (the approval marker included). A heredoc note written to some
   other file may mention them.
5. Supabase MCP (it runs SQL as postgres): SQL that touches Vault secrets or credential columns is denied; SQL that
   writes, and migrations, deploys and project or branch changes, ask the user to confirm in the Claude UI (an agent
   cannot approve its own writes; a session without a user denies them).
A guard error denies the call (fail closed). Names-only view of an env file: scripts/dev/env-names.sh <file>.
Tests: tests/secret-guard.test.mjs.
"""
import fnmatch
import json
import os
import re
import sys
import time
import urllib.parse

HOME = os.path.expanduser("~")

# ---------- secret file names ----------
TEMPLATE = re.compile(
    r"^(\.env(\.[\w.-]+)?\.(example|sample|template)|[\w.-]+\.env\.(example|sample|template)"
    r"|\.dev\.vars\.(example|sample|template)|secrets\.example\.xcconfig)$", re.I)
# A backslash right before the dot (\.env, \.pem) is a regex escape in a quoted pattern, not a file name: the shell
# drops an unquoted one before a word is tested here.
SECRET_BASENAME = re.compile(
    r"""^(
        \.env.* | .*[^\\]\.env | .*[^\\]\.env\..* | \.dev\.vars.* | secrets(.*[^\\])?\.xcconfig.*
      | (.*[^\\])?\.(p8|p12|pfx|pem|key|mobileprovision|provisionprofile|keystore|jks|kdbx)
      | (.*[^\\])?\.(p8|p12|pem|key)\..* | id_(rsa|ed25519|ecdsa|dsa) | utc--.*
      | \.npmrc | \.netrc | \.git-credentials | \.pgpass
    )$""", re.X | re.I)
# The environment objects of JS runtimes (process.env.X, import.meta.env.X, Deno.env, Bun.env) are code, not files.
RUNTIME_ENV = re.compile(r"^(process|meta|deno|bun)\.env(\.[A-Za-z_$][\w$]*)*$", re.I)
SECRET_PATH = re.compile(r"(^|/)(\.foundry/keystores|\.ssh/id_|\.aws/credentials|\.config/gh/hosts\.yml"
                         r"|\.docker/config\.json|\.config/op/)")
# Names a glob in a command is tested against (dotfiles only match a glob that starts with ".").
SAMPLE_NAMES = [".env", ".env.local", ".env.production", ".envrc", ".dev.vars", "prod.env", "Secrets.xcconfig",
                "deploy.pem", "deploy.key", "AuthKey_X.p8", "cert.p12", "id_rsa", ".npmrc", ".netrc"]
# Names a search's include filter (grep --include, rg -g) is tested against: the samples and the credential stores.
FILTER_SAMPLES = SAMPLE_NAMES + ["config.json", "hosts.yml", "credentials", "keystore.json", "UTC--2024-01-01--0a"]


def is_secret_name(base):
    return bool(base) and not TEMPLATE.match(base) and not RUNTIME_ENV.match(base) and \
        bool(SECRET_BASENAME.match(base))


def is_secret_path(p):
    if not p or not isinstance(p, str):
        return False
    if p.startswith("file:"):
        p = urllib.parse.unquote(urllib.parse.urlparse(p).path)
    p = os.path.expanduser(p)
    return is_secret_name(os.path.basename(p.rstrip("/"))) or bool(SECRET_PATH.search(p))


def glob_can_name_secret(g):
    """A shell glob (with * ? or [) that could expand to a secret file name."""
    base = os.path.basename(g.rstrip("/"))
    if not re.search(r"[*?[]", base):
        return False
    literal = len(re.sub(r"\[[^]]*\]|[*?]", "", base))
    if literal < (1 if base.startswith(".") else 2):
        return False  # "*" or "*.*": too generic to mean a secret file
    for n in SAMPLE_NAMES:
        if n.startswith(".") and not base.startswith("."):
            continue
        if fnmatch.fnmatchcase(n.lower(), base.lower()):
            return True
    return False


def names_file(p):
    return is_secret_path(p) or glob_can_name_secret(p)


def base_of(p):
    return os.path.basename(p.rstrip("/")) or p


# A word that can be a path: no quotes, backslashes or code punctuation; spaces and a copy suffix " (1)" allowed.
PATHLIKE = re.compile(r"^[^'\"`;|&<>()=,!\\\n]*(\s?\(\d{1,3}\)[^'\"`;|&<>()=,!\\\n]*)?$")
PREFIX = re.compile(r"^(--?[\w-]+=|[A-Za-z_][A-Za-z0-9_]*=|@)")
SPLICE = re.compile(r"(['\"`])\s*\+\s*\1|(['\"])\2")  # 'a'+'b' and 'a''b' → 'ab'
LITERAL = re.compile(r"'([^']*)'|\"([^\"]*)\"|`([^`]*)`")


def code_names(text):
    """Secret file names in code: only its string literals count ('.env', "deploy.key", `${d}/.env`, spliced
    '.e'+'nv'), so a property access (t.key, process.env.X) or a regex (\\.env) is not a file."""
    hits = []
    for m in LITERAL.finditer(SPLICE.sub("", text)):
        lit = next(g for g in m.groups() if g is not None)
        for tok in [lit] + re.split(r"[\s<>=@;|&()\[\],]+", lit):
            if tok and PATHLIKE.match(tok) and names_file(tok):
                hits.append(base_of(tok))
    return hits


def word_names(w):
    """Secret file names one shell word (quotes and escapes already removed) can name."""
    v = w
    for _ in range(4):
        m = PREFIX.match(v)
        if not m or m.end() == len(v):
            break
        v = v[m.end():]
    if PATHLIKE.match(v):
        return [base_of(v)] if names_file(v) else []
    return code_names(w)


# ---------- shell commands: a small lexer ----------
class GuardError(Exception):
    pass


class Cmd:
    """One simple command: its words (quotes removed, $( ) as "$S"), redirections, heredocs, here-strings and parsed
    command substitutions."""

    def __init__(self, start=-1):
        self.start, self.end, self.raw = start, start, None
        self.words, self.redirs, self.subs, self.heredocs, self.herestrings = [], [], [], [], []


ANSI = {"a": "\a", "b": "\b", "e": "\x1b", "E": "\x1b", "f": "\f", "n": "\n", "r": "\r", "t": "\t", "v": "\v"}
REDIR_OPS = ("<<<", "<<-", "<<", "<>", "<&", "<", "&>>", "&>", ">>", ">|", ">&", ">")


class Lexer:
    """Enough of bash's quoting, escapes, $( ), backticks, heredocs and control operators to tell command words from
    data, and to split a command line into pipelines of simple commands."""

    def __init__(self, text, depth=0):
        if depth > 8:
            raise GuardError("commands nested too deeply")
        self.t, self.n, self.i, self.depth = text, len(text), 0, depth
        self.pending, self.cuts = [], []  # heredocs waiting for their body; (start, end) of the bodies cut out

    def run(self):
        pipes = self.parse()
        for h in self.pending:  # an operator with no newline after it: an empty, unterminated body
            h["open"] = True
        self.pending = []
        self.finish(pipes)
        return pipes

    def finish(self, pipes):
        for pipe in pipes:
            for c in pipe:
                if c.raw is None:
                    c.raw = self.text(c.start, c.end).strip()
                for sub, _, _ in c.subs:
                    self.finish(sub)

    def text(self, a, b):
        """The source from a to b with heredoc bodies cut out."""
        if a < 0:
            return ""
        out, pos = [], a
        for s, e in sorted(self.cuts):
            if e <= pos or s >= b:
                continue
            out.append(self.t[pos:s] if s > pos else "")
            pos = max(pos, e)
        if pos < b:
            out.append(self.t[pos:b])
        return "".join(out)

    def parse(self, closer=False, level=0):
        """Pipelines (lists of Cmd) up to the end of the text or, for $( ), up to its closing parenthesis."""
        if level > 16:
            raise GuardError("commands nested too deeply")
        t, n = self.t, self.n
        pipes, pipe = [], []
        cmd = Cmd()
        word, redir, parens = None, None, 0
        word_subs = []  # the substitutions inside the word being read

        def add(s):
            nonlocal word
            if cmd.start < 0:
                cmd.start = self.i
            word = (word or "") + s

        def end_word():
            nonlocal word, redir
            if word is not None:
                if redir == "<<<":
                    cmd.herestrings.append(word)
                kind, idx = "herestring", len(cmd.herestrings) - 1
                if redir and redir != "<<<":
                    cmd.redirs.append((redir, word))
                    kind, idx = "redir", len(cmd.redirs) - 1
                elif not redir:
                    cmd.words.append(word)
                    kind, idx = "word", len(cmd.words) - 1
                for sub in word_subs:  # where this word's $( ) output lands
                    cmd.subs.append((sub, kind, idx))
                redir = None
            word_subs.clear()
            word = None

        def end_cmd(at):
            nonlocal cmd, redir
            end_word()
            redir = None
            if cmd.start >= 0 and (cmd.words or cmd.redirs or cmd.heredocs or cmd.subs or cmd.herestrings):
                cmd.end = at
                pipe.append(cmd)
            cmd = Cmd()

        def end_pipe(at):
            nonlocal pipe
            end_cmd(at)
            if pipe:
                pipes.append(pipe)
            pipe = []

        while self.i < n:
            c = t[self.i]
            nx = t[self.i + 1] if self.i + 1 < n else ""
            if c in " \t\r":
                end_word()
                self.i += 1
            elif c == "\n":
                end_pipe(self.i)
                self.i += 1
                if self.pending:
                    self.read_bodies()
            elif c == "#" and word is None:
                j = t.find("\n", self.i)
                self.i = n if j < 0 else j
            elif c == "\\":
                if nx == "\n":
                    self.i += 2
                else:
                    add(nx)
                    self.i += 2
            elif c == "'":
                j = t.find("'", self.i + 1)
                j = n if j < 0 else j
                add(t[self.i + 1:j])
                self.i = j + 1
            elif c == "$" and nx == "'":
                add("")
                add(self.ansi_c())
            elif c == '"' or (c == "$" and nx == '"'):
                add("")
                self.i += 1 if c == '"' else 2
                s, subs = self.dquote(level)
                word_subs.extend(subs)
                add(s)
            elif c == "$" and nx == "(":
                add("")
                if t.startswith("$((", self.i):
                    self.i = self.arith_end(self.i + 3)
                    add("$A")
                else:
                    self.i += 2
                    word_subs.append(self.parse(True, level + 1))
                    add("$S")
            elif c == "`":
                add("")
                word_subs.append(self.backtick())
                add("$S")
            elif c in "<>" and nx == "(" and word is None:
                add("")
                self.i += 2
                word_subs.append(self.parse(True, level + 1))
                add("$S")
            elif c == ")":
                if closer and parens == 0:
                    end_pipe(self.i)
                    self.i += 1
                    return pipes
                parens = max(0, parens - 1)
                end_pipe(self.i)
                self.i += 1
            elif c == "(":
                parens += 1
                end_pipe(self.i)
                self.i += 1
            elif c == "&" and nx == "&" or c == "|" and nx == "|":
                end_pipe(self.i)
                self.i += 2
            elif c == "|":
                end_cmd(self.i)
                self.i += 2 if nx == "&" else 1
            elif c == ";":
                end_pipe(self.i)
                self.i += 1
                while self.i < n and t[self.i] in ";&":
                    self.i += 1
            elif c == "&" and nx != ">":
                end_pipe(self.i)
                self.i += 1
            elif c in "<>&":
                if word is not None and word.isdigit():
                    word = None  # a file descriptor number (2>, 3<)
                else:
                    end_word()
                if cmd.start < 0:
                    cmd.start = self.i
                op = next(o for o in REDIR_OPS if t.startswith(o, self.i))
                self.i += len(op)
                if op in ("<<", "<<-"):
                    delim, quoted = self.delimiter()
                    h = {"delim": delim, "quoted": quoted, "strip": op == "<<-", "body": "", "open": True}
                    cmd.heredocs.append(h)
                    self.pending.append(h)
                else:
                    redir = op
            else:
                add(c)
                self.i += 1
        end_pipe(self.i)
        return pipes

    def dquote(self, level):
        """A double-quoted string from self.i (after the quote) through its closing quote: (value, substitutions)."""
        t, n, out, subs = self.t, self.n, [], []
        while self.i < n:
            c = t[self.i]
            if c == '"':
                self.i += 1
                break
            if c == "\\" and self.i + 1 < n:
                d = t[self.i + 1]
                out.append("" if d == "\n" else d if d in '$`"\\' else "\\" + d)
                self.i += 2
            elif t.startswith("$((", self.i):
                self.i = self.arith_end(self.i + 3)
                out.append("$A")
            elif t.startswith("$(", self.i):
                self.i += 2
                subs.append(self.parse(True, level + 1))
                out.append("$S")
            elif c == "`":
                subs.append(self.backtick())
                out.append("$S")
            else:
                out.append(c)
                self.i += 1
        return "".join(out), subs

    def backtick(self):
        """A `…` substitution from self.i, parsed as its own command."""
        t, n = self.t, self.n
        j, out = self.i + 1, []
        while j < n and t[j] != "`":
            if t[j] == "\\" and j + 1 < n:
                out.append(t[j + 1] if t[j + 1] in "`$\\" else t[j:j + 2])
                j += 2
            else:
                out.append(t[j])
                j += 1
        self.i = min(n, j + 1)
        return Lexer("".join(out), self.depth + 1).run()

    def ansi_c(self):
        """A $'…' string from self.i, with bash's escapes decoded ($'\\x2eenv' is .env)."""
        t, n = self.t, self.n
        j, out = self.i + 2, []
        while j < n and t[j] != "'":
            if t[j] == "\\" and j + 1 < n:
                d = t[j + 1]
                j += 2
                m = None
                if d == "x":
                    m = re.match(r"[0-9A-Fa-f]{1,2}", t[j:j + 2])
                    out.append(chr(int(m.group(), 16)) if m else "\\x")
                elif d in "uU":
                    m = re.match(r"[0-9A-Fa-f]{1,%d}" % (4 if d == "u" else 8), t[j:])
                    out.append(chr(min(int(m.group(), 16), 0x10FFFF)) if m else "\\" + d)
                elif d in "01234567":
                    m = re.match(r"[0-7]{0,2}", t[j:])
                    out.append(chr(int(d + m.group(), 8) & 0xFF))
                elif d == "c" and j < n:
                    out.append(chr(ord(t[j]) & 0x1F))
                    j += 1
                else:
                    out.append(ANSI.get(d, d))
                if m:
                    j += len(m.group())
            else:
                out.append(t[j])
                j += 1
        self.i = min(n, j + 1)
        return "".join(out)

    def arith_end(self, j):
        """The index after the )) that closes a $(( … ))."""
        depth = 2
        while j < self.n and depth > 0:
            depth += {"(": 1, ")": -1}.get(self.t[j], 0)
            j += 1
        return j

    def delimiter(self):
        """The word after << (a heredoc delimiter): its value and whether any of it was quoted (no expansion)."""
        t, n = self.t, self.n
        while self.i < n and t[self.i] in " \t":
            self.i += 1
        out, quoted = [], False
        while self.i < n and t[self.i] not in " \t\r\n;&|<>()":
            c = t[self.i]
            if c in "'\"":
                j = t.find(c, self.i + 1)
                j = n if j < 0 else j
                out.append(t[self.i + 1:j])
                quoted, self.i = True, j + 1
            elif c == "\\" and self.i + 1 < n:
                out.append(t[self.i + 1])
                quoted, self.i = True, self.i + 2
            else:
                out.append(c)
                self.i += 1
        return "".join(out), quoted

    def read_bodies(self):
        """Reads the pending heredocs' bodies, which start at self.i (just after a newline), and cuts them out."""
        t, n = self.t, self.n
        for h in self.pending:
            start, lines = self.i, []
            while self.i < n:
                j = t.find("\n", self.i)
                line = t[self.i:n if j < 0 else j]
                key = line.lstrip("\t") if h["strip"] else line
                if key == h["delim"]:
                    self.i, h["open"] = (n if j < 0 else j + 1), False
                    break
                if h["delim"] and key.startswith(h["delim"]) and key[len(h["delim"]):].lstrip(" \t").startswith(")"):
                    # `EOF)` closing a $( ): the body ends here and the parenthesis is still to be read.
                    self.i, h["open"] = self.i + len(line) - len(key) + len(h["delim"]), False
                    break
                lines.append(line)
                self.i = n if j < 0 else j + 1
            h["body"] = "\n".join(lines)
            self.cuts.append((start, self.i))
        self.pending = []


def body_substitutions(body, depth):
    """The $( ) and `…` of an unquoted heredoc body (they run when the body is read), each parsed as a command."""
    subs, i = [], 0
    while True:
        m = re.compile(r"\$\((?!\()|`").search(body, i)
        if not m:
            return subs
        lx = Lexer(body, depth + 1)
        if m.group() == "`":
            lx.i = m.start()
            subs.append(lx.backtick())
        else:
            lx.i = m.end()
            sub = lx.parse(True, 1)
            lx.finish(sub)
            subs.append(sub)
        i = max(lx.i, m.end())


# ---------- shell commands: the checks ----------
LEADING = re.compile(r"^\s*(?:(?:then|else|elif|do|if|while|until|!|\{|\(|time|exec|command|builtin|nohup|sudo|"
                     r"env(?:\s+-\S+)*|[A-Za-z_][A-Za-z0-9_]*=\S*)\s+)+")
ASSIGN = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
KEYWORDS = {"then", "else", "elif", "do", "if", "while", "until", "!", "{", "}", "time", "done", "fi"}
WRAPPERS = {"exec", "command", "builtin", "nohup", "sudo", "doas", "env", "nice", "caffeinate", "stdbuf", "timeout",
            "gtimeout"}
LAUNCHERS = WRAPPERS | {"xargs", "parallel", "watch", "find", "fd", "time", "flock", "ionice", "taskpolicy", "arch",
                        "unbuffer", "script", "uv", "uvx", "npx", "pnpx", "bunx", "pipx", "poetry", "pixi", "mise",
                        "direnv", "op"}
SAFE_SEGMENT = [
    re.compile(r"^((ls|stat|test)\b|\[\[?\s)"),
    re.compile(r"^find\b(?!.*\s-(exec|execdir|ok|okdir|fprint\w*|fls)\b)"),
    re.compile(r"^git\s+(-C\s+\S+\s+)?(check-ignore|ls-files|status|rm\s+--cached)\b"),
    re.compile(r"^chmod\s+[0-7]{3,4}\b"),
    re.compile(r"^(\S*/)?env-names\.sh\b"),
    re.compile(r"^cp\s+(-\w+\s+)*\S*\.example\.xcconfig\s+\S*Secrets\.xcconfig\s*$"),
]
READERS = r"(cat|head|tail|less|more|grep|egrep|fgrep|rg|ag|ack|awk|sed|strings|xxd|od|hexdump|nl|sort|uniq|cut|tr|" \
          r"bat|jq|python3?|node|perl|ruby|base64|openssl|diff|cmp|wc|file)"
NAMES_ONLY = re.compile(r"(^|\s)(-[a-zA-Z]*[lLcq][a-zA-Z]*|--files-with(out)?-match(es)?|--count|--quiet|--silent|"
                        r"--files)\b")
SECRET_WORD = re.compile(r"(?i)(private[_-]?key|secret|mnemonic|seed[_-]?phrase|treasury|deployer|owner[_-]?key|"
                         r"api[_-]?key|_token|password|pepper|jwt|service[_-]?role)")
PRUNE = {".git", "node_modules", "DerivedData", "build", ".build", "Pods", "dist", ".next", "out", "cache", ".wrangler",
         "target", "vendor", ".venv", "venv", "__pycache__", ".xcarchive"}
SHELLS = {"sh", "bash", "zsh", "dash", "ksh", "mksh", "fish", "csh", "tcsh"}
INTERP = re.compile(r"^(python[\d.]*|pypy3?|node(js)?|deno|bun|perl[\d.]*|ruby[\d.]*|php[\d.]*|osascript|lua[\d.]*|"
                    r"Rscript|swift|tclsh|expect|pwsh|powershell)$")
# Commands whose stdin can become code or file names to open (the rest of a pipeline after an allowed ls / find).
STDIN_RUNNERS = SHELLS | {"xargs", "parallel", "while", "until", "read", "source", ".", "eval", "awk", "gawk", "mawk",
                          "nawk", "sed", "gsed", "psql", "sqlite3", "mysql", "ssh", "su", "tar", "cpio", "zip",
                          "rsync", "curl", "wget"}
# Commands that only print or count what they read: text piped into them stays text.
TEXT_FILTERS = {"wc", "head", "tail", "sort", "uniq", "cut", "tr", "grep", "egrep", "fgrep", "rg", "cat", "tee",
                "less", "more", "column", "fold", "fmt", "nl", "rev", "pbcopy", "jq"}
BYPASS_TEXT = re.compile(r"--no-veri(?:fy?)?(?![\w-])|(?i:core\.hookspath)|\bHUSKY=0\b|\bGIT_CONFIG_(?:PARAMETERS|COUNT)\b")
HOOKS_ENV = re.compile(r"^(HUSKY=0$|GIT_CONFIG_(PARAMETERS|COUNT)=)")
GIT_GLOBAL_VALUE = {"-C", "-c", "--git-dir", "--work-tree", "--namespace", "--config-env", "--super-prefix",
                    "--attr-source", "--list-cmds"}
GIT_MESSAGE_SUBS = {"commit", "tag", "merge", "stash", "notes"}
GIT_LOG_SUBS = {"log", "show", "shortlog", "whatchanged", "rev-list", "reflog"}
CONFIG_WRITES = {"--unset", "--unset-all", "--add", "--replace-all", "--remove-section", "--rename-section", "-e",
                 "--edit", "set", "unset", "rename-section", "remove-section", "edit"}
# Options that take the next word as their value (only when certain: a wrong entry would shift a file into the
# pattern's place). BSD grep's -C and --context take an optional, attached value, so they are not here.
GREP_VALUE = {
    "grep": ("efmABdD", {"--regexp", "--file", "--max-count", "--after-context", "--before-context", "--include",
                         "--exclude", "--exclude-dir", "--include-dir", "--exclude-from", "--label", "--binary-files",
                         "--directories", "--devices", "--group-separator"}),
    "rg": ("efgtTmABCjMErd", {"--regexp", "--file", "--glob", "--iglob", "--type", "--type-not", "--max-count",
                              "--after-context", "--before-context", "--context", "--threads", "--max-columns",
                              "--encoding", "--replace", "--max-depth", "--pre", "--pre-glob", "--sort", "--sortr",
                              "--type-add", "--type-clear", "--ignore-file", "--max-filesize", "--path-separator",
                              "--context-separator", "--colors", "--color", "--engine", "--dfa-size-limit",
                              "--regex-size-limit", "--field-context-separator", "--field-match-separator",
                              "--hyperlink-format", "--generate", "--hostname-bin"}),
    "git": ("efmABC", {"--regexp", "--file", "--max-count", "--after-context", "--before-context", "--context",
                       "--threads", "--max-depth"}),
}
GREP_VALUE["egrep"] = GREP_VALUE["fgrep"] = GREP_VALUE["grep"]
GH_TEXT = {"--title", "-t", "--body", "-b", "--notes"}
GUARD_READERS = re.compile(r"^(cat|head|tail|less|more|ls|stat|wc|diff|cmp|grep|egrep|fgrep|rg|file|shasum|sha256sum|"
                           r"md5|md5sum|jq|bat|test|\[\[?|realpath|readlink|dirname|basename|echo|printf)(?=\s|$)")
GUARD_RUNNER = re.compile(r"^(python3?|/usr/bin/python3)\s+(-m\s+py_compile\s+)?\S*secret-guard\.py(?=\s|$)")
GUARD_GITREAD = re.compile(r"^git\s+(-C\s+\S+\s+)?(add|diff|show|log|status|blame|ls-files|grep|cat-file|commit)"
                           r"(?=\s|$)")
WRITE_REDIRS = {">", ">>", ">|", "&>", "&>>", "<>", ">&"}
_holds = {}


def holds_secret(root):
    """True when a secret file is somewhere under root (bounded walk; the bound itself counts as True)."""
    root = os.path.abspath(os.path.expanduser(root))
    if root in _holds:
        return _holds[root]
    found, seen, t0 = False, 0, time.time()
    if os.path.isfile(root):
        found = is_secret_path(root)
    else:
        for d, dirs, files in os.walk(root):
            if any(is_secret_name(f) for f in files) or SECRET_PATH.search(d + "/"):
                found = True
                break
            dirs[:] = [x for x in dirs if x not in PRUNE and not x.endswith(".xcarchive")]
            seen += len(files) + len(dirs)
            if seen > 60000 or time.time() - t0 > 3:
                found = True  # too big to be sure: treat as holding one
                break
    _holds[root] = found
    return found


def strip_quoted(s):
    return re.sub(r"'[^']*'|\"(?:[^\"\\]|\\.)*\"", "''", s)


def operands(seg):
    """Non-option words after the command name (quotes removed)."""
    words = re.findall(r"'[^']*'|\"(?:[^\"\\]|\\.)*\"|\S+", seg)[1:]
    return [w.strip("'\"") for w in words if not w.startswith("-")]


def deny(reason):
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny",
                                             "permissionDecisionReason": "Blocked by the secret guard "
                                             "(.claude/hooks/secret-guard.py): " + reason}}))
    sys.exit(0)


def ask(reason):
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "ask",
                                             "permissionDecisionReason": reason}}))
    sys.exit(0)


SECRET_REASON = ("this would expose the contents of a secret file ({}) to the transcript. Use "
                 "`scripts/dev/env-names.sh <file>` for variable names and value lengths only, compare values inside "
                 "a script that prints booleans, or let the tool that needs the file read it itself (xcodebuild, "
                 "secret-scan.sh). To write .gitignore/gitleaks rules that mention these names, use the Write/Edit "
                 "tools on those config files.")
NAMES_FED_REASON = ("a secret file's name ({}) is piped or substituted into a command that can open it (xargs, a loop, "
                    "a shell, an interpreter, tar …). Keep metadata commands (ls, find, git ls-files) on their own.")
HOOKS_REASON = ("skipping or redirecting the git hooks (--no-verify, git commit -n, core.hooksPath, HUSKY=0, "
                "GIT_CONFIG_*) switches off the leak guard. Fix what the hook reports instead; a false positive goes "
                "in .leakguard.")
GUARD_REASON = ("changing Claude's settings or hooks (~/.claude, .claude/settings*.json, .claude/hooks/) is the owner's "
                "job, not an agent's; this includes creating an approval marker. Ask the user.")
GUARD_FILES = re.compile(r"(^|[^\w.])\.claude/(settings[^/]*\.json|hooks(/|$|[\s'\"]))|allow-supabase-writes")


def is_guard_path(p):
    return isinstance(p, str) and bool(GUARD_FILES.search(os.path.expanduser(p)))


def first_command(words):
    """Index of the command word: after leading assignments and shell keywords only (not sudo/env and their options,
    so a misread option can never turn `sudo -u echo cat .env` into echo text)."""
    k = 0
    while k < len(words) and (ASSIGN.match(words[k]) or words[k] in KEYWORDS):
        k += 1
    return k


def verb_of(c):
    k = first_command(c.words)
    return os.path.basename(c.words[k]) if k < len(c.words) else ""


def command_words(words):
    """The command and its arguments after keywords, assignments and wrappers (sudo, env, nice, timeout …)."""
    k = 0
    while k < len(words):
        w, b = words[k], os.path.basename(words[k])
        if ASSIGN.match(w) or w in KEYWORDS:
            k += 1
        elif b in WRAPPERS:
            k += 1
            while k < len(words) and words[k].startswith("-"):
                k += 2 if words[k] in ("-u", "-g", "-n", "-C", "-s", "-k") else 1
            if b in ("timeout", "gtimeout") and k < len(words) and re.match(r"^\d", words[k]):
                k += 1
        else:
            break
    return words[k:]


def runs_input(c):
    """A command that can run its stdin as code or open the file names it reads (sh, python, xargs, a read loop …)."""
    heads = [os.path.basename(w) for w in c.words[:first_command(c.words) + 1]]
    cw = command_words(c.words)
    if cw:
        heads.append(os.path.basename(cw[0]))
    return any(h in STDIN_RUNNERS or INTERP.match(h) for h in heads)


def interpreted(cmds):
    """True when code run by these commands goes to python/node/…; False for a shell or anything else (checked as a
    shell command, the stricter reading)."""
    for c in cmds:
        bases = [os.path.basename(w) for w in c.words]
        if any(b in SHELLS for b in bases):
            return False
        if any(INTERP.match(b) for b in bases):
            return True
    return False


def check_code(text, interp, depth, sink_text=True):
    """Code a shell or an interpreter will run: a heredoc script, a here-string, text piped into sh or python."""
    if not text.strip():
        return
    if not interp:
        check_bash(text, depth + 1, sink_text)
        return
    if BYPASS_TEXT.search(text):
        deny(HOOKS_REASON)
    if GUARD_FILES.search(text):
        deny(GUARD_REASON)
    hits = code_names(text)
    if hits:
        deny(SECRET_REASON.format(hits[0]))


def has_value(args, opts, value):
    return any(a in opts and i + 1 < len(args) and args[i + 1] == value or
               any(a == o + "=" + value for o in opts if o.startswith("--")) for i, a in enumerate(args))


def git_split(args):
    """(git's global option words, the subcommand, the index of its first argument in args)."""
    k, glob = 0, []
    while k < len(args) and args[k].startswith("-"):
        glob.append(args[k])
        if args[k] in GIT_GLOBAL_VALUE and k + 1 < len(args):
            glob.append(args[k + 1])
            k += 1
        k += 1
    return glob, (args[k] if k < len(args) else ""), k + 1


def heredoc_is_text(c):
    """cat/tee/wc/jq read a heredoc as text; so do git commit/tag/notes/merge -F - and gh … --body-file -."""
    k = first_command(c.words)
    verb = os.path.basename(c.words[k]) if k < len(c.words) else ""
    rest = c.words[k + 1:]
    if verb in ("cat", "tee", "wc", "jq"):
        return True
    if verb == "git":
        _, sub, off = git_split(rest)
        return sub in GIT_MESSAGE_SUBS and has_value(rest[off:], ("-F", "--file"), "-")
    if verb == "gh":
        return has_value(rest, ("-F", "--body-file"), "-")
    return False


def grep_pattern_indices(words, k, kind):
    """Indices of a grep/rg/git grep pattern (its first operand, or the -e values): text, never a file. Option values
    stay checked (a -f file is a file)."""
    short, long_ = GREP_VALUE[kind]
    pats, explicit, first, i = set(), False, None, k + 1
    if kind == "rg" and "--files" in words[k + 1:]:
        return pats
    while i < len(words):
        w = words[i]
        if w == "--":
            if first is None and i + 1 < len(words):
                first = i + 1
            break
        if w.startswith("--"):
            name = w.split("=", 1)[0]
            if name in ("--regexp", "--file"):
                explicit = True
            if name == "--regexp" and "=" in w:
                pats.add(i)
            if name in long_ and "=" not in w:
                if name == "--regexp" and i + 1 < len(words):
                    pats.add(i + 1)
                i += 1
        elif w.startswith("-") and len(w) > 1:
            for j, ch in enumerate(w[1:], 1):
                if ch in short:
                    explicit = explicit or ch in "ef"
                    if j == len(w) - 1:
                        if ch == "e" and i + 1 < len(words):
                            pats.add(i + 1)
                        i += 1
                    elif ch == "e":
                        pats.add(i)
                    break
        elif first is None:
            first = i
        i += 1
    if first is not None and not explicit:
        pats.add(first)
    return pats


def git_text_indices(words, k, sub=None):
    """Indices in words of a git command's text: commit/tag -m messages, log --grep/-S strings, git grep patterns.
    words[k] is the git word (git-<sub> when sub is given)."""
    if sub is None:
        _, sub, off = git_split(words[k + 1:])
        base = k + 1 + off  # index of the subcommand's first argument
    else:
        base = k + 1
    if sub == "grep":
        return grep_pattern_indices(words, base - 1, "git")
    out, i = set(), base
    text_opts = ({"-m", "--message"} if sub in GIT_MESSAGE_SUBS else set()) | \
        ({"--grep", "--author", "--committer", "-S", "-G", "--format", "--pretty"} if sub in GIT_LOG_SUBS else set())
    while i < len(words):
        w = words[i]
        if w == "--":
            break
        name = w.split("=", 1)[0]
        if name.startswith("--") and name in text_opts:
            if "=" in w:
                out.add(i)
            elif i + 1 < len(words):
                out.add(i + 1)
                i += 1
        elif w in text_opts and i + 1 < len(words):
            out.add(i + 1)
            i += 1
        elif sub in GIT_MESSAGE_SUBS and re.match(r"^-[A-Za-z]*m$", w) and i + 1 < len(words):
            out.add(i + 1)  # -am "message"
            i += 1
        i += 1
    return out


def text_positions(c, k, verb, inert):
    """Indices of the words that are text, not file arguments: echo/printf text (when it is only printed), commit
    messages, grep patterns, gh titles and bodies."""
    words = c.words
    if verb in ("echo", "printf") and inert:
        return set(range(k + 1, len(words)))
    if verb in GREP_VALUE and verb != "git":
        return grep_pattern_indices(words, k, verb)
    if verb == "git":
        return git_text_indices(words, k)
    if verb == "gh":
        return {i + 1 for i, w in enumerate(words) if w in GH_TEXT} | \
            {i for i, w in enumerate(words) if w.split("=", 1)[0] in GH_TEXT and "=" in w}
    return set()


def git_config_reads(sub, rest):
    if sub != "config":
        return False
    if rest and rest[0] in ("get", "list"):
        return True
    if any(w in CONFIG_WRITES for w in rest):
        return False
    if any(w in ("-l", "--list") or w.startswith("--get") for w in rest):
        return True
    args, i = [], 0
    while i < len(rest):
        if rest[i] in ("-f", "--file", "--blob", "--type", "--default", "--comment"):
            i += 2
            continue
        if not rest[i].startswith("-"):
            args.append(rest[i])
        i += 1
    return len(args) == 1  # `git config core.hooksPath` prints it


def check_git(words, k, dashed=None):
    """git's own ways to skip the hooks: --no-verify (and abbreviations), commit -n, core.hooksPath, bypass aliases.
    words[k] is the git word (git-<dashed> for git-commit, git-push …)."""
    if dashed is None:
        glob, sub, off = git_split(words[k + 1:])
        start = k + 1 + off
    else:
        glob, sub, start = [], dashed, k + 1
    if any(BYPASS_TEXT.search(w) for w in glob):
        deny(HOOKS_REASON)  # git -c core.hooksPath=…, --config-env=core.hooksPath=…
    text = git_text_indices(words, k, dashed)
    reads = git_config_reads(sub, words[start:])
    for i in range(start, len(words)):
        w = words[i]
        if i in text:
            continue
        if BYPASS_TEXT.search(w) and not (reads and not re.search(r"--no-veri|HUSKY|GIT_CONFIG_", w)):
            deny(HOOKS_REASON)
        if sub == "commit" and re.match(r"^-[A-Za-z]+$", w):
            for ch in w[1:]:
                if ch == "n":
                    deny("`git commit -n` skips the leak-guard hooks. Fix what the hook reports instead.")
                if ch in "mFCctSu":
                    break


def runs_as_command(words, i, cmd_at):
    """words[i] runs as a command: it is the command word, or a launcher before it (xargs, find -exec, watch, uv run
    …) runs it. A pattern such as `grep -e git` is not a command."""
    return i == cmd_at or any(os.path.basename(x) in LAUNCHERS for x in words[:i])


def check_hooks(c, k, verb, inert, depth, sink_text):
    """3. Commands that switch the git leak guard off."""
    words = c.words
    prose = verb in ("echo", "printf") and inert
    for i, w in enumerate(words):
        if not (prose and i > k) and HOOKS_ENV.match(w):
            deny(HOOKS_REASON)
    if prose:
        return
    if verb in ("echo", "printf") and BYPASS_TEXT.search(" ".join(words[k + 1:])):
        deny(HOOKS_REASON)  # echo "git commit --no-verify" | sh
    cmd_at = len(words) - len(command_words(words))
    for i, w in enumerate(words):
        b = os.path.basename(w)
        if (b == "git" or re.match(r"^git-[a-z][a-z-]*$", b)) and runs_as_command(words, i, cmd_at):
            check_git(words, i, None if b == "git" else b[4:])
            break
    for i, w in enumerate(words):
        if INTERP.match(os.path.basename(w)) and runs_as_command(words, i, cmd_at):
            if any(BYPASS_TEXT.search(x) for x in words[i + 1:]):
                deny(HOOKS_REASON)
            break
    for i, w in enumerate(words):  # bash -c 'code', su -c 'code': the code is a command
        b = os.path.basename(w)
        if b not in SHELLS and b != "su" or not runs_as_command(words, i, cmd_at):
            continue
        j = i + 1
        while j < len(words) and (words[j].startswith(("-", "+")) or b == "su"):
            if re.match(r"^-[A-Za-z]*c[A-Za-z]*$|^--command$", words[j]) and j + 1 < len(words):
                check_bash(words[j + 1], depth + 1, sink_text)
                break
            j += 2 if words[j] in ("-o", "+o", "-O", "+O") else 1
    cw = command_words(words)
    if cw and os.path.basename(cw[0]) == "eval":
        check_bash(" ".join(cw[1:]), depth + 1, sink_text)


def check_guard_files(c, s, verb, inert):
    """4. Reading Claude's settings and hooks is fine; changing them is the owner's job."""
    if not GUARD_FILES.search(c.raw):
        return
    reader = GUARD_READERS.match(s) and (inert or verb not in ("echo", "printf"))
    ok = bool(reader or GUARD_RUNNER.match(s) or GUARD_GITREAD.match(s))
    for op, t in c.redirs:
        if op not in WRITE_REDIRS or op == ">&" and re.match(r"^(\d+|-)$", t) or \
                t in ("/dev/null", "/dev/stdout", "/dev/stderr"):
            continue
        if GUARD_FILES.search(t) or re.search(r"[$`*?\[{]", t):
            ok = False  # a redirection into a guard file, or into a name only known at run time
    if not ok:
        deny(GUARD_REASON)


def include_filters_skip_secrets(words, opts):
    """True when include globs are given (grep --include, rg -g) and none can match a secret file."""
    globs, i = [], 0
    while i < len(words):
        w = words[i]
        for o in opts:
            if w == o and i + 1 < len(words):
                globs.append(words[i + 1])
                i += 1
                break
            if w.startswith(o + "="):
                globs.append(w[len(o) + 1:])
                break
            if len(o) == 2 and w.startswith(o) and len(w) > 2:
                globs.append(w[2:])
                break
        i += 1
    pos = [g for g in globs if not g.startswith("!")]
    return bool(pos) and not any(filter_can_match_secret(x) for g in pos for x in expand_braces(g))


def expand_braces(g, limit=64):
    m = re.search(r"\{([^{}]*)\}", g)
    if not m:
        return [g]
    out = []
    for alt in m.group(1).split(","):
        out += expand_braces(g[:m.start()] + alt + g[m.end():], limit)
    return out[:limit]


def filter_can_match_secret(g):
    b = base_of(g)
    return is_secret_name(b) or any(fnmatch.fnmatchcase(n.lower(), b.lower()) for n in FILTER_SAMPLES)


def check_recursive(c, s, sbare):
    """2. Recursive readers over a tree that holds a secret file."""
    verb = os.path.basename(s.split()[0]) if s.split() else ""
    names_only = bool(NAMES_ONLY.search(sbare))
    roots = None
    if verb in ("grep", "egrep", "fgrep") and re.search(r"(^|\s)(-[a-zA-Z]*[rR][a-zA-Z]*|--recursive|"
                                                        r"--dereference-recursive|-d\s*recurse)\b", sbare):
        if not include_filters_skip_secrets(c.words, ("--include",)):
            ops = operands(s)
            roots = ops[1:] if len(ops) > 1 else ["."]
    elif verb == "rg" and re.search(r"(^|\s)(-[a-zA-Z]*u[a-zA-Z]*|--hidden|--no-ignore\S*|--unrestricted|-\.)\b", sbare):
        if not include_filters_skip_secrets(c.words, ("-g", "--glob", "--iglob")):
            ops = operands(s)
            roots = ops[1:] if len(ops) > 1 else ["."]
    elif verb in ("ag", "ack", "ack-grep"):
        ops = operands(s)
        roots = ops[1:] if len(ops) > 1 else ["."]
    elif verb == "git" and re.search(r"\bgrep\b.*(--no-index|--untracked)", sbare):
        m = re.match(r"^git\s+-C\s+(\S+)", s)
        roots = [m.group(1).strip("'\"") if m else "."]
    elif verb in ("tar", "zip", "7z", "7zz", "cpio", "ditto") and \
            re.search(r"(^|\s)(-[a-zA-Z]*c[a-zA-Z]*|-r|a)\b|--create|^tar\s+[a-zA-Z]*c", sbare):
        roots = [o for o in operands(s) if os.path.isdir(os.path.expanduser(o))] or []
        names_only = False
    elif verb == "find" and re.search(r"-(exec|execdir|ok|okdir)\s+" + READERS + r"\b", sbare) and \
            not re.search(r"-i?(name|path|regex)\b", sbare):
        roots = [o for o in operands(s) if not o.startswith(("(", ")", "!", "{", "\\;", ";", "+"))][:1] or ["."]
        names_only = False
    if roots is not None and not names_only and any(holds_secret(r) for r in roots):
        deny("this search or archive reaches a directory that holds a secret file (.env, Secrets.xcconfig, keys) "
             "and can print its lines. Use `git grep` (tracked files only), plain `rg` (skips ignored and hidden "
             "files), -l for file names only, --include/-g globs that exclude secrets, or narrow the path.")


def xargs_runs(words):
    """The command xargs runs (after its options and their values)."""
    k = 1
    while k < len(words) and words[k].startswith("-"):
        k += 2 if words[k] in ("-n", "-L", "-P", "-I", "-E", "-d", "-s", "-a", "-R", "-S", "-J", "-l") else 1
    return os.path.basename(words[k]) if k < len(words) else "echo"


def check_find_xargs(pipe):
    """find … | xargs <reader>, where find has no name filter."""
    for i, c in enumerate(pipe):
        cw = command_words(c.words)
        if not cw or os.path.basename(cw[0]) != "xargs" or not re.match(READERS + "$", xargs_runs(cw)) or \
                NAMES_ONLY.search(" ".join(cw)):
            continue
        for q in pipe[:i]:
            qs = LEADING.sub("", q.raw).strip()
            if re.match(r"^find\b", qs) and not re.search(r"-i?(name|path|regex)\b", strip_quoted(qs)):
                roots = [o for o in operands(qs) if not o.startswith(("(", ")", "!"))][:1] or ["."]
                if any(holds_secret(r) for r in roots):
                    deny("find | xargs over a directory that holds a secret file can print its lines. Add a "
                         "-name filter, or use `git grep` / plain `rg`.")


def check_command(c, later, sink_text, depth):
    """Checks one simple command. `later` are the commands its output is piped into; sink_text says whether the
    pipeline's output ends up as text (printed, a message, an echo argument) rather than as the file arguments of an
    enclosing command."""
    words = c.words
    k = first_command(words)
    verb = os.path.basename(words[k]) if k < len(words) else ""
    inert = sink_text and all(verb_of(x) in TEXT_FILTERS for x in later)  # its output only gets printed or counted
    s = LEADING.sub("", c.raw).strip()
    sbare = strip_quoted(s)
    text_at = text_positions(c, k, verb, inert)

    # Command substitutions run first, and their output lands where the $( ) stands: text in a message or an echo
    # argument, file names anywhere else (an operand, an assignment, a redirection).
    for sub, kind, idx in c.subs:
        is_text = kind == "word" and idx in text_at or kind == "herestring" and inert and heredoc_is_text(c)
        check_pipes(sub, is_text, depth + 1)

    # Heredocs and here-strings: text for cat/tee/…, code for a shell or an interpreter.
    for h in c.heredocs:
        if not h["open"] and inert and heredoc_is_text(c):
            if not h["quoted"]:
                for sub in body_substitutions(h["body"], depth):
                    check_pipes(sub, True, depth + 1)
        else:
            check_code(h["body"], interpreted([c] + later), depth, sink_text)
    for hs in c.herestrings:
        if not (inert and heredoc_is_text(c)):
            check_code(hs, interpreted([c] + later), depth, sink_text)
    # echo/printf text piped into a shell or an interpreter is code.
    if verb in ("echo", "printf") and any(runs_input(x) for x in later):
        check_code(" ".join(words[k + 1:]), interpreted(later), depth, sink_text)

    check_hooks(c, k, verb, inert, depth, sink_text)
    check_guard_files(c, s, verb, inert)

    # 1. Secret files named by the command's file arguments and redirections.
    hits = []
    for i, w in enumerate(words):
        if i not in text_at:
            hits += word_names(w)
    for op, t in c.redirs:
        if not (op in (">&", "<&") and re.match(r"^(\d+|-)$", t)):
            hits += word_names(t)
    if hits:
        if any(p.match(s) for p in SAFE_SEGMENT) and not re.search(r"\$\(|`|<", s):
            if not inert:  # ls/find output becomes another command's input or arguments
                deny(NAMES_FED_REASON.format(hits[0]))
        else:
            deny(SECRET_REASON.format(hits[0]))

    check_recursive(c, s, sbare)


def check_pipes(pipes, sink_text, depth):
    for pipe in pipes:
        for i, c in enumerate(pipe):
            check_command(c, pipe[i + 1:], sink_text, depth)
        check_find_xargs(pipe)


def check_bash(cmd, depth=0, sink_text=True):
    """Denies a shell command that would expose a secret file, change a guard, or skip the git hooks."""
    check_pipes(Lexer(cmd, depth).run(), sink_text, depth)


# ---------- Supabase MCP ----------
SQL_SECRET = re.compile(r"(?i)(\bvault\s*\"?\s*\.|decrypted_secret|pgsodium|\bdecrypt|service_role_key|jwt_secret|"
                        r"email_pepper_key|encrypted_password|confirmation_token|recovery_token|"
                        r"pg_read_file|pg_read_binary_file|pg_ls_dir|lo_import|to\s+program)")
SQL_WRITE = re.compile(r"(?i)^\s*(insert|update|delete|truncate|drop|alter|create|grant|revoke|comment|vacuum|"
                       r"reindex|cluster|refresh|call|do|copy|merge|lock|security\s+label|with\b[\s\S]*\b"
                       r"(insert|update|delete))\b|\b(set_config|pg_terminate_backend|pg_cancel_backend|nextval|setval)"
                       r"\s*\(")
MCP_WRITE_TOOLS = ("apply_migration", "deploy_edge_function", "delete_branch", "merge_branch", "reset_branch",
                   "rebase_branch", "pause_project", "restore_project", "create_project", "create_branch")


def check_mcp_sql(name, ti):
    if name == "execute_sql":
        q = ti.get("query") or ""
        if SQL_SECRET.search(q):
            deny("this SQL touches Vault secrets, keys or credential columns. Never read them into a transcript; ask "
                 "the owner to check in the dashboard.")
        if any(SQL_WRITE.search(x) for x in q.split(";") if x.strip()):
            ask("This SQL writes to the Supabase project. Confirm only if the owner approved this exact change.")
    elif name in MCP_WRITE_TOOLS:
        ask(f"{name} changes the Supabase project. Confirm only if the owner approved this exact change.")


# ---------- every tool ----------
# Keys that hold a path or URL (checked even with spaces in them); other keys are checked when they hold one word.
PATH_KEYS = {"file_path", "file_paths", "notebook_path", "path", "paths", "files", "url", "uri", "file", "filename",
             "source", "destination", "target", "dir", "directory", "root", "out_dir", "cwd", "scriptPath"}
SKIP_KEYS = {"content", "new_string", "old_string", "new_source", "edits", "prompt", "description", "body", "text",
             "query", "message", "caption", "title", "pattern", "label", "intent", "notes", "summary"}
COMMAND_KEYS = {"command", "cmd", "script", "shell"}
# Tools whose inputs are prose and orchestration for other agents, whose own tool calls this guard checks when they
# run: only their real path fields are checked, never the text (a Workflow script cannot touch files itself).
PROSE_TOOLS = {"Workflow", "Agent", "Task", "SendMessage", "Skill", "AskUserQuestion", "ScheduleWakeup", "CronCreate",
               "TodoWrite", "TaskCreate", "TaskUpdate", "ExitPlanMode", "EnterPlanMode", "PushNotification",
               "SuggestSkills", "ToolSearch"}


def walk(value, key=""):
    if isinstance(value, dict):
        for k, v in value.items():
            yield from walk(v, k)
    elif isinstance(value, list):
        for v in value:
            yield from walk(v, key)
    elif isinstance(value, str):
        yield key, value


def main():
    data = json.load(sys.stdin)
    tool = data.get("tool_name", "") or ""
    ti = data.get("tool_input") or {}
    name = tool.split("__")[-1] if tool.startswith("mcp__") else tool
    if tool.startswith("mcp__") and name in (("execute_sql",) + MCP_WRITE_TOOLS):
        check_mcp_sql(name, ti)
    if tool in ("Write", "Edit", "MultiEdit", "NotebookEdit"):
        p = ti.get("file_path") or ti.get("notebook_path") or ""
        if is_guard_path(p):
            deny("changing Claude's settings or hooks (~/.claude, .claude/settings*.json, .claude/hooks/) is the "
                 "owner's job, not an agent's. Ask the user.")
    if tool == "Grep":
        g = ti.get("glob") or ""
        if is_secret_path(ti.get("path") or "") or (g and (glob_can_name_secret(g) or is_secret_path(g) or
                                                           re.search(r"(^|[{,/])\.env|env[},]|xcconfig", g))):
            deny(SECRET_REASON.format(os.path.basename(ti.get("path") or "") or g))
        if ti.get("output_mode") == "content" and SECRET_WORD.search(ti.get("pattern") or "") and \
                holds_secret(ti.get("path") or "."):
            deny("printing the lines that match a secret-looking name over a directory that holds a secret file can "
                 "print its value. Use output_mode files_with_matches, then read the files you need.")
    if tool in PROSE_TOOLS:
        for key in ("scriptPath", "file_path", "notebook_path", "path"):
            v = ti.get(key)
            if isinstance(v, str) and is_secret_path(v):
                deny(SECRET_REASON.format(base_of(v)))
        sys.exit(0)
    for key, s in walk(ti):
        if key in COMMAND_KEYS:
            check_bash(s)
        elif key not in SKIP_KEYS and s and (key in PATH_KEYS or not re.search(r"\s", s)) and is_secret_path(s):
            deny(SECRET_REASON.format(base_of(s)))
    sys.exit(0)


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception as e:  # fail closed
        deny(f"the guard could not check this call ({type(e).__name__}); nothing ran. Fix the guard or ask the user.")
