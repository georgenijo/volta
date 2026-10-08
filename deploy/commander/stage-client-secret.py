#!/usr/bin/env python3
"""Copy one value from a root-only dotenv file into commander's secret file.

Usage (as root): stage-client-secret.py SOURCE.env DEST [KEY]

Never prints the value. Supports KEY='single quoted' (literal, no expansion),
KEY="double quoted" without escapes, and bare KEY=value. DEST is written
atomically, owned by commander's uid/gid 65532 with mode 0400.
"""
import os
import sys
import tempfile

UID = GID = 65532


def value(path, key):
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line.startswith("export "):
                line = line[7:].lstrip()
            name, sep, raw = line.partition("=")
            if not sep or name.strip() != key:
                continue
            raw = raw.strip()
            if len(raw) >= 2 and raw[0] == raw[-1] and raw[0] in "'\"":
                if raw[0] == '"' and ("\\" in raw or "$" in raw):
                    sys.exit("refusing double-quoted value with escapes; use single quotes")
                raw = raw[1:-1]
            elif any(c in raw for c in "'\"\\ #$"):
                sys.exit("refusing ambiguous unquoted value; use single quotes")
            if not raw or "\n" in raw or "\r" in raw:
                sys.exit("value is empty or multi-line")
            return raw
    sys.exit("key not found")


def main():
    if len(sys.argv) not in (3, 4):
        sys.exit(__doc__)
    source, dest = sys.argv[1], os.path.abspath(sys.argv[2])
    secret = value(source, sys.argv[3] if len(sys.argv) == 4 else "TESLA_CLIENT_SECRET")
    directory = os.path.dirname(dest)
    os.makedirs(directory, mode=0o755, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=directory, prefix=".client-secret.")
    try:
        with os.fdopen(fd, "wb") as f:
            os.fchmod(f.fileno(), 0o400)
            os.fchown(f.fileno(), UID, GID)
            f.write((secret + "\n").encode())
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, dest)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise
    print("staged client secret for uid 65532 (value not shown)")


if __name__ == "__main__":
    main()
