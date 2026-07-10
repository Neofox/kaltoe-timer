#!/bin/bash
# Generates the Linux tray icon SVGs (3 glyphs × 3 urgency colors) into linux/icons/.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=linux/icons
mkdir -p "$OUT"

emit() { # $1=file-basename $2=stroke-color $3=glyph-body
  cat > "$OUT/$1.svg" <<EOF
<svg xmlns="http://www.w3.org/2000/svg" width="22" height="22" viewBox="0 0 22 22">
<g fill="none" stroke="$2" stroke-width="1.8" stroke-linecap="round">
$3
</g>
</svg>
EOF
}

TIMER='<circle cx="11" cy="12.5" r="6.5"/><path d="M11 12.5V9"/><path d="M9 2.5h4"/><path d="M11 2.5v3"/>'
FORK='<path d="M7 3v5"/><path d="M10 3v5"/><path d="M13 3v5"/><path d="M7 8a3 3 0 0 0 6 0"/><path d="M10 11v8"/>'
CUP='<path d="M5 7h10v5a5 5 0 0 1-10 0z"/><path d="M15 8h1.5a2.5 2.5 0 0 1 0 5H15"/><path d="M5 19h12"/>'

for pair in "timer|$TIMER" "fork|$FORK" "cup|$CUP"; do
  glyph="${pair%%|*}" body="${pair#*|}"
  emit "kaltoe-$glyph"          "#dfdfdf" "$body"
  emit "kaltoe-$glyph-warning"  "#ff9500" "$body"
  emit "kaltoe-$glyph-critical" "#ff3b30" "$body"
done
echo "Wrote 9 SVGs to $OUT"
