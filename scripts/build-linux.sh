#!/bin/bash
# Builds kaltoe-core for x86_64 Linux in Docker and assembles the
# distributable tarball. Requires Docker (OrbStack/colima work).
set -euo pipefail
cd "$(dirname "$0")/.."

IMAGE=swift:6.1-noble
docker run --rm --platform linux/amd64 -v "$PWD":/src -w /src -e HOME=/tmp \
  "$IMAGE" swift build -c release --product kaltoe-core --static-swift-stdlib \
  --scratch-path .build-linux

# NOTE: if you need to rerun the test suite inside this Docker image, pass
# -e TZ=Asia/Seoul — ~30 date-sensitive tests shift under the container's default
# UTC (build and daemon are unaffected). Example:
#   docker run --rm --platform linux/amd64 -v "$PWD":/src -w /src -e HOME=/tmp \
#     -e TZ=Asia/Seoul "$IMAGE" swift test --scratch-path .build-linux

OUT=build/kaltoe-timer-linux
rm -rf "$OUT"
mkdir -p "$OUT/icons"
cp .build-linux/release/kaltoe-core "$OUT/"
cp linux/kaltoe-tray.py linux/install.sh linux/README-linux.md "$OUT/"
cp linux/icons/*.svg "$OUT/icons/"
chmod +x "$OUT/kaltoe-core" "$OUT/kaltoe-tray.py" "$OUT/install.sh"

tar -C build -czf build/kaltoe-timer-linux-x86_64.tar.gz kaltoe-timer-linux
echo "Built build/kaltoe-timer-linux-x86_64.tar.gz"
