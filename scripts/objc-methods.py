#!/usr/bin/env python3
"""Reads `otool -oV` from stdin and prints the Objective-C methods whose class or selector matches a
regex, one per line as -[Class selector] (+ for class methods).

  otool -oV Spotify | scripts/objc-methods.py 'playWithContext|Collection'
"""
import re
import sys

pattern = re.compile(sys.argv[1])
class_line = re.compile(r"^[0-9a-f]+ 0x[0-9a-f]+ _OBJC_(?:CLASS|METACLASS)_\$_(\S+)")
category_line = re.compile(r"^[0-9a-f]+ 0x[0-9a-f]+ _OBJC_\$_CATEGORY_(\S+?)_\$_")
name_line = re.compile(r"^\s+name\s+0x[0-9a-f]+\s+(\S+)\s*$")
cls, meta, in_methods, seen = None, False, False, set()
for line in sys.stdin:
    m = class_line.match(line)
    if m:
        cls, meta, in_methods = m.group(1), "METACLASS" in line, False
        continue
    m = category_line.match(line)
    if m:
        cls, meta, in_methods = m.group(1) + "(category)", False, False
        continue
    stripped = line.strip()
    if stripped.startswith("Meta Class"):
        meta, in_methods = True, False
        continue
    if stripped.startswith(("baseMethods", "instanceMethods", "classMethods")):
        in_methods = True
        if stripped.startswith("classMethods"):
            meta = True
        elif stripped.startswith("instanceMethods"):
            meta = False
        continue
    if stripped.startswith(("baseProtocols", "ivars", "baseProperties", "instanceProperties", "weakIvarLayout", "protocols")):
        in_methods = False
        continue
    m = name_line.match(line)
    if not m or not cls:
        continue
    if not in_methods:
        # The class_ro_t's own name names the class (Swift classes' mangled names become readable here).
        if line.startswith("        name") and not line.startswith("         "):
            cls = m.group(1)
        continue
    selector = m.group(1)
    entry = f"{'+' if meta else '-'}[{cls} {selector}]"
    if entry not in seen and (pattern.search(cls) or pattern.search(selector)):
        seen.add(entry)
        print(entry)
