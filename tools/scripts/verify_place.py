#!/usr/bin/env python3
"""
Verifies the built .rbxlx place file structurally.

This is the substitute for a Studio playtest, which cannot run on Linux:
it proves the shipped artifact actually contains the services, systems and
scripts we wrote, and that every ModuleScript has non-empty source.
"""
import sys
import xml.etree.ElementTree as ET

path = sys.argv[1] if len(sys.argv) > 1 else "build/ZombieUprising.rbxlx"

REQUIRED_SERVICES = ["ServerScriptService", "ReplicatedStorage", "StarterPlayer"]
REQUIRED_MODULES = [
    "Config", "Remotes", "Types", "RNG", "MathUtil", "MapBuilder",
]

try:
    tree = ET.parse(path)
except Exception as e:
    print(f"FAIL: cannot parse {path}: {e}")
    sys.exit(1)

root = tree.getroot()

def iter_items(node):
    for child in node.findall("Item"):
        yield child
        yield from iter_items(child)

items = list(iter_items(root))
if not items:
    print("FAIL: no instances in place file")
    sys.exit(1)

classes = {}
names = {}
sources = {}

for it in items:
    cls = it.get("class", "")
    classes[cls] = classes.get(cls, 0) + 1
    props = it.find("Properties")
    if props is None:
        continue
    for sp in props:
        if sp.tag == "string" and sp.get("name") == "Name":
            names[sp.text or ""] = names.get(sp.text or "", 0) + 1
        elif sp.tag in ("ProtectedString", "string") and sp.get("name") == "Source":
            n = None
            for sp2 in props:
                if sp2.tag == "string" and sp2.get("name") == "Name":
                    n = sp2.text
                    break
            if n:
                sources[n] = sp.text or ""

failures = []

for svc in REQUIRED_SERVICES:
    if svc not in classes:
        failures.append(f"missing service {svc}")

for mod in REQUIRED_MODULES:
    if mod not in names:
        failures.append(f"missing module {mod}")
    elif sources.get(mod, "").strip() == "":
        failures.append(f"module {mod} has empty source")

# Every ModuleScript must carry source
empty = [n for n, s in sources.items() if not s.strip()]
if empty:
    failures.append(f"ModuleScripts with empty source: {empty}")

if failures:
    print("PLACE VERIFICATION FAILED:")
    for f in failures:
        print("  -", f)
    sys.exit(1)

print(
    f"place OK: {len(items)} instances, "
    f"services={sorted(set(REQUIRED_SERVICES) & set(classes))}, "
    f"modules={len(sources)} with source"
)
