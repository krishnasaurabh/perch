#!/usr/bin/env python3
"""Reject private material and generated output from Git's index or history."""
import argparse
import pathlib
import re
import subprocess
import sys

ROOT_FILES = {
    "README.md", "LICENSE", "AGENTS.md", "CONTRIBUTING.md", "SECURITY.md",
    "CHANGELOG.md", "Package.swift", "Package.resolved", ".gitignore",
    ".gitattributes", ".editorconfig", ".pre-commit-config.yaml", ".swift-format",
}
ROOT_DIRS = {"Sources", "Tests", "Resources", "scripts", ".github", ".githooks", "docs"}
PRIVATE_DIRS = {
    "re", "research", "reference", "references", "team", "qa", "pstack",
    "audits", "audit", "reports", "artifacts", "evidence", "recordings",
    "screenshots", "logs", "test-results", "test-output", "coverage",
    "htmlcov", "__pycache__", ".hermes", ".claude", ".build", ".swiftpm",
    ".worktrees", "dist", "node_modules",
}
OUTPUT_SUFFIXES = {
    ".log", ".pyc", ".pyo", ".dmg", ".app", ".xcresult", ".profraw",
    ".profdata", ".trace", ".har", ".mp4", ".mov", ".zip", ".tgz",
}
CONTENT_RULES = (
    ("private key", re.compile(rb"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----")),
    ("access token", re.compile(rb"(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,}|sk-[A-Za-z0-9_-]{32,})")),
    ("private machine path", re.compile(rb"/(?:home|Users)/[A-Za-z0-9_.-]+/")),
    ("private host", re.compile(rb"(?:\bbrev-[a-z0-9]+\b|\bvara" rb"-mac\b|[a-z0-9.-]{1,253}\.ts\.net\b)", re.I)),
    ("private network address", re.compile(rb"\b100\.(?:6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.[0-9]{1,3}\.[0-9]{1,3}\b")),
    ("unsupported provenance claim", re.compile(rb"\b(?:clean[\s-]+room|from[\s-]+scratch)\b", re.I)),
)


def git(*args, data=None):
    return subprocess.check_output(["git", *args], input=data)


def path_problem(path):
    p = pathlib.PurePosixPath(path)
    parts = p.parts
    if not parts or (len(parts) == 1 and path not in ROOT_FILES) or (len(parts) > 1 and parts[0] not in ROOT_DIRS):
        return "outside product source/documentation paths"
    if any(part.lower() in PRIVATE_DIRS for part in parts):
        return "private or generated directory"
    if p.suffix.lower() in OUTPUT_SUFFIXES or p.name.startswith((".env", ".coverage")):
        return "generated output or local configuration"
    if parts[0] == "docs" and p.suffix.lower() not in {".md", ".rst"}:
        return "only user-facing text belongs in docs"
    return None


def content_problem(data):
    for reason, pattern in CONTENT_RULES:
        if pattern.search(data):
            return reason
    return None


def records(ref=None):
    if ref is None:
        raw = git("ls-files", "--stage", "-z")
        for row in raw.split(b"\0"):
            if row:
                meta, path = row.split(b"\t", 1)
                mode, oid, stage = meta.split()
                yield mode, oid, path.decode("utf-8", "surrogateescape")
    else:
        raw = git("ls-tree", "-rz", "--full-tree", ref)
        for row in raw.split(b"\0"):
            if row:
                meta, path = row.split(b"\t", 1)
                mode, kind, oid = meta.split()
                yield mode, oid, path.decode("utf-8", "surrogateescape")


def check(refs=None):
    problems, blobs, paths = set(), {}, set()
    revisions = refs or [None]
    for ref in revisions:
        for mode, oid, path in records(ref):
            paths.add(path)
            reason = path_problem(path)
            if reason:
                problems.add((path, reason))
            if mode not in {b"100644", b"100755"}:
                problems.add((path, "symlinks and submodules require explicit review"))
                continue
            if oid not in blobs:
                data = git("cat-file", "blob", oid.decode())
                blobs[oid] = (len(data), content_problem(data) if len(data) <= 1024 * 1024 else None)
            size, reason = blobs[oid]
            if size > 1024 * 1024:
                problems.add((path, "file exceeds 1 MiB; use a release asset instead"))
            if reason:
                problems.add((path, reason))
    if paths:
        data = b"\0".join(p.encode("utf-8", "surrogateescape") for p in sorted(paths)) + b"\0"
        result = subprocess.run(["git", "check-ignore", "--no-index", "--stdin", "-z"], input=data, stdout=subprocess.PIPE, check=False)
        if result.returncode not in (0, 1):
            raise RuntimeError("git check-ignore failed")
        for path in result.stdout.split(b"\0"):
            if path:
                problems.add((path.decode("utf-8", "surrogateescape"), "tracked despite ignore rule"))
    if refs:
        for ref in refs:
            message = git("show", "-s", "--format=%B", ref)
            reason = content_problem(message)
            if reason:
                problems.add((ref[:12], "commit message: " + reason))
    for path, reason in sorted(problems):
        print(f"Blocked: {path}: {reason}", file=sys.stderr)
    print("Repository hygiene: " + ("FAILED" if problems else "passed"))
    return bool(problems)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--staged", action="store_true", help="check staged contents (default)")
    group.add_argument("--history", nargs="+", metavar="REV", help="check every commit reachable from revisions")
    args = parser.parse_args()
    refs = git("rev-list", *args.history).decode().splitlines() if args.history else None
    return int(check(refs))


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (subprocess.CalledProcessError, RuntimeError) as exc:
        print(f"Repository hygiene could not run: {type(exc).__name__}", file=sys.stderr)
        sys.exit(2)
