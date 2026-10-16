#!/usr/bin/env python3
"""Rewrites one key of config.sh in place: the single writer the bars, their
actions and the installer all call. There used to be five copies of it, and
two of them wrote values raw.

  setconfig.py <config.sh> KEY value
  setconfig.py <config.sh> KEY[] entry...     the one array, REPOS_ROOTS

Every bar sources this file every few seconds, so a value is shell code, not
text: it is escaped, and the file is replaced in one rename rather than
rewritten where a bar could read it half-written.
"""
import os
import re
import sys
import tempfile

KEY = re.compile(r'[A-Z_][A-Z0-9_]*$')


def quote(v):
    # $HOME is spared so stored paths stay portable between machines; every
    # other $, and backticks, quotes and backslashes, is escaped.
    out = v.replace("\\", "\\\\").replace('"', '\\"').replace("`", "\\`")
    return re.sub(r'\$(?!HOME\b)', r'\\$', out)


def main(path, key, values):
    array = key.endswith("[]")
    name = key[:-2] if array else key
    # The key arrives from a menu parameter: anything that is not a plain
    # variable name would be written as a line of shell of its own.
    if not KEY.match(name):
        sys.exit("setconfig: not a config key: %r" % key)
    # Through a symlink to the real file, so a config kept in a dotfiles repo
    # stays a symlink instead of being replaced by a copy.
    real = os.path.realpath(path)
    os.makedirs(os.path.dirname(real), exist_ok=True)
    txt = open(real).read() if os.path.exists(real) else ""
    if array:
        block = name + "=(\n" + "".join('  "%s"\n' % quote(v) for v in values) + ")"
        pat = re.compile(r'^%s=\(.*?^\)' % re.escape(name), re.M | re.S)
    else:
        block = '%s="%s"' % (name, quote(values[0] if values else ""))
        pat = re.compile(r'^%s=.*$' % re.escape(name), re.M)
    if pat.search(txt):
        txt = pat.sub(lambda _: block, txt, count=1)
    else:
        txt = txt.rstrip() + "\n" + block + "\n"
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(real), prefix=".config.")
    with os.fdopen(fd, "w") as f:
        f.write(txt)
    # mkstemp makes it 0600; keep whatever the file had, or a normal 0644.
    os.chmod(tmp, os.stat(real).st_mode & 0o777 if os.path.exists(real) else 0o644)
    os.replace(tmp, real)


if __name__ == "__main__":
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2], sys.argv[3:])
