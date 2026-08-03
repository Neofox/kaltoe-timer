#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP=build/칼퇴타이머.app
rm -rf "$APP" build/FlexTimer.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/FlexTimer "$APP/Contents/MacOS/FlexTimer"
cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>칼퇴타이머</string>
  <key>CFBundleDisplayName</key><string>칼퇴타이머</string>
  <key>CFBundleIdentifier</key><string>com.perso.flextimer</string>
  <key>CFBundleExecutable</key><string>FlexTimer</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>2.2.0</string>
  <key>CFBundleVersion</key><string>2.2.0</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF

# Sign with the stable self-signed identity when present (see README:
# "Code signing"); ad-hoc otherwise. Ad-hoc identities change every build,
# which makes the Keychain re-prompt for the session item after each upgrade.
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep -o '"kaltoe-dev"' | head -1 || true)
if [ -n "$IDENTITY" ]; then
  codesign --force -s kaltoe-dev "$APP"
  echo "Signed with kaltoe-dev (stable identity — keychain 항상 허용 survives rebuilds)."
else
  codesign --force -s - "$APP"
  echo "WARNING: ad-hoc signed — keychain will re-prompt after every rebuild."
  echo "Create the one-time 'kaltoe-dev' certificate (README: Code signing) to fix."
fi
echo "Built $APP — copy to /Applications (adds itself to Login Items on first launch)."
