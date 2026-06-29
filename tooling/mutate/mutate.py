#!/usr/bin/env python3
"""Zig source mutation engine for the caveman meaningful-coverage gate.

Enumerates operator-mutation sites in a Zig source file, OR applies a single
mutation by index. Comment-, string-, and test-block-aware so it never mutates
non-code bytes (which would yield bogus "killed" results from compile errors that
have nothing to do with test quality).

No off-the-shelf Zig mutation tool exists (verified 2025-2026), so this is a
purpose-built, minimal engine. It is deliberately conservative: it only mutates
tokens it can prove are real code operators, and it skips anything inside a
`test "..." { ... }` block (we mutate code-under-test, not the tests).

Operators (mirrors universalmutator / Stryker semantics, scoped to what matters
for this codebase's branch/relational/boolean/return logic):
    ==  <-> !=           relational equality flip
    <   <-> <=  ,  >  <-> >=     boundary off-by-one
    and <-> or           boolean operator swap
    return true <-> return false   literal result flip
    orelse-RHS deletion is intentionally NOT done here (hard to do safely with a
        regex; covered by the relational/boolean operators around it).

Usage:
    mutate.py list   FILE                 -> JSON list of {idx,line,col,op,from,to}
    mutate.py apply  FILE IDX [--out F]   -> writes mutated source (to F or stdout)
    mutate.py count  FILE                 -> integer count of mutation sites
"""
import json
import re
import sys

# (pattern, replacement) operator pairs. `pattern` matches the operator token
# with surrounding spaces so we don't catch `===`/`!==`-like or compound tokens,
# and so `<`/`>` don't match inside `<=`/`>=`/generics/shift. We require the
# spaced form the codebase uses (verified: `a == b`, `x and y`, `return true;`).
MUTATORS = [
    (re.compile(r"(?<= )==(?= )"), "!=", "=="),
    (re.compile(r"(?<= )!=(?= )"), "==", "!="),
    (re.compile(r"(?<= )<=(?= )"), "<", "<="),
    (re.compile(r"(?<= )>=(?= )"), ">", ">="),
    # bare < / > only when spaced AND not part of <=,>=,<<,>> (the lookarounds
    # ensure a space on both sides, which excludes those compound tokens).
    (re.compile(r"(?<= )<(?= )"), "<=", "<"),
    (re.compile(r"(?<= )>(?= )"), ">=", ">"),
    (re.compile(r"(?<= )and(?= )"), "or", "and"),
    (re.compile(r"(?<= )or(?= )"), "and", "or"),
    (re.compile(r"return true\b"), "return false", "return true"),
    (re.compile(r"return false\b"), "return true", "return false"),
]


def _code_mask(src: str):
    """Return a bool list, True where the byte is real code (not in a //comment,
    not in a "string"/'char'/\\\\multiline, not inside a test "..." {} block).
    Single-pass scanner over the source."""
    mask = [True] * len(src)
    i, n = 0, len(src)
    state = "code"  # code | line_comment | string | char | multiline_str
    # Track test-block depth: when we see `test ` at statement level we find its
    # `{` and mask out to the matching `}`.
    while i < n:
        c = src[i]
        nxt = src[i + 1] if i + 1 < n else ""
        if state == "code":
            if c == "/" and nxt == "/":
                state = "line_comment"; mask[i] = mask[i + 1] = False; i += 2; continue
            if c == '"':
                state = "string"; mask[i] = False; i += 1; continue
            if c == "'":
                state = "char"; mask[i] = False; i += 1; continue
            if c == "\\" and nxt == "\\":
                state = "multiline_str"; mask[i] = mask[i + 1] = False; i += 2; continue
            i += 1
        elif state == "line_comment":
            mask[i] = False
            if c == "\n": state = "code"
            i += 1
        elif state == "string":
            mask[i] = False
            if c == "\\" and nxt:  # escape: consume next byte too
                if i + 1 < n: mask[i + 1] = False
                i += 2; continue
            if c == '"': state = "code"
            i += 1
        elif state == "char":
            mask[i] = False
            if c == "\\" and nxt:
                if i + 1 < n: mask[i + 1] = False
                i += 2; continue
            if c == "'": state = "code"
            i += 1
        elif state == "multiline_str":
            mask[i] = False
            if c == "\n": state = "code"  # \\ multiline strings end at EOL
            i += 1
    _mask_test_blocks(src, mask)
    return mask


def _mask_test_blocks(src: str, mask):
    """Mask out the body of every `test "..." { ... }` / `test name { ... }`
    block so we mutate code-under-test, not the test assertions themselves."""
    for m in re.finditer(r'(?m)^[ \t]*test\b[^\n{]*\{', src):
        # find matching close brace from the opening '{'
        depth = 0
        j = m.end() - 1  # at the '{'
        # only count braces in real code (skip strings/comments already masked)
        while j < len(src):
            ch = src[j]
            if mask[j] or ch in "{}":
                if ch == "{": depth += 1
                elif ch == "}":
                    depth -= 1
                    if depth == 0:
                        for k in range(m.start(), j + 1):
                            mask[k] = False
                        break
            j += 1


def sites(src: str):
    mask = _code_mask(src)
    out = []
    for pat, to, frm in MUTATORS:
        for m in pat.finditer(src):
            s = m.start()
            if not mask[s]:
                continue
            # require the whole matched token to be in-code
            if not all(mask[k] for k in range(m.start(), m.end())):
                continue
            line = src.count("\n", 0, s) + 1
            col = s - (src.rfind("\n", 0, s))
            out.append({"idx": None, "pos": s, "end": m.end(), "line": line,
                        "col": col, "op": f"{frm}->{to}", "from": frm, "to": to})
    out.sort(key=lambda d: d["pos"])
    for n, d in enumerate(out):
        d["idx"] = n
    return out


def apply(src: str, idx: int) -> str:
    sl = sites(src)
    if idx < 0 or idx >= len(sl):
        raise SystemExit(f"idx {idx} out of range (0..{len(sl)-1})")
    d = sl[idx]
    return src[: d["pos"]] + d["to"] + src[d["end"]:]


def main(argv):
    if len(argv) < 3:
        raise SystemExit(__doc__)
    cmd, path = argv[1], argv[2]
    src = open(path, encoding="utf-8").read()
    if cmd == "list":
        sl = sites(src)
        for d in sl:
            d.pop("pos", None); d.pop("end", None)
        print(json.dumps(sl))
    elif cmd == "count":
        print(len(sites(src)))
    elif cmd == "apply":
        idx = int(argv[3])
        out_path = None
        if "--out" in argv:
            out_path = argv[argv.index("--out") + 1]
        mutated = apply(src, idx)
        if out_path:
            open(out_path, "w", encoding="utf-8").write(mutated)
        else:
            sys.stdout.write(mutated)
    else:
        raise SystemExit(f"unknown command {cmd}")


if __name__ == "__main__":
    main(sys.argv)
