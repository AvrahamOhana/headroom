#!/bin/zsh
# Headroom build + install + launch to a paired iPhone.
# Usage: tools/deploy.sh ["ExcludedFile.swift ..."]   (optional EXCLUDED_SOURCE_FILE_NAMES)
#
# Gotchas baked in (learned the hard way — see HANDOFF.md):
#   * The freshly-signed product is ONLY at Build/Products/Debug-iphoneos/NamRig.app.
#     Skip the Index.noindex artifact (no valid CFBundleIdentifier) AND the transient
#     .XCInstall/Wrapper copy (has an executable but can be STALE from a prior deploy).
#   * Launch with --terminate-existing or a running app gives "prevent launch" (RBS error 7).
set -e
DEV=${DEV:?set DEV=<device id> (find yours with: xcrun devicectl list devices)}
BID=${BID:-com.avrahamohana.Headroom}
EXCL="$1"
cd "$(dirname "$0")/.."
echo "=== BUILD ${EXCL:+(excluding: $EXCL)} ==="
xcodebuild build -project NamRig/NamRig.xcodeproj -scheme NamRig \
  -destination "id=$DEV" -allowProvisioningUpdates -quiet \
  ${EXCL:+EXCLUDED_SOURCE_FILE_NAMES="$EXCL"} 2>&1 | tail -15
APP=""
for cand in $(find ~/Library/Developer/Xcode/DerivedData -type d -name "Headroom.app" \
  -path "*Build/Products/Debug-iphoneos*" -not -path "*Index.noindex*" -not -path "*.XCInstall*"); do
  [ -f "$cand/Headroom" ] && APP="$cand" && break
done
echo "=== APP: $APP ==="
echo "=== INSTALL ==="
xcrun devicectl device install app --device $DEV "$APP" 2>&1 | grep -E "installationURL|ERROR|missing|error" | head -4
echo "=== LAUNCH ==="
xcrun devicectl device process launch --device $DEV --terminate-existing $BID 2>&1 | tail -2
echo "=== DONE ==="

# Compile-check only (no device / no signing):
#   xcodebuild build -project NamRig/NamRig.xcodeproj -scheme NamRig \
#     -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO -quiet
#   NOTE: a compile-check leaves an UNSIGNED product; always run a signed build before installing.
