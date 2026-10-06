#!/usr/bin/env python3
"""Refuse shell/environment image overrides before pulling or stopping containers."""
import json
import pathlib
import sys
from importlib.util import spec_from_file_location, module_from_spec
spec = spec_from_file_location("images", pathlib.Path(__file__).with_name("upgrade-compose-images.py"))
images = module_from_spec(spec)
spec.loader.exec_module(images)
try:
    pins = images.pins(pathlib.Path(sys.argv[1]).read_text())
    config = json.load(sys.stdin)
    for kind in images.KINDS:
        if config["services"][kind.lower()]["image"] != pins[kind + "_IMAGE"]:
            raise ValueError(f"Resolved {kind}_IMAGE differs from the chosen release; remove the shell/environment override")
except (ValueError, KeyError, OSError) as error:
    print(error, file=sys.stderr)
    sys.exit(1)
