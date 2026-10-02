#!/usr/bin/env bash
# Assembles and signs build/LapCat.app from the SwiftPM build.
#   scripts/bundle-app.sh [debug|release]
# release builds a Universal 2 (arm64 + x86_64) binary.
# Signing identity: $LAPCAT_CODESIGN_IDENTITY, default "LapCat Dev" (scripts/make-dev-cert.sh).
set -euo pipefail

cd "$(dirname "$0")/.."
config="${1:-debug}"
identity="${LAPCAT_CODESIGN_IDENTITY:-LapCat Dev}"

app="build/LapCat.app"
contents="$app/Contents"

case "$config" in
  debug)
    swift build -c debug --product LapCat
    bin_dir="$(swift build -c debug --show-bin-path)"
    executables=("$bin_dir/LapCat")
    ;;
  release)
    # `swift build --arch a --arch b` needs Xcode's xcbuild; the Command Line Tools can only build
    # one triple at a time, so each architecture is built separately and joined with lipo.
    executables=()
    for triple in arm64-apple-macosx14.2 x86_64-apple-macosx14.2; do
      swift build -c release --triple "$triple" --product LapCat
      bin_dir="$(swift build -c release --triple "$triple" --show-bin-path)"
      executables+=("$bin_dir/LapCat")
    done
    # Resource bundles are architecture-independent; $bin_dir (the last triple) supplies them.
    ;;
  *) echo "usage: $0 [debug|release]" >&2; exit 64 ;;
esac

framework="$(find .build/artifacts -type d -name whisper.framework -path '*macos-arm64_x86_64*' | head -1)"
if [[ -z "$framework" ]]; then
  echo "whisper.framework not found under .build/artifacts" >&2
  exit 1
fi

rm -rf "$app"
mkdir -p "$contents/MacOS" "$contents/Resources" "$contents/Frameworks" "$contents/Helpers"

if [[ ${#executables[@]} -gt 1 ]]; then
  lipo -create "${executables[@]}" -output "$contents/MacOS/LapCat"
else
  cp "${executables[0]}" "$contents/MacOS/LapCat"
fi
cp Resources/Info.plist "$contents/Info.plist"
for bundle in "$bin_dir"/*.bundle; do
  [[ -e "$bundle" ]] && cp -R "$bundle" "$contents/Resources/"
done
cp -R "$framework" "$contents/Frameworks/"

for arch in arm64 x64; do
  if [[ -d "vendor/llama/$arch" ]]; then
    # Helpers holds signed code only; non-code files there break the app's seal.
    mkdir -p "$contents/Helpers/llama/$arch"
    cp "vendor/llama/$arch/llama-server" "$contents/Helpers/llama/$arch/"
    cp -P "vendor/llama/$arch/"*.dylib "$contents/Helpers/llama/$arch/"
    cp "vendor/llama/$arch/LICENSE" "$contents/Resources/llama.cpp-LICENSE"
  else
    echo "warning: vendor/llama/$arch missing — run scripts/fetch-sidecars.sh for local LLM support" >&2
  fi
done

# The default identity lives in its own keychain (scripts/make-dev-cert.sh); unlock it so
# codesign never waits on a GUI prompt.
dev_keychain="$HOME/Library/Keychains/lapcat-dev.keychain-db"
if [[ -z "${LAPCAT_CODESIGN_IDENTITY:-}" ]]; then
  [[ -f "$dev_keychain" ]] || { echo "Run scripts/make-dev-cert.sh first." >&2; exit 1; }
  security unlock-keychain -p lapcat-dev "$dev_keychain"
fi

sign() { codesign --force --timestamp=none --sign "$identity" "$@"; }

# Inside-out: helpers and frameworks first, the app last.
while IFS= read -r -d '' file; do
  sign "$file"
done < <(find "$contents/Helpers" -type f \( -name '*.dylib' -o -perm -u+x \) -print0)
sign "$contents/Frameworks/whisper.framework"
sign --identifier com.lapcat.app "$app"

codesign --verify --deep --strict "$app"
echo "Built $app ($config), signed by \"$identity\"."
