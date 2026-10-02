#!/usr/bin/env bash
# Creates the self-signed "LapCat Dev" code-signing identity. Idempotent.
#
# A stable identity keeps macOS privacy (TCC) grants across rebuilds: TCC pins the app's
# designated requirement (bundle id + leaf certificate), so the certificate does not need to
# be trusted. The identity lives in its own keychain with a fixed password, which lets
# scripts unlock it and lets codesign use the key without a GUI prompt — the login keychain
# would need an "Always Allow" click that a non-GUI shell cannot show. The password guards
# only this self-signed development key.
set -euo pipefail

NAME="LapCat Dev"
KEYCHAIN="$HOME/Library/Keychains/lapcat-dev.keychain-db"
PASSWORD="lapcat-dev"

add_to_search_list() {
  local current
  current=()
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%\"}"; line="${line#\"}"
    [[ -n "$line" ]] && current+=("$line")
  done < <(security list-keychains -d user)
  for k in "${current[@]}"; do
    [[ "$k" == "$KEYCHAIN" || "$k" == "/private$KEYCHAIN" ]] && return 0
  done
  security list-keychains -d user -s "${current[@]}" "$KEYCHAIN"
}

if [[ ! -f "$KEYCHAIN" ]]; then
  security create-keychain -p "$PASSWORD" "$KEYCHAIN"
  security set-keychain-settings "$KEYCHAIN" # no auto-lock timeout
fi
security unlock-keychain -p "$PASSWORD" "$KEYCHAIN"
add_to_search_list

if security find-identity -p codesigning "$KEYCHAIN" | grep -q "\"$NAME\""; then
  echo "Code-signing identity \"$NAME\" already present in $KEYCHAIN."
  exit 0
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -subj "/CN=$NAME" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" \
  -addext "basicConstraints=critical,CA:false" \
  -keyout "$tmp/key.pem" -out "$tmp/cert.pem" 2>/dev/null

# -legacy keeps the PKCS#12 readable by `security import` when openssl is 3.x.
legacy=()
if openssl version | grep -q "^OpenSSL 3"; then legacy=(-legacy); fi
openssl pkcs12 -export "${legacy[@]}" -name "$NAME" \
  -inkey "$tmp/key.pem" -in "$tmp/cert.pem" -out "$tmp/identity.p12" -passout pass:lapcat

security import "$tmp/identity.p12" -k "$KEYCHAIN" -P lapcat -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PASSWORD" "$KEYCHAIN" >/dev/null

security find-identity -p codesigning "$KEYCHAIN" | grep -q "\"$NAME\"" || {
  echo "Import finished but \"$NAME\" is not a code-signing identity in $KEYCHAIN." >&2
  exit 1
}
echo "Created code-signing identity \"$NAME\" in $KEYCHAIN."
