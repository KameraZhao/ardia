#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd -P)"
ardiacore="$root/packages/ardiacore"
out_dir="${1:-$root/dist/zh-hans}"
build_dir="${ARDIA_BUILD_DIR:-$root/apps/browser/build-zh-hans}"
mkdir -p "$out_dir" "$build_dir"
out_dir="$(cd "$out_dir" && pwd -P)"
build_dir="$(cd "$build_dir" && pwd -P)"

export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8
export ARDIACORE_PREBUILT_REPO="${ARDIACORE_PREBUILT_REPO:-ardia-browser/ardia}"
[ -d "$HOME/.cargo/bin" ] && export PATH="$HOME/.cargo/bin:$PATH"
[ -d "/opt/homebrew/bin" ] && export PATH="/opt/homebrew/bin:$PATH"

echo "==> Fetching prebuilt ArdiaCore engine"
if [ -n "${ARDIACORE_FRAMEWORK:-}" ] && [ -d "${ARDIACORE_FRAMEWORK}" ]; then
  framework="$ARDIACORE_FRAMEWORK"
else
  framework="$("$ardiacore/scripts/fetch-engine.sh" --nearest)"
fi
echo "Using framework: $framework"

echo "==> Preparing content blockers and HSTS preload"
"$ardiacore/scripts/ubo.sh"
"$ardiacore/scripts/ubol.sh"
"$ardiacore/scripts/hsts-preload.sh"

echo "==> Building Rust core xcframework"
"$root/packages/core-rs/scripts/build-xcframework.sh"

echo "==> Installing CocoaPods"
(cd "$root/apps/browser/macos" && pod install)

version="$(sed -n 's/.*MARKETING_VERSION = \([^;]*\);/\1/p' "$root/apps/browser/macos/Ardia.xcodeproj/project.pbxproj" | head -n 1 | tr -d '[:space:]"')"
version="${version:-0.0.0}"
short_sha="$(git -C "$root" rev-parse --short HEAD 2>/dev/null || echo local)"
archive="$out_dir/Ardia.xcarchive"
rm -rf "$archive"

echo "==> Building Release archive (ad-hoc signed, arm64)"
(
  cd "$root/apps/browser"
  ARDIACORE_FRAMEWORK="$framework" \
  ARDIACORE_STAGE_DIR="$build_dir/ArdiaCoreFramework" \
  xcodebuild \
    -workspace macos/Ardia.xcworkspace \
    -scheme Ardia-macOS \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    ARCHS=arm64 \
    -derivedDataPath "$build_dir" \
    -archivePath "$archive" \
    -xcconfig macos/AdHoc.xcconfig \
    archive
) > "$out_dir/archive.log" 2>&1 || {
  grep -E "error:|build commands failed" -A2 "$out_dir/archive.log" | grep -v MACOSX_DEPLOYMENT_TARGET | tail -30 >&2 || true
  echo "Archive failed. Full log: $out_dir/archive.log" >&2
  exit 1
}

app="$archive/Products/Applications/Ardia.app"
[ -d "$app" ] || { echo "Expected app not found at $app" >&2; exit 1; }

dmg="$out_dir/Ardia-${version}-zh-Hans-${short_sha}.dmg"
staging="$out_dir/dmg-staging"
dmg_rw="$out_dir/dmg-rw.dmg"
dmg_mnt="$out_dir/dmg-mnt"
rm -rf "$staging" "$dmg_rw" "$dmg_mnt" "$dmg"
mkdir -p "$staging" "$dmg_mnt"

echo "==> Packaging DMG: $dmg"
ditto "$app" "$staging/Ardia.app"
ln -s /Applications "$staging/Applications"
cp "$root/scripts/dmg/background.tiff" "$staging/.background.tiff"
cp "$root/scripts/dmg/DS_Store" "$staging/.DS_Store"
cp "$app/Contents/Resources/AppIcon.icns" "$staging/.VolumeIcon.icns"
mkdir -p "$staging/.fseventsd" && touch "$staging/.fseventsd/no_log"

hdiutil create -volname Ardia -srcfolder "$staging" -format UDRW -ov "$dmg_rw" >/dev/null
rm -rf "$staging"
hdiutil attach "$dmg_rw" -nobrowse -noautoopen -noverify -mountpoint "$dmg_mnt" >/dev/null
SetFile -a C "$dmg_mnt" || true
for attempt in 1 2 3 4 5; do
  hdiutil detach "$dmg_mnt" >/dev/null 2>&1 || true
  mount | grep -qF " on $(cd "$dmg_mnt" && pwd -P) (" || break
  [ "$attempt" = 5 ] && hdiutil detach "$dmg_mnt" -force >/dev/null 2>&1 || true
  sleep 2
done
hdiutil convert "$dmg_rw" -format ULMO -imagekey udif-chunk-size=8192 -ov -o "$dmg" >/dev/null
rm -rf "$dmg_rw" "$dmg_mnt"

echo "DMG_PATH=$dmg"
ls -lh "$dmg"
