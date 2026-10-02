#!/usr/bin/env bash
# Downloads the llama-server sidecar for both architectures into vendor/llama/{arm64,x64}/.
# Archives are verified against scripts/sidecars.sha256. Idempotent.
set -euo pipefail

cd "$(dirname "$0")/.."
release="b11320"
base="https://github.com/ggml-org/llama.cpp/releases/download/$release"
cache="vendor/downloads"
mkdir -p "$cache"

for arch in arm64 x64; do
  archive="llama-$release-bin-macos-$arch.tar.gz"
  dest="vendor/llama/$arch"
  stamp="$dest/.release"

  if [[ -x "$dest/llama-server" && "$(cat "$stamp" 2>/dev/null)" == "$release" ]]; then
    echo "llama-server $release ($arch) already present."
    continue
  fi

  if ! (cd "$cache" && shasum -a 256 -c --status <(grep " $archive\$" ../../scripts/sidecars.sha256) 2>/dev/null); then
    echo "Downloading $archive…"
    curl -fSL --retry 3 -o "$cache/$archive" "$base/$archive"
    (cd "$cache" && grep " $archive\$" ../../scripts/sidecars.sha256 | shasum -a 256 -c -) || {
      echo "Checksum mismatch for $archive" >&2
      rm -f "$cache/$archive"
      exit 1
    }
  fi

  tmp="$(mktemp -d)"
  tar -xzf "$cache/$archive" -C "$tmp"
  src="$tmp/llama-$release"
  rm -rf "$dest"
  mkdir -p "$dest"
  # llama-server finds its dylibs through an @loader_path rpath, so they sit next to it.
  cp "$src/llama-server" "$src/LICENSE" "$dest/"
  cp -P "$src"/lib*.dylib "$dest/"
  # Per-tool implementation libraries other than the server's are not needed.
  find "$dest" -name 'libllama-*-impl.dylib' ! -name 'libllama-server-impl.dylib' -delete
  echo "$release" > "$stamp"
  rm -rf "$tmp"
  echo "Installed llama-server $release ($arch) in $dest."
done
