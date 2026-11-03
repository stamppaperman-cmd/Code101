#!/bin/zsh
# Build EchoNote and deploy to /Applications, then relaunch from there.
# ALWAYS use this instead of `open build/.../EchoNote.app` — launching from
# the build folder leaves /Applications stale, and the next login/Desktop
# launch silently runs the old version.
set -e -o pipefail
cd "$(dirname "$0")"

# Deploying kills the running app. Four in-flight jobs were lost that way in one
# session, roughly 40 minutes of compute each, because the check was "remember to
# look at job.json first" and nobody remembers. Now it is the script's job.
# Only a *running* app can lose work. A job left as "transcribing" by an app that is
# already gone is stale state waiting for JobStore to repair it on next launch, and
# blocking on that would train everyone to type --force.
JOBS="$HOME/Library/Application Support/EchoNote/jobs"
if [[ -d "$JOBS" ]] && pgrep -x EchoNote >/dev/null; then
  RUNNING=$(grep -l '"status" *: *"\(decoding\|transcribing\|summarizing\)"' "$JOBS"/*/job.json 2>/dev/null || true)
  if [[ -n "$RUNNING" ]]; then
    echo "งานกำลังรันอยู่ — deploy จะฆ่าแอปและทำให้เสียงานนี้:"
    for f in ${(f)RUNNING}; do
      /usr/bin/python3 -c "
import json,sys
j=json.load(open(sys.argv[1]))
print('  %-28s %s  %s  %d%%' % (j.get('filename','?')[:28], j.get('status'), j.get('currentStage') or '-', round(j.get('progress',0)*100)))
" "$f" 2>/dev/null || echo "  $f"
    done
    if [[ "$1" != "--force" ]]; then
      echo
      echo "รอให้จบก่อน หรือสั่ง ./deploy.sh --force ถ้ายอมทิ้งงานเหล่านี้"
      exit 1
    fi
    echo "--force: ทิ้งงานข้างบนแล้ว deploy ต่อ"
  fi
fi

xcodebuild -project EchoNote.xcodeproj -scheme EchoNote \
  -configuration Debug -derivedDataPath build build |
  grep -E "^\*\* BUILD|error:"

pkill -x EchoNote 2>/dev/null || true
sleep 1
pkill -9 -x EchoNote 2>/dev/null || true

ditto --rsrc build/Build/Products/Debug/EchoNote.app /Applications/EchoNote.app
open /Applications/EchoNote.app

echo "Deployed build $(defaults read /Applications/EchoNote.app/Contents/Info.plist CFBundleVersion)"
