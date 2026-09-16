#!/bin/bash
# Creates a stable self-signed code-signing identity so that rebuilding ImageSmith
# does not invalidate its Screen Recording permission.
#
# With an ad-hoc signature (the default), macOS ties the TCC grant to the exact
# code hash, so every rebuild forces you to approve the app again. A certificate
# keeps the identity stable across rebuilds.
#
# You will be asked for your login password twice: once to add the certificate to
# your keychain, once to trust it. Run this once, then use Scripts/install.sh.
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
openssl pkcs12 -export -out "$TMP/identity.p12" -inkey "$TMP/key.pem" \
  -in "$TMP/cert.pem" -passout pass: 2>/dev/null

echo "▸ Importing into your login keychain…"
security import "$TMP/identity.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
  -P "" -T /usr/bin/codesign -T /usr/bin/security

echo "▸ Marking it trusted for code signing (needs your password)…"
sudo security add-trusted-cert -d -r trustRoot \
  -p codeSign -k /Library/Keychains/System.keychain "$TMP/cert.pem"

echo "✓ Done. Scripts/build-app.sh will now sign with '$NAME'."
