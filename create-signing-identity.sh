#!/usr/bin/env bash
# Creates a self-signed code-signing identity so TCC permissions survive rebuilds.
#
# Without this the app is signed ad-hoc, which gives it no stable identity: macOS
# pins Microphone and Screen Recording grants to the hash of the binary, so every
# rebuild looks like a brand new app and every permission is forgotten.
set -euo pipefail

NAME="${1:-Meeting Notes Local Signing}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
# The PKCS#12 wrapper is opened and discarded during import, so this password
# protects nothing afterwards. It only has to be non-empty: LibreSSL and Apple's
# Security framework disagree on how to MAC an empty password, which makes the
# import fail with "MAC verification failed".
P12_PASS="meetingnotes-import"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$NAME"; then
    echo "Identity \"$NAME\" already exists. Nothing to do."
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

echo "==> Importing into the login keychain"
# -A lets codesign use the private key without prompting on every build.
if openssl pkcs12 -export -out "$TMP/identity.p12" \
        -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
        -passout "pass:$P12_PASS" 2>/dev/null \
   && security import "$TMP/identity.p12" -k "$KEYCHAIN" -P "$P12_PASS" \
        -T /usr/bin/codesign -A 2>/dev/null; then
    echo "    imported as PKCS#12"
else
    # Some OpenSSL/LibreSSL builds produce a PKCS#12 that macOS rejects outright.
    # Importing the certificate and the key separately builds the same identity.
    echo "    PKCS#12 rejected, importing certificate and key separately"
    security import "$TMP/cert.pem" -k "$KEYCHAIN" -A
    security import "$TMP/key.pem" -k "$KEYCHAIN" -T /usr/bin/codesign -A
fi

echo ""
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$NAME"; then
    echo "Done. \"$NAME\" is ready to sign with."
    echo ""
    echo "Next:"
    echo "  ./build.sh --install"
    echo "  tccutil reset ScreenCapture app.local.meetingnotes"
    echo "  tccutil reset Microphone app.local.meetingnotes"
    echo ""
    echo "Grant the two permissions once more and they will stick from then on."
    echo "Remove the certificate any time with:"
    echo "  security delete-identity -c \"$NAME\""
else
    echo "The identity did not register. Create it by hand instead:"
    echo ""
    echo "  Keychain Access > Certificate Assistant > Create a Certificate..."
    echo "    Name:              $NAME"
    echo "    Identity Type:     Self Signed Root"
    echo "    Certificate Type:  Code Signing"
    echo ""
    echo "Leave it in the login keychain; build.sh finds it by name."
    exit 1
fi
