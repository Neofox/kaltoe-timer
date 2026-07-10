#!/bin/bash
# Installs 칼퇴타이머 for the current user and registers autostart.
set -euo pipefail
cd "$(dirname "$0")"

DEST="$HOME/.local/share/kaltoe-timer"
mkdir -p "$DEST/icons" "$HOME/.config/autostart"
cp kaltoe-core kaltoe-tray.py README-linux.md "$DEST/"
cp icons/*.svg "$DEST/icons/"
chmod +x "$DEST/kaltoe-core" "$DEST/kaltoe-tray.py"

cat > "$HOME/.config/autostart/kaltoe-timer.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=칼퇴타이머
Comment=Work-hours tray timer for flex.team
Exec=$DEST/kaltoe-tray.py
X-GNOME-Autostart-enabled=true
EOF

echo "Installed to $DEST (autostarts at login)."
echo "Start it now with:  $DEST/kaltoe-tray.py &"
