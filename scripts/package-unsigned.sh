#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD_DIR=${BUILD_DIR:-"${TMPDIR:-/tmp}/xgimi-unsigned-build"}
OUT_DIR=${OUT_DIR:-"$ROOT/dist"}
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$ROOT/ios-wake/Info.plist")
mkdir -p "$OUT_DIR"
OUT_DIR=$(CDPATH= cd -- "$OUT_DIR" && pwd)
xcodebuild -project "$ROOT/ios-wake/ProjectorWake.xcodeproj" -scheme ProjectorWake -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath "$BUILD_DIR" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO SWIFT_SERIALIZE_DEBUGGING_OPTIONS=NO build
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/xgimi-ipa.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/Payload"
cp -R "$BUILD_DIR/Build/Products/Release-iphoneos/ProjectorWake.app" "$STAGE/Payload/"
if [ -e "$STAGE/Payload/ProjectorWake.app/embedded.mobileprovision" ] || [ -d "$STAGE/Payload/ProjectorWake.app/_CodeSignature" ]; then
  echo 'Refusing to package signed provisioning material' >&2; exit 1
fi
(cd "$STAGE" && zip -qry "$OUT_DIR/XGIMIRemote-v$VERSION-unsigned.ipa" Payload)
(cd "$OUT_DIR" && shasum -a 256 "XGIMIRemote-v$VERSION-unsigned.ipa" > SHA256SUMS.txt)
echo "Created $OUT_DIR/XGIMIRemote-v$VERSION-unsigned.ipa (self-sign before installation)"
