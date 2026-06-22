#!/usr/bin/env python3
"""Self-test for the mutation engine — proves it skips comments/strings/test
blocks and catches real code. Run: python3 tooling/mutate/test_mutate.py"""
import sys, os
sys.path.insert(0, os.path.dirname(__file__))
import mutate

FIXTURE = '''\
const std = @import("std");
// this comment has a == and an `and` and return true — none must mutate
fn f(a: u8, b: u8) bool {
    return a == b and a != 0;
}
const s = "a string with == and or inside";
fn g() bool { return true; }
test "g returns true" {
    // inside a test block: x == y must NOT be mutated
    try std.testing.expect(g() == true);
}
'''

def run():
    sites = mutate.sites(FIXTURE)
    lines = {s["line"] for s in sites}
    ops = [(s["line"], s["op"]) for s in sites]
    fails = []

    # Line 2 is a comment — no sites.
    if 2 in lines: fails.append("comment line 2 was mutated")
    # Line 6 is a string — no sites.
    if 6 in lines: fails.append("string line 6 was mutated")
    # Lines 8-11 are a test block — no sites (incl. the == on line 10/11).
    if any(8 <= ln <= 11 for ln in lines): fails.append("test-block lines 8-11 were mutated")
    # Line 4 IS real code: must have == , and , != sites.
    l4 = {op for ln, op in ops if ln == 4}
    for need in ("==->!=", "and->or", "!=->=="):
        if need not in l4: fails.append(f"line 4 missing real site {need}")
    # Line 7 `return true` IS real code.
    if not any(ln == 7 and op == "return true->return false" for ln, op in ops):
        fails.append("line 7 'return true' not caught")

    if fails:
        print("FAIL:")
        for f in fails: print("  -", f)
        print("sites found:", ops)
        return 1
    print(f"OK — {len(sites)} real-code sites; comments/strings/test-blocks correctly skipped")
    return 0

sys.exit(run())
