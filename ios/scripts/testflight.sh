#!/usr/bin/env bash
#
# Archive OpenCircuit (Release) and upload to App Store Connect / TestFlight.
#
# Prereqs (one-time, see docs/TESTFLIGHT.md):
#   1. Paid Apple Developer Program active; Account Holder has accepted the latest
#      Program License Agreement in App Store Connect.
#   2. The app record must exist in App Store Connect for bundle id
#      com.deansdomain.ringpool (Ringpool). NOTE: POST /v1/apps is rejected for EVERY API key
#      role (Apple 403: apps allow GET/UPDATE, not CREATE) — create it once in the ASC web UI
#      (My Apps -> New App) or via a Transporter/Xcode Apple-ID upload. See docs/TESTFLIGHT.md.
#   3. An App Store Connect API key (Users and Access -> Integrations -> App Store Connect API):
#        - download the .p8 once,
#        - note the Key ID and Issuer ID.
#      For this account: Key ID 5D6627S3L2 (pier-admin), Issuer ID
#      69a6de72-af42-47e3-e053-5b8c7c11a4d1 (not secret without the .p8).
#
# Usage:
#   export ASC_KEY_ID=XXXXXXXXXX
#   export ASC_ISSUER_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
#   export ASC_KEY_PATH="$HOME/.appstoreconnect/private_keys/AuthKey_XXXXXXXXXX.p8"
#   ios/scripts/testflight.sh
#
# Bump CURRENT_PROJECT_VERSION in project.yml (then re-run `xcodegen generate`) before each
# upload — App Store Connect rejects a build number it has already seen.

set -euo pipefail

cd "$(dirname "$0")/.."   # -> ios/

: "${ASC_KEY_ID:?Set ASC_KEY_ID (App Store Connect API key id)}"
: "${ASC_ISSUER_ID:?Set ASC_ISSUER_ID (App Store Connect issuer id)}"
: "${ASC_KEY_PATH:?Set ASC_KEY_PATH (path to the AuthKey_*.p8 file)}"

SCHEME="OpenCircuit"
PROJECT="OpenCircuit.xcodeproj"
ARCHIVE="build-device/OpenCircuit.xcarchive"
EXPORT_DIR="build-device/export"

echo "==> Regenerating project (picks up any project.yml/asset changes)"
xcodegen generate

echo "==> Archiving (Release)"
xcodebuild archive \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$ASC_KEY_PATH" \
  -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID"

echo "==> Exporting + uploading to App Store Connect"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist ExportOptions.plist \
  -exportPath "$EXPORT_DIR" \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$ASC_KEY_PATH" \
  -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID"

echo "==> Done. The build will appear in App Store Connect -> TestFlight after processing (a few min)."
