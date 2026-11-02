#!/bin/zsh
# Build StampLab (formerly OverlayLens) and deploy to /Applications, then relaunch from there.
# ALWAYS use this instead of `open build/.../StampLab.app` — launching from
# the build folder leaves /Applications stale, and the next login/Desktop
# launch silently runs the old version.
set -e -o pipefail
cd "$(dirname "$0")"

# Logic tests first (Tests/Package.swift) — a failure stops the deploy before
# anything is built or the running app is touched.
mkdir -p build
# Test build output lives outside Desktop too: iCloud tags Tests/.build and
# codesign then refuses the test bundle ("resource fork, Finder information").
if ! swift test --package-path Tests --scratch-path "$HOME/Library/Caches/StampLab-tests" > build/logic-tests.log 2>&1; then
  grep -E "✘|error:" build/logic-tests.log || tail -20 build/logic-tests.log
  echo "Logic tests failed — not deploying (full log: build/logic-tests.log)"
  exit 1
fi
grep -E "Test run with" build/logic-tests.log

# Xcode output goes outside the project: Desktop is synced by iCloud, which
# tags the built .app with FinderInfo and codesign then refuses it
# ("resource fork, Finder information, or similar detritus not allowed").
DERIVED="$HOME/Library/Caches/StampLab-build"

# Release: optimized, no debug dylib. Signed with the same Apple Development
# identity as Debug, so Screen Recording / Microphone permissions carry over.
xcodebuild -project OverlayLens.xcodeproj -scheme OverlayLens \
  -configuration Release -derivedDataPath "$DERIVED" build |
  grep -E "^\*\* BUILD|error:"

# Claude Code hook helpers: ambient screen state (Tools/ambient-hook) and
# Allow / Deny from StampLab (Tools/approval-hook). Both share ClaudeApproval.swift.
HOOK_DIR="$HOME/Library/Application Support/StampLab"
mkdir -p "$HOOK_DIR"
swiftc -O Tools/ambient-hook/main.swift OverlayLens/ClaudeApproval.swift OverlayLens/QuotaReset.swift -o "$HOOK_DIR/ambient-hook"
swiftc -O Tools/approval-hook/main.swift OverlayLens/ClaudeApproval.swift OverlayLens/ClaudeAutopilot.swift -o "$HOOK_DIR/approval-hook"
# กะดึก Finish Engine: the night chat's helper and its UserPromptSubmit gate.
swiftc -O Tools/nightshift/main.swift OverlayLens/NightShiftLogic.swift OverlayLens/FinishEngineLogic.swift -o "$HOOK_DIR/nightshift-cli"

# The app was renamed OverlayLens -> StampLab; stop either name.
pkill -x StampLab 2>/dev/null || true
pkill -x OverlayLens 2>/dev/null || true
sleep 1
pkill -9 -x StampLab 2>/dev/null || true
pkill -9 -x OverlayLens 2>/dev/null || true

# Copy to a fresh bundle and swap it in. Copying over the old one would leave
# stale files behind (e.g. the Debug build's StampLab.debug.dylib) and break
# the code signature.
rm -rf /Applications/StampLab.app.new
ditto --norsrc "$DERIVED/Build/Products/Release/StampLab.app" /Applications/StampLab.app.new
codesign --verify --deep --strict /Applications/StampLab.app.new
rm -rf /Applications/StampLab.app
mv /Applications/StampLab.app.new /Applications/StampLab.app
open /Applications/StampLab.app

echo "Deployed build $(defaults read /Applications/StampLab.app/Contents/Info.plist CFBundleVersion)"
