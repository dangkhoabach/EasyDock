#!/usr/bin/env bash
# Builds 7zz, the 7-Zip command line program EasyDock extracts archives with,
# from the unmodified 7-Zip source in ThirdParty/7-Zip, for the architectures
# Xcode is building. Run by the app target's "Build 7-Zip" phase, which
# declares the source and this script as inputs and $BUILT_PRODUCTS_DIR/7zz
# as the output, so it runs again only when one of them changes.
set -euo pipefail

SOURCE="$SRCROOT/ThirdParty/7-Zip/7z2606-src.tar.xz"
# SHA-256 of 7z2606-src.tar.xz as released on 7-zip.org and github.com/ip7z/7zip.
SOURCE_SHA256="a4e374c8f864f51df48c2cfd0e1413ec3b2ea030deae852d6a655402ebb61ac4"
# Xcode's script sandbox lets the phase write only its declared output and
# the temporary folder, not DerivedData's own folders.
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
OUTPUT="$BUILT_PRODUCTS_DIR/7zz"

echo "$SOURCE_SHA256  $SOURCE" | shasum -a 256 -c - >/dev/null || {
  echo "error: $SOURCE does not match its SHA-256" >&2
  exit 1
}
tar -xf "$SOURCE" -C "$WORK"
cd "$WORK/CPP/7zip/Bundles/Alone2"

BUILT=()
for ARCH in $ARCHS; do
  case "$ARCH" in
    arm64) MAKEFILE=cmpl_mac_arm64.mak PLATFORM=arm64 FLAGS="-arch arm64 -march=armv8-a" ;;
    x86_64) MAKEFILE=cmpl_mac_x64.mak PLATFORM=x64 FLAGS="-arch x86_64" ;;
    *) echo "error: no 7-Zip build for $ARCH" >&2; exit 1 ;;
  esac
  # The makefiles target macOS 10.15 on Intel, which the libc++ of current
  # Xcode refuses, and build with -Werror -Weverything, which a newer
  # compiler's new warnings would break.
  make -s -j"$(sysctl -n hw.activecpu)" -f "../../$MAKEFILE" \
    MY_ARCH="$FLAGS -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET" CFLAGS_WARN_WALL=-Wall
  BUILT+=("b/m_$PLATFORM/7zz")
done
# lipo writes a temporary file beside its output, which the sandbox refuses
# next to the declared output: join here, then copy just the result.
lipo -create -output "$WORK/7zz" "${BUILT[@]}"
cp "$WORK/7zz" "$OUTPUT"
