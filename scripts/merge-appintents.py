#!/usr/bin/env python3
"""Adds a Metadata.appintents to the app's own inside an IPA, in place.

  scripts/merge-appintents.py <ipa> <Payload/X.app/> <Metadata.appintents dir>

The system looks an intent up in the metadata of the bundle that runs it, and a LiveActivityIntent
runs in the app, so the widget's intents have to be listed in Spotify's file next to its own. So do
the speed and pitch presets' intents, their entity and its query, and the phrases Siri knows them by.

Tables keyed by name (actions, entities, queries) are joined, lists (enums, autoShortcuts...) run on,
and anything else Spotify's file lacks is taken from ours: the App Shortcuts provider's name, of which
an app has one, and Spotify declares none.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import zipfile

ipa, app_dir, ours = sys.argv[1:4]
member = f"{app_dir}Metadata.appintents/extract.actionsdata"
version = f"{app_dir}Metadata.appintents/version.json"

with zipfile.ZipFile(ipa) as z:
    theirs = json.loads(z.read(member)) if member in z.namelist() else None
with open(os.path.join(ours, "extract.actionsdata")) as f:
    added = json.load(f)

def merge(theirs, ours):
    out = dict(theirs)
    for key, value in ours.items():
        mine = out.get(key)
        if isinstance(value, dict) and isinstance(mine, dict) and key != "generator":
            out[key] = {**mine, **value}
        elif isinstance(value, list) and isinstance(mine, list):
            out[key] = mine + [item for item in value if item not in mine]
        elif mine in (None, "", [], {}):
            out[key] = value
        elif key not in ("generator", "version", "shortcutTileColor") and mine != value:
            print(f"    {key}: Spotify's value kept over ours")
    return out

merged = added if theirs is None else merge(theirs, added)

with tempfile.TemporaryDirectory() as tmp:
    os.makedirs(os.path.join(tmp, os.path.dirname(member)))
    with open(os.path.join(tmp, member), "w") as f:
        json.dump(merged, f)
    entries = [member]
    if theirs is None:
        shutil.copy(os.path.join(ours, "version.json"), os.path.join(tmp, version))
        entries.append(version)
    subprocess.run(["zip", "-q", os.path.abspath(ipa), *entries], cwd=tmp, check=True)

print(f"    {len(added.get('actions', {}))} actions, {len(added.get('entities', {}))} entities and "
      f"{len(added.get('autoShortcuts', []))} App Shortcuts added to the app's "
      f"{len((theirs or {}).get('actions', {}))} actions")
