#!/usr/bin/env python3
"""Render a source formula pinned to a published tag or immutable commit archive."""
import hashlib
import pathlib
import re
import sys

if len(sys.argv) != 4:
    raise SystemExit("Usage: make-formula.py VERSION SOURCE_URL SOURCE_ARCHIVE")
version, url, archive = sys.argv[1], sys.argv[2], pathlib.Path(sys.argv[3])
if not re.fullmatch(r"[0-9][A-Za-z0-9.+-]*", version):
    raise SystemExit("Invalid formula version")
if not re.fullmatch(r"https://github.com/dokterbob/macos-speech-server/archive/(?:refs/tags/v[0-9A-Za-z.+-]+|[a-f0-9]{40})\.tar\.gz", url):
    raise SystemExit("Use a version tag or full commit archive URL from this repository")
digest = hashlib.sha256()
with archive.open("rb") as source:
    for chunk in iter(lambda: source.read(1024 * 1024), b""):
        digest.update(chunk)
template = pathlib.Path(__file__).with_name("macos-speech-server-app.rb.in").read_text()
print(template.replace("@VERSION@", version).replace("@SOURCE_URL@", url).replace("@SHA256@", digest.hexdigest()), end="")
