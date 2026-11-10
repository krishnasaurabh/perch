#!/usr/bin/env python3
"""Bind a freshly built CI bundle to its clean source checkout, without modifying its signature."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys

app = Path(sys.argv[1]).resolve()
sha = subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()
subprocess.run(['git', 'diff', '--exit-code', 'HEAD', '--', 'Sources', 'Package.swift'], check=True)
binary = app / 'Contents/MacOS/Perch'
out = app.parent / 'motion-build.json'
out.write_text(json.dumps(dict(schema=1, build_sha=sha, binary_sha256=hashlib.sha256(binary.read_bytes()).hexdigest()), indent=2))
print(out)
