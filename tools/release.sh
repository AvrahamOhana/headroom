#!/bin/zsh
# Archive the iOS app (Release) and upload it to App Store Connect.
#   tools/release.sh            # archive + upload (needs an Apple Developer Program team + an ASC app record)
#   tools/release.sh archive    # archive only → build/Headroom.xcarchive (validate the release build)
# Signing is automatic; Xcode must be signed in to the Apple ID that owns team L825F6VFVF
# (Xcode → Settings → Accounts), or pass -authenticationKeyPath/-authenticationKeyID/-authenticationKeyIssuerID
# for an App Store Connect API key.
set -e
cd "$(dirname "$0")/.."
ARCHIVE=build/Headroom.xcarchive
echo "=== ARCHIVE (Release, iOS) ==="
xcodebuild archive -project NamRig/NamRig.xcodeproj -scheme NamRig -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" -allowProvisioningUpdates -quiet
echo "archive: $ARCHIVE"
plutil -p "$ARCHIVE/Products/Applications/Headroom.app/Info.plist" | grep -E "CFBundleIdentifier|CFBundleShortVersionString|CFBundleVersion|MinimumOSVersion"
[ "$1" = "archive" ] && exit 0
echo "=== UPLOAD to App Store Connect ==="
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist tools/ExportOptions.plist \
  -exportPath build/export -allowProvisioningUpdates
echo "=== uploaded — processing takes ~10–30 min, then the build appears in App Store Connect → TestFlight ==="
