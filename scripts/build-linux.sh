#!/bin/bash
# Builds kaltoe-core for x86_64 Linux in Docker and assembles the
# distributable tarball. Requires Docker (OrbStack/colima work).
set -euo pipefail
cd "$(dirname "$0")/.."

IMAGE=swift:6.3-noble
docker run --rm --platform linux/amd64 -v "$PWD":/src -w /src -e HOME=/tmp \
  "$IMAGE" swift build -c release --product kaltoe-core --static-swift-stdlib \
  --scratch-path .build-linux

# The image tracks the toolchain developers actually use, deliberately. It sat on
# 6.1-noble while local Swift moved to 6.3, and the skew hid a real break: five
# collection literals that 6.3 accepts and 6.1 rejects compiled here and failed
# there, invisibly, because this script built only the *product* and never the
# tests. If you bump local Swift, bump this too.
#
# The test run below is why that can no longer happen quietly. It is a separate
# `docker run` because `--product` and `--build-tests` conflict, so it cannot be a
# flag on the build above. TZ=Asia/Seoul is required, not cosmetic: ~30
# date-sensitive tests shift under the container's default UTC (the release build
# and the daemon itself are unaffected). SKIP_LINUX_TESTS=1 skips it for a fast
# release build — the skew it guards is real, so skip knowingly.
if [ "${SKIP_LINUX_TESTS:-0}" = 1 ]; then
  echo "SKIP_LINUX_TESTS=1 — not running the Linux test suite"
else
  docker run --rm --platform linux/amd64 -v "$PWD":/src -w /src -e HOME=/tmp \
    -e TZ=Asia/Seoul "$IMAGE" swift test --scratch-path .build-linux
fi

OUT=build/kaltoe-timer-linux
rm -rf "$OUT"
mkdir -p "$OUT/icons"
cp .build-linux/release/kaltoe-core "$OUT/"
cp linux/kaltoe-tray.py linux/kaltoe_rows.py linux/install.sh linux/README-linux.md "$OUT/"
cp linux/icons/*.svg "$OUT/icons/"
chmod +x "$OUT/kaltoe-core" "$OUT/kaltoe-tray.py" "$OUT/install.sh"

# The staging list above and install.sh's copy list have to agree, and they drifted
# once already: install.sh gained kaltoe_rows.py and this script did not, so the
# tarball shipped an installer that aborts on its own `cp` — after GNU cp has
# already copied what it could, leaving an upgraded tray with no module to import.
# So the requirement is *derived* from install.sh here rather than restated; a
# second hand-kept list is precisely the bug being guarded against. Every source
# operand of every `cp` in install.sh must resolve inside the staged directory.
missing=""
checked=0
while read -ra words; do
  last=$(( ${#words[@]} - 1 ))   # the destination operand; sources are words[1..last-1]
  for (( i = 1; i < last; i++ )); do
    src=${words[i]}
    case "$src" in -*) continue ;; esac   # a flag, not a source
    checked=$(( checked + 1 ))
    compgen -G "$OUT/$src" >/dev/null || missing="$missing  $src"$'\n'
  done
done < <(grep -E '^[[:space:]]*cp[[:space:]]' linux/install.sh)

# A guard that inspects nothing passes everything, so refuse to be a no-op: if
# install.sh stops installing with `cp`, this parse has to be rewritten, not
# quietly skipped.
if [ "$checked" -eq 0 ]; then
  echo "error: found no cp source operands in linux/install.sh — the staging guard" >&2
  echo "in scripts/build-linux.sh no longer understands it. Fix the guard." >&2
  exit 1
fi

if [ -n "$missing" ]; then
  {
    echo "error: linux/install.sh copies files that $OUT does not contain:"
    printf '%s' "$missing"
    echo "Add them to the 'cp linux/...' line in scripts/build-linux.sh and rebuild."
    echo "(Shipping the tarball without them gives users a half-applied install.)"
  } >&2
  exit 1
fi

tar -C build -czf build/kaltoe-timer-linux-x86_64.tar.gz kaltoe-timer-linux
echo "Built build/kaltoe-timer-linux-x86_64.tar.gz"
