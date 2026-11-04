#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Install the HTFG prctl() hook into kernel/sys.c.

Usage:
    python3 patch_sysc.py <kernel_tree>/kernel/sys.c

The patch is idempotent.  It does two things:
  1. insert `#include <linux/htfg.h>` after the first `#include <linux/...>`;
  2. insert, after the local declarations and before the LSM hook:

        if (unlikely(option == HTFG_PRCTL_MAGIC))
            return htfg_kernel_entry(arg2, arg3, arg4, arg5);

No anchor match means a non-zero exit and a printout of the first lines of
prctl(); the build must fail rather than silently ship a kernel without the
hook.
"""

import io
import sys

INCLUDE_LINE = "#include <linux/htfg.h>\n"

HOOK = (
    "\tif (unlikely(option == HTFG_PRCTL_MAGIC))\n"
    "\t\treturn htfg_kernel_entry(arg2, arg3, arg4, arg5);\n"
    "\n"
)

# Priority: (anchor, insert before/after)
ANCHORS = [
    ("\terror = security_task_prctl(option, arg2, arg3, arg4, arg5);\n", "before"),
    ("\tstruct task_struct *me = current;\n", "after"),
]

PRCTL_START = "SYSCALL_DEFINE5(prctl,"


def die(msg, lines=None, start=None):
    sys.stderr.write("patch_sysc: FAILED: %s\n" % msg)
    if lines is not None and start is not None and start >= 0:
        end = min(len(lines), start + 30)
        sys.stderr.write("---- first %d lines of prctl() in kernel/sys.c ----\n" % (end - start))
        sys.stderr.writelines(lines[start:end])
        sys.stderr.write("--------------------------------------------------\n")
    sys.exit(1)


def main():
    if len(sys.argv) != 2:
        sys.stderr.write("usage: patch_sysc.py <path/to/kernel/sys.c>\n")
        sys.exit(2)

    path = sys.argv[1]
    with io.open(path, "r", encoding="utf-8", errors="surrogateescape", newline="") as f:
        text = f.read()

    # New name only.  Do not accept the old htfg_prctl / ksu_htfg_prctl names:
    # this project is a clean-room source tree, not a migrated one.
    n_new = text.count("htfg_kernel_entry")
    if n_new > 1:
        die("kernel/sys.c contains %d htfg_kernel_entry hooks" % n_new)
    if n_new == 1:
        print("patch_sysc: already patched, skipping -> %s" % path)
        return
    if "htfg_prctl" in text or "ksu_htfg_prctl" in text:
        die("kernel/sys.c contains a legacy HTFG hook; restore kernel/sys.c first")

    lines = text.splitlines(keepends=True)
    if not lines:
        die("file is empty")

    # ---- Locate the prctl() body (all later lookups are after it) ----
    pidx = -1
    for i, ln in enumerate(lines):
        if ln.startswith(PRCTL_START):
            pidx = i
            break
    if pidx < 0:
        die("cannot find %r (kernel version difference?)" % PRCTL_START, lines, 0)

    # ---- Locate the include insertion point ----
    inc_idx = -1
    for i, ln in enumerate(lines):
        if ln.startswith("#include <linux/"):
            inc_idx = i
            break
    if inc_idx < 0:
        die("no `#include <linux/...>` line found, cannot insert header", lines, pidx)

    # ---- Locate the hook insertion point ----
    # Find both positions before modifying the file, so a failure leaves no
    # half-patched tree.
    hit = None
    for anchor, where in ANCHORS:
        try:
            idx = lines.index(anchor, pidx)
        except ValueError:
            continue
        hit = (idx, where)
        break

    if hit is None:
        die(
            "none of the anchors matched: %s" % " / ".join(repr(a[0]) for a in ANCHORS),
            lines,
            pidx,
        )

    idx, where = hit

    # ---- Insert ----
    if "#include <linux/htfg.h>" not in text:
        lines.insert(inc_idx + 1, INCLUDE_LINE)
        if idx > inc_idx:       # include was inserted before the hook, shift
            idx += 1

    if where == "before":
        lines.insert(idx, HOOK)
    else:
        lines.insert(idx + 1, HOOK)

    out = "".join(lines)

    # ---- Self-check ----
    for must in ("#include <linux/htfg.h>", "HTFG_PRCTL_MAGIC", "htfg_kernel_entry"):
        if must not in out:
            die("self-check failed: %r missing from result" % must, lines, pidx)

    with io.open(path, "w", encoding="utf-8", errors="surrogateescape", newline="") as f:
        f.write(out)

    print("patch_sysc: prctl hook installed into %s" % path)


if __name__ == "__main__":
    main()
