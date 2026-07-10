#!/bin/bash
# swift test hangs when run unattended: each rebuilt unsigned test binary
# triggers a securityd keychain-consent prompt (CookieVault uses the login
# keychain). Run the suite against a throwaway default keychain instead.
set -euo pipefail
cd "$(dirname "$0")/.."

KEYCHAIN="${TMPDIR:-/tmp}/flextimer-tests-$$.keychain-db"
ORIGINAL_LIST=$(security list-keychains -d user | sed 's/^ *"//;s/"$//')
ORIGINAL_DEFAULT=$(security default-keychain -d user | sed 's/^ *"//;s/"$//')

cleanup() {
  # shellcheck disable=SC2086
  security list-keychains -d user -s $ORIGINAL_LIST
  security default-keychain -d user -s "$ORIGINAL_DEFAULT"
  security delete-keychain "$KEYCHAIN" 2>/dev/null || true
}
trap cleanup EXIT

security create-keychain -p tests "$KEYCHAIN"
security unlock-keychain -p tests "$KEYCHAIN"
# Temp keychain must be BOTH first in the search list and the default:
# SecItemAdd writes to the default while SecItemCopyMatching searches the list.
# shellcheck disable=SC2086
security list-keychains -d user -s "$KEYCHAIN" $ORIGINAL_LIST
security default-keychain -d user -s "$KEYCHAIN"

swift test "$@"
