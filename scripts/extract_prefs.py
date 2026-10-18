"""Extract preference sections/options from Aseprite's data/pref.xml.

Usage: python -I scripts/extract_prefs.py <aseprite-src-dir> <out.json>
Output: {"section": {"option": "type = default", ...}, ...}
Sections under <tool> and <document> are prefixed with "tool." / "document.".
"""

import json
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

root = ET.parse(Path(sys.argv[1]) / "data" / "pref.xml").getroot()
out = {}


def walk(section, prefix):
    for child in section:
        if child.tag == "section":
            name = prefix + child.get("id")
            opts = {}
            for opt in child:
                if opt.tag == "option":
                    desc = opt.get("type", "")
                    if opt.get("default") is not None:
                        desc += " = " + opt.get("default")
                    opts[opt.get("id")] = desc
            if opts:
                out[name] = opts
            walk(child, name + ".")


for top in root:
    if top.tag == "global":
        walk(top, "")
    elif top.tag in ("tool", "document"):
        walk(top, top.tag + ".")

Path(sys.argv[2]).write_text(json.dumps(out, indent=1), encoding="utf-8")
print(f"{len(out)} sections -> {sys.argv[2]}")
