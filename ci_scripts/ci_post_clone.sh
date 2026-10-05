#!/bin/sh
# Installs the NDI SDK (headers + libndi_ios.a) into Vendor/NDI so the project
# builds on Xcode Cloud, where /Library/NDI SDK for Apple doesn't exist.
# The lib is ~270 MB (over GitHub's 100 MB file limit), so it can't be committed.
# Locally: run once; it symlinks your installed SDK if present.
set -eu

ROOT="${CI_PRIMARY_REPOSITORY_PATH:-$(cd "$(dirname "$0")/.." && pwd)}"
DEST="$ROOT/Vendor/NDI"
LOCAL_SDK="/Library/NDI SDK for Apple"
PKG_URL="https://downloads.ndi.tv/SDK/NDI_SDK_Mac/Install_NDI_SDK_v6_Apple.pkg"
# Pinned: NDI republishes this URL in place. On mismatch, review the new SDK and update.
PKG_SHA256="5aa101a01b00494724c60b7e1e15b5d1743bf9c68b61739c22ac54932dde95fb"

if [ -f "$DEST/lib/iOS/libndi_ios.a" ]; then
  echo "NDI SDK already at $DEST"
  exit 0
fi

mkdir -p "$ROOT/Vendor"
if [ -z "${CI:-}" ] && [ -f "$LOCAL_SDK/lib/iOS/libndi_ios.a" ]; then
  ln -sfn "$LOCAL_SDK" "$DEST"
  echo "Linked $DEST -> $LOCAL_SDK"
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

curl -fsSL --retry 3 -o "$TMP/ndi.pkg" "$PKG_URL"
echo "$PKG_SHA256  $TMP/ndi.pkg" | shasum -a 256 -c -

pkgutil --expand-full "$TMP/ndi.pkg" "$TMP/x"
SDK="$(find "$TMP/x" -type d -name 'NDI SDK for Apple' -path '*/Payload/*' | head -n 1)"
[ -n "$SDK" ] || { echo "NDI SDK not found in pkg" >&2; exit 1; }

rm -rf "$DEST"
mkdir -p "$DEST/lib/iOS"
cp -R "$SDK/include" "$DEST/include"
cp "$SDK/lib/iOS/libndi_ios.a" "$DEST/lib/iOS/"
echo "Installed NDI SDK into $DEST"
