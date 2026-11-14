#!/bin/bash
# Capture each declared state at 2x. One app process per appearance/motion pair.
set -euo pipefail
python3 - "$@" <<'PY'
# BEGIN PYTHON
import argparse
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import struct
import subprocess
import sys
import tempfile
import zlib


def parse_list(text):
    shots = []
    names = set()
    for line_number, line in enumerate(text.splitlines(), 1):
        try:
            words = shlex.split(line, comments=True)
            if not words:
                continue
            name, *arguments = words
            if not re.fullmatch(r"[a-z0-9][a-z0-9_-]*", name) or name in names:
                raise ValueError("invalid or duplicate shot name")
            options = {}
            index = 0
            while index < len(arguments):
                flag = arguments[index]
                index += 1
                if flag not in ("--scenario", "--open") or flag in options:
                    raise ValueError("expected unique --scenario or --open")
                if index == len(arguments) or not arguments[index] or arguments[index].startswith("--"):
                    raise ValueError("missing option value")
                options[flag] = arguments[index]
                index += 1
            if "--scenario" not in options:
                raise ValueError("a scenario is required")
            if "--open" not in options:
                arguments += ["--open", "today"]
            names.add(name)
            shots.append(dict(name=name, arguments=arguments))
        except ValueError as error:
            raise ValueError(f"line {line_number}: {error}") from error
    if not shots:
        raise ValueError("the shot list is empty")
    return shots


def png_size(path):
    try:
        data = path.read_bytes()
    except OSError as error:
        raise ValueError(f"missing image: {path.name}") from error
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError(f"invalid PNG: {path.name}")
    offset, size, pixels, ended = 8, None, bytearray(), False
    while offset + 12 <= len(data):
        length = struct.unpack(">I", data[offset:offset + 4])[0]
        kind = data[offset + 4:offset + 8]
        chunk = data[offset + 8:offset + 8 + length]
        crc = data[offset + 8 + length:offset + 12 + length]
        if len(crc) != 4 or zlib.crc32(kind + chunk) != struct.unpack(">I", crc)[0]:
            raise ValueError(f"invalid PNG chunk: {path.name}")
        if kind == b"IHDR":
            if len(chunk) != 13:
                raise ValueError("invalid PNG header")
            size = struct.unpack(">II", chunk[:8])
        if kind == b"IDAT":
            pixels.extend(chunk)
        if kind == b"IEND":
            ended = True
            break
        offset += length + 12
    try:
        decoded = zlib.decompress(pixels)
    except zlib.error as error:
        raise ValueError(f"invalid PNG pixels: {path.name}") from error
    if not ended or size is None or min(size) <= 0 or not decoded:
        raise ValueError(f"incomplete PNG: {path.name}")
    return size


def verify_batch(directory, shots, appearance, reduced):
    try:
        receipts = json.loads((directory / "result.json").read_text())
    except (OSError, ValueError) as error:
        raise ValueError("missing or invalid batch receipt") from error
    if not isinstance(receipts, list) or len(receipts) != len(shots):
        raise ValueError("incomplete batch receipt")
    by_name = {row.get("name"): row for row in receipts if isinstance(row, dict)}
    if len(by_name) != len(shots) or set(by_name) != {s["name"] for s in shots}:
        raise ValueError("duplicate or unexpected receipt")
    for shot in shots:
        row = by_name[shot["name"]]
        args = shot["arguments"]
        scenario = args[args.index("--scenario") + 1]
        target = args[args.index("--open") + 1]
        if row.get("scenario") != scenario:
            raise ValueError("receipt does not match requested scenario")
        if row.get("target") != target or row.get("appearance") != appearance or row.get("reduceMotion") is not reduced:
            raise ValueError("receipt does not match requested state")
        dimensions = (row.get("width"), row.get("height"))
        if row.get("scale") != 2 or any(not isinstance(n, int) or n <= 0 for n in dimensions):
            raise ValueError("invalid 2x receipt")
        if png_size(directory / (shot["name"] + ".png")) != tuple(n * 2 for n in dimensions):
            raise ValueError("image is not 2x its logical bounds")


def run_shots(binary, output, shots, run=subprocess.run):
    output.mkdir(parents=True, exist_ok=True)
    count = 0
    # Separate processes keep immutable motion-policy injection honest. Each process
    # reuses its store and window hosts for the whole list, avoiding N cold launches.
    for appearance in ("light", "dark"):
        for reduced in (False, True):
            mode = appearance + ("-reduced" if reduced else "")
            with tempfile.TemporaryDirectory(prefix="redesign-", dir=output) as tmp:
                work = Path(tmp)
                plan = dict(output=str(work), appearance=appearance, reduceMotion=reduced, shots=shots)
                plan_path = work / "plan.json"
                plan_path.write_text(json.dumps(plan))
                command = [str(binary), "-AppleLocale", "en_GB", "--appearance", appearance,
                           "--redesign-shots", str(plan_path)]
                if reduced:
                    command.append("--reduce-motion")
                environment = dict(os.environ, PERCH_DATA=str(work / "planner.json"), TZ="UTC")
                try:
                    result = run(command, env=environment, capture_output=True, text=True,
                                 timeout=15 + len(shots) * 5)
                except subprocess.TimeoutExpired as error:
                    raise RuntimeError(f"{mode}: app timed out") from error
                (output / (mode + ".log")).write_text(result.stdout + result.stderr)
                if result.returncode != 0:
                    raise RuntimeError(f"{mode}: app exited {result.returncode}; see {mode}.log")
                verify_batch(work, shots, appearance, reduced)
                destination = output / mode
                if destination.exists():
                    shutil.rmtree(destination)
                destination.mkdir()
                for name in [s["name"] + ".png" for s in shots] + ["result.json"]:
                    shutil.copyfile(work / name, destination / name)
                count += len(shots)
    return count


def main():
    parser = argparse.ArgumentParser(description="Capture declared Perch states at 2x in light, dark and Reduce Motion.")
    parser.add_argument("output", type=Path)
    parser.add_argument("--app", type=Path, default=Path("dist/Perch.app/Contents/MacOS/Perch"))
    parser.add_argument("--list", type=Path, default=Path("scripts/redesign_shots.list"))
    args = parser.parse_args()
    if not args.app.is_file():
        parser.error("build the instrumented app first, or supply --app")
    try:
        total = run_shots(args.app.resolve(), args.output.resolve(), parse_list(args.list.read_text()))
    except (ValueError, RuntimeError) as error:
        print(f"redesign snapshots: {error}", file=sys.stderr)
        return 1
    print(f"Captured {total} verified 2x images.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
# END PYTHON
PY
