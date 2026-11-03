#!/bin/zsh
# Build Drop Shelf.app (Apple silicon + Intel) and package it as a .dmg
# that can be sent to someone else.
#   ./build.sh          → dist/DropShelf.dmg
set -e -o pipefail
cd "$(dirname "$0")"

VERSION="1.1"
BUILD="$(date +%Y%m%d.%H%M)"
MIN_OS="14.0"

# This project folder lives on the iCloud-synced Desktop, and the file
# provider keeps re-adding com.apple.FinderInfo to anything inside it —
# which codesign refuses, and which breaks the signature right after it is
# applied. So the bundle is built, signed and packaged in a temp folder
# outside the synced tree; only the finished .dmg comes back here.
WORK="$(mktemp -d "${TMPDIR:-/tmp}/dropshelf-build.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
APP="$WORK/Drop Shelf.app"

rm -rf dist
mkdir -p dist

echo "→ compile"
for arch in arm64 x86_64; do
  swiftc -swift-version 5 -O -parse-as-library \
    -target "$arch-apple-macos$MIN_OS" \
    Sources/*.swift -o "$WORK/DropShelf-$arch"
done

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create "$WORK/DropShelf-arm64" "$WORK/DropShelf-x86_64" -output "$APP/Contents/MacOS/DropShelf"

echo "→ icon"
swift Tools/make_icon.swift "$WORK/AppIcon.iconset"
iconutil -c icns "$WORK/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key><string>th</string>
	<key>CFBundleExecutable</key><string>DropShelf</string>
	<key>CFBundleIconFile</key><string>AppIcon</string>
	<key>CFBundleIdentifier</key><string>com.stamp.dropshelf</string>
	<key>CFBundleName</key><string>Drop Shelf</string>
	<key>CFBundleDisplayName</key><string>Drop Shelf</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>$VERSION</string>
	<key>CFBundleVersion</key><string>$BUILD</string>
	<key>LSMinimumSystemVersion</key><string>$MIN_OS</string>
	<key>LSUIElement</key><true/>
	<key>NSPrincipalClass</key><string>NSApplication</string>
	<key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

echo "→ sign (ad-hoc)"
xattr -cr "$APP"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"

echo "→ dmg"
STAGE="$WORK/dmg"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Drop Shelf.app"
ln -s /Applications "$STAGE/Applications"
cp "วิธีติดตั้ง.txt" "$STAGE/"
xattr -cr "$STAGE/วิธีติดตั้ง.txt"
hdiutil create -volname "Drop Shelf" -srcfolder "$STAGE" -ov -format UDZO "$WORK/DropShelf.dmg" >/dev/null
cp "$WORK/DropShelf.dmg" dist/DropShelf.dmg
xattr -c dist/DropShelf.dmg

echo "→ verify (ตรวจแอปที่อยู่ใน dmg จริง)"
MNT="$(mktemp -d "${TMPDIR:-/tmp}/dropshelf-verify.XXXXXX")"
hdiutil attach dist/DropShelf.dmg -mountpoint "$MNT" -nobrowse -quiet
codesign --verify --deep --strict --verbose=2 "$MNT/Drop Shelf.app"
lipo -archs "$MNT/Drop Shelf.app/Contents/MacOS/DropShelf"
hdiutil detach "$MNT" -quiet
rmdir "$MNT"

echo "Built Drop Shelf $VERSION ($BUILD) → dist/DropShelf.dmg"
