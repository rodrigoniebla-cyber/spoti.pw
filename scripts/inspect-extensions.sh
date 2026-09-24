#!/usr/bin/env bash
# Prints what each of Spotify's app extensions is and what it reaches for: its NSExtension keys, its
# entitlements as Spotify signed it, where it looks for dylibs, what it links, and the app group, keychain
# and account strings in its code. It is how a sideload problem of an extension (Siri's "verify your
# account details") is looked at without a Mac of one's own: run it in CI and read the log.
#
#   scripts/inspect-extensions.sh <decrypted.ipa>
set -uo pipefail
IN="${1:?usage: $0 <ipa>}"
WORK="$(mktemp -d)"
unzip -q "$IN" -d "$WORK"
APP="$(ls -d "$WORK"/Payload/*.app | head -1)"

section() { printf '\n======== %s ========\n' "$*"; }
ents() { codesign -d --entitlements - --xml "$1" 2>/dev/null | plutil -p - 2>/dev/null || ldid -e "$1" 2>/dev/null; }
interesting='group\.|keychain|[Aa]ccess[Gg]roup|kSecAttr|suiteName|[Ss]iri|INPlayMedia|INMedia|INAddMedia|INSearchForMedia|[Ll]ogged|[Ll]ogin|[Cc]redential|[Uu]sername|[Aa]ccessToken|[Rr]efreshToken|[Aa]uth|[Vv]erify|[Aa]ccount|handleInApp|HandleInApp|NotSubscribed|RequiringAppLaunch|com\.spotify'

section "app"
plutil -p "$APP/Info.plist" | grep -iE 'CFBundleIdentifier|CFBundleExecutable|INIntents|NSUserActivityTypes|Siri|AppGroup|Keychain' || true
section "app entitlements"
ents "$APP/$(plutil -extract CFBundleExecutable raw -o - "$APP/Info.plist")"
section "frameworks"
ls "$APP/Frameworks" 2>/dev/null

for APPEX in "$APP"/PlugIns/*.appex; do
  NAME="$(basename "$APPEX" .appex)"
  EXEC="$(plutil -extract CFBundleExecutable raw -o - "$APPEX/Info.plist" 2>/dev/null || echo "$NAME")"
  BIN="$APPEX/$EXEC"
  section "$NAME: Info.plist"
  plutil -p "$APPEX/Info.plist"
  section "$NAME: entitlements"
  ents "$BIN"
  section "$NAME: rpaths and linked libraries"
  otool -l "$BIN" | grep -A2 LC_RPATH | grep path || true
  otool -L "$BIN" | grep -v '/usr/lib\|/System/Library' || true
  section "$NAME: contents"
  ls -la "$APPEX"
  section "$NAME: strings"
  strings -a "$BIN" | grep -E "$interesting" | sort -u | head -400
  section "$NAME: Objective-C and Swift classes"
  { otool -oV "$BIN" 2>/dev/null | grep -E '^\s+name 0x[0-9a-f]+ ' | awk '{print $3}'; nm -gU "$BIN" 2>/dev/null | grep -oE '_OBJC_CLASS_\$_[A-Za-z0-9_]+' | sed 's/_OBJC_CLASS_\$_//'; } | sort -u | grep -iE 'intent|siri|auth|login|session|account|keychain|credential|group|handler' | head -200
done

# Spotify keeps much of its code in frameworks the extensions link; their own group and keychain
# strings say where the shared login lives.
for FW in "$APP"/Frameworks/*.framework; do
  B="$FW/$(basename "$FW" .framework)"
  [ -f "$B" ] || continue
  HITS="$(strings -a "$B" | grep -E 'group\.com\.spotify|keychain-access|[Aa]ccessGroup|com\.spotify\.[a-z.]*(shared|siri|intent|keychain|credentials)' | sort -u | head -80)"
  [ -n "$HITS" ] && { section "framework $(basename "$FW"): group and keychain strings"; echo "$HITS"; }
done

section "main binary: group, keychain and Siri strings"
strings -a "$APP/$(plutil -extract CFBundleExecutable raw -o - "$APP/Info.plist")" | grep -E 'group\.com\.spotify|[Aa]ccessGroup|keychain|INPlayMediaIntent|handleIntent|handlerForIntent|IntentsExtension|siri' | sort -u | head -200
rm -rf "$WORK"
exit 0
