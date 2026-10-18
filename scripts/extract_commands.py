"""Extract Aseprite command names and their parameters from the C++ source.

Usage: python -I scripts/extract_commands.py <aseprite-src-dir> <api-docs-dir> <out.json>
"""

import json
import re
import sys
from pathlib import Path

src = Path(sys.argv[1])
api = Path(sys.argv[2])
out = Path(sys.argv[3])

cmd_dir = src / "src" / "app" / "commands"
names = re.findall(r"FOR_EACH_COMMAND\((\w+)\)", (cmd_dir / "commands_list.h").read_text(encoding="utf-8"))

cpp_files = list(cmd_dir.rglob("*.cpp")) + list(cmd_dir.rglob("*.h"))
texts = {p: p.read_text(encoding="utf-8", errors="replace") for p in cpp_files}

param_re = re.compile(r"Param<\s*([\w:<> ]+?)\s*>\s*\w+\s*\{\s*this\s*,\s*(.*?)\s*,\s*(\{\s*\"[\w-]+\"[^}]*\}|\"[\w-]+\")", re.S)
get_re = re.compile(r"params\.(?:get|has|has_param)\(\s*\"([\w-]+)\"")
getas_re = re.compile(r"params\.(?:getAs|get_as)<\s*([\w:]+)\s*>\(\s*\"([\w-]+)\"")

# Docs: which commands require UI, plus one-line descriptions.
doc_text = (api / "app_command.md").read_text(encoding="utf-8")
ui_only = set(re.findall(r"app\.command\.(\w+)\]?[^\n]*\[\[UI\]\]", doc_text))
can_ui = set(re.findall(r"app\.command\.(\w+)\]?[^\n]*\[\[\*\]\]", doc_text))
descs = {}
for m in re.finditer(r"\* \[?app\.command\.(\w+)\]?(?:\(command/[^ )]+(?: \"([^\"]+)\")?\))?[^\n]*\n(?:\s+\* ([^\n]+))?", doc_text):
    d = m.group(2) or m.group(3)
    if d:
        descs[m.group(1)] = d.strip()


def find_file(name):
    pat = re.compile(r"create" + name + r"Command\s*\(")
    for p, t in texts.items():
        if pat.search(t) and "CommandFactory::create" + name + "Command" in t:
            return p
    return None


def struct_params(text, name):
    # Prefer the <Name>Params struct; fall back to all Param<> in the file.
    m = re.search(r"struct\s+" + name + r"Params\b.*?\n\};", text, re.S)
    body = m.group(0) if m else text
    res = []
    for t, default, ids in param_re.findall(body):
        default = " ".join(default.split())
        names_ = re.findall(r"\"([\w-]+)\"", ids)
        entry = {"name": names_[0], "type": t.strip(), "default": default}
        if len(names_) > 1:
            entry["aliases"] = names_[1:]
        res.append(entry)
    return res


commands = []
for name in names:
    p = find_file(name)
    params = []
    if p is not None:
        text = texts[p]
        header = p.with_suffix(".h")
        if header in texts:
            text = texts[header] + "\n" + text
        if "MoveThing" in text:
            text += "\n" + texts[cmd_dir / "move_thing.cpp"]
        params = struct_params(text, name)
        seen = {x["name"] for x in params}
        for t, pid in getas_re.findall(text):
            if pid not in seen:
                params.append({"name": pid, "type": t})
                seen.add(pid)
        for pid in get_re.findall(text):
            if pid not in seen:
                params.append({"name": pid, "type": "string"})
                seen.add(pid)
    entry = {"name": name, "params": params}
    if p is not None:
        entry["source"] = p.relative_to(src).as_posix()
    if name in ui_only:
        entry["requiresUI"] = True
    if name in can_ui:
        entry["hasUiParam"] = True
    if name in descs:
        entry["description"] = descs[name]
    commands.append(entry)

out.write_text(json.dumps(commands, indent=1), encoding="utf-8")
print(f"{len(commands)} commands, {sum(1 for c in commands if c['params'])} with params -> {out}")
