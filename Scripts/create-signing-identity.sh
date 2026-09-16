#!/bin/bash
# Creates a stable self-signed code-signing identity so that rebuilding ImageSmith
# does not invalidate its Screen Recording permission.
#
# With an ad-hoc signature (the default), macOS ties the TCC grant to the exact
# code hash, so every rebuild forces you to approve the app again. A certificate
# keeps the identity stable across rebuilds.
#
# macOS will show a keychain authorisation dialog — approve it. Run this once,
# then use Scripts/install.sh.
set -euo pipefail

NAME="ImageSmith Dev"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if security find-identity -v -p codesigning | grep -q "$NAME"; then
  echo "✓ '$NAME' already exists."
  exit 0
fi

cat > "$TMP/openssl.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF

echo "▸ Generating certificate…"
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/openssl.cnf" 2>/dev/null
# Apple's Security framework only reads the legacy PKCS#12 algorithms, so pin
# them explicitly — OpenSSL 3 defaults to AES/SHA-256 and the import fails.
openssl pkcs12 -export -out "$TMP/identity.p12" -inkey "$TMP/key.pem" \
  -in "$TMP/cert.pem" -passout pass:imagesmith \
  -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 2>/dev/null

echo "▸ Importing into your login keychain…"
security import "$TMP/identity.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
  -P imagesmith -A -T /usr/bin/codesign -T /usr/bin/security

echo "▸ Marking it trusted for code signing (approve the keychain dialog)…"
security add-trusted-cert -r trustRoot -p codeSign \
  -k "$HOME/Library/Keychains/login.keychain-db" "$TMP/cert.pem"

echo "✓ Done. Scripts/build-app.sh will now sign with '$NAME'."
