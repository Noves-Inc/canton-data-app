#!/usr/bin/env python3
"""Upgrade only official v4 image pins; retain every other dotenv byte and a private backup."""
import os
import pathlib
import re
import sys
import tempfile

KINDS = ("BACKEND", "FRONTEND", "DATABASE")

def pins(text):
    result = {}
    for line in text.splitlines():
        match = re.fullmatch(r"\s*(?:export\s+)?(BACKEND_IMAGE|FRONTEND_IMAGE|DATABASE_IMAGE)\s*=\s*(.*?)\s*", line)
        if match:
            key, value = match.groups()
            if key in result:
                raise ValueError(f"Duplicate {key}; review the image overrides before upgrading")
            if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
                value = value[1:-1]
            result[key] = value
    return result


def upgrade(path, example):
    if path.is_symlink() or not path.is_file():
        raise ValueError("Compose .env must be a regular file")
    with path.open(newline="") as stream:
        original = stream.read()
    current, target = pins(original), pins(example.read_text())
    for kind in KINDS:
        key = kind + "_IMAGE"
        pattern = rf"ghcr\.io/noves-inc/noves-canton-{kind.lower()}-v4:4\.[0-9]+\.[0-9]+@sha256:[a-f0-9]{{64}}"
        if not re.fullmatch(pattern, target.get(key, "")):
            raise ValueError(f"Release example has no official digest pin for {key}")
        if key in current and not re.fullmatch(pattern, current[key]):
            raise ValueError(f"Custom {key} override: review it and set the release pin before rerunning")
    lines = original.splitlines(keepends=True)
    for i, line in enumerate(lines):
        match = re.match(r"\s*(?:export\s+)?(BACKEND_IMAGE|FRONTEND_IMAGE|DATABASE_IMAGE)\s*=", line)
        if match:
            lines[i] = match[1] + "=" + target[match[1]] + "\n"
    rewritten = "".join(lines)
    for key, value in target.items():
        if key not in current:
            rewritten += ("" if rewritten.endswith("\n") or not rewritten else "\n") + key + "=" + value + "\n"
    if rewritten == original:
        return
    backup_fd, backup = tempfile.mkstemp(prefix=".env.pre-image-upgrade.", dir=path.parent)
    with os.fdopen(backup_fd, "w") as stream:
        stream.write(original)
    fd, temporary = tempfile.mkstemp(prefix=".env.image-upgrade.", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as stream:
            stream.write(rewritten)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    print(f"Updated the three release image pins; retained configuration backup: {backup}")

if __name__ == "__main__":
    try:
        upgrade(pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]))
    except (ValueError, OSError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
