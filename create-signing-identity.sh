#!/usr/bin/env bash
# Creates a self-signed code-signing identity so TCC permissions survive rebuilds.
#
# Without this the app is signed ad-hoc, which gives it no stable identity: macOS
# pins Microphone and Screen Recording grants to the hash of the binary, so every
# rebuild looks like a brand new app and every permission is forgotten.
set -euo pipefail

NAME="${1:-Meeting Notes Local Signing}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$NAME" >/dev/null 2>&1; then
    echo "Certificate \"$NAME\" already exists. Nothing to do."
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "==> Generating a 10-year self-signed code-signing certificate"
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -subj "/CN=$NAME" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null

openssl pkcs12 -export -out "$TMP/identity.p12" \
    -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -passout pass: 2>/dev/null

echo "==> Importing into the login keychain"
# -A lets codesign use the key without a prompt on every build.
security import "$TMP/identity.p12" -k "$KEYCHAIN" -P "" -T /usr/bin/codesign -A

echo ""
if security find-certificate -c "$NAME" >/dev/null 2>&1; then
    echo "Done. \"$NAME\" is installed."
    echo "Now re-sign the app so the grant sticks:"
    echo "  cd ~/code/meeting-notes-granolastyle && ./build.sh --install"
    echo ""
    echo "Remove it any time in Keychain Access, or with:"
    echo "  security delete-certificate -c \"$NAME\""
else
    echo "Import did not take. Create it manually instead:"
    echo "  Keychain Access > Certificate Assistant > Create a Certificate..."
    echo "  Name: $NAME / Self Signed Root / Code Signing"
    exit 1
fi
