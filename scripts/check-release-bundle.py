#!/usr/bin/env python3
"""Bind the manifest and image smoke test to the committed, pushed chart and Compose pins."""
import os
import pathlib
import re
import subprocess
import sys
import yaml
from importlib.util import spec_from_file_location, module_from_spec

ROOT = pathlib.Path(__file__).resolve().parents[1]
_spec = spec_from_file_location("compose_images", ROOT / "scripts/upgrade-compose-images.py")
_images = module_from_spec(_spec)
_spec.loader.exec_module(_images)
FILES = ("chart/noves-canton-data-app/Chart.yaml", "chart/noves-canton-data-app/values.yaml",
         "docker-compose/compose.yaml", "docker-compose/.env.example")


def check(root, inputs):
    version = inputs["RELEASE_VERSION"]
    chart = yaml.safe_load((root / FILES[0]).read_text())
    if str(chart["version"]) != version or str(chart["appVersion"]) != version:
        raise ValueError("Chart version/appVersion must match RELEASE_VERSION")
    values = yaml.safe_load((root / FILES[1]).read_text())
    compose = yaml.safe_load((root / FILES[2]).read_text())
    pins = _images.pins((root / FILES[3]).read_text())
    for component in ("backend", "frontend", "database"):
        prefix = component.upper()
        repo, digest = inputs[prefix + "_REPOSITORY"], inputs[prefix + "_DIGEST"]
        if not re.fullmatch(r"sha256:[a-f0-9]{64}", digest):
            raise ValueError(f"{component}: a full sha256 digest is required")
        image = values[component]["image"]
        if (image["repository"], str(image["tag"]), image["digest"]) != (repo, version, digest):
            raise ValueError(f"{component}: chart pin differs from release inputs")
        expected = f"{repo}:{version}@{digest}"
        if pins.get(prefix + "_IMAGE") != expected:
            raise ValueError(f"{component}: Compose example pin differs from release inputs")
        if compose["services"][component]["image"] != "${" + prefix + "_IMAGE:-" + expected + "}":
            raise ValueError(f"{component}: Compose default differs from release inputs")


def check_source(root, commit):
    if not re.fullmatch(r"[a-f0-9]{40}", commit):
        raise ValueError("CHART_SOURCE_COMMIT must be the full committed bundle SHA")
    head = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()
    if head != commit:
        raise ValueError("Run from the CHART_SOURCE_COMMIT checkout")
    for name in FILES:
        recorded = subprocess.check_output(["git", "show", f"{commit}:{name}"], cwd=root)
        if recorded != (root / name).read_bytes():
            raise ValueError(f"Uncommitted bundle file: {name}")
    remote = subprocess.check_output(["git", "ls-remote", "origin", "refs/heads/master"], cwd=root, text=True).split()
    if not remote or remote[0] != commit:
        raise ValueError("Push the bundle commit to origin/master before creating release assets")


if __name__ == "__main__":
    try:
        check(ROOT, os.environ)
        check_source(ROOT, os.environ["CHART_SOURCE_COMMIT"])
        print("Committed chart and Compose pins match the release inputs")
    except (KeyError, ValueError, OSError, subprocess.CalledProcessError) as error:
        print(f"Release bundle check failed: {error}", file=sys.stderr)
        sys.exit(1)
