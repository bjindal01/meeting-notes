#!/usr/bin/env bash
# Builds MeetingNotes.app and (with --install) copies it to /Applications.
set -euo pipefail

cd "$(dirname "$0")"
APP_NAME="Meeting Notes"
BUNDLE="build/${APP_NAME}.app"

echo "==> Compiling (release)"
swift build -c release

BIN="$(swift build -c release --show-bin-path)/MeetingNotes"
[ -x "$BIN" ] || { echo "error: build produced no binary at $BIN"; exit 1; }

echo "==> Assembling ${BUNDLE}"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$BIN" "$BUNDLE/Contents/MacOS/MeetingNotes"
cp Resources/Info.plist "$BUNDLE/Contents/Info.plist"
printf 'APPL????' > "$BUNDLE/Contents/PkgInfo"

# macOS ties Microphone and Screen Recording grants to the code signature.
#
# An ad-hoc signature has no stable identity, so TCC pins the grant to the HASH
# OF THE BINARY -- every rebuild looks like a brand new app and you are asked for
# permission all over again. Signing with a real identity (even a self-signed
# one) makes the requirement identity-based instead, so grants survive rebuilds.
#
# Set CODESIGN_IDENTITY, or create "Meeting Notes Local Signing" in Keychain
# Access (see README), and this picks it up automatically.
IDENTITY="${CODESIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ] && security find-identity -v -p codesigning 2>/dev/null \
        | grep -q "Meeting Notes Local Signing"; then
    IDENTITY="Meeting Notes Local Signing"
fi

if [ -n "$IDENTITY" ]; then
    echo "==> Signing as: $IDENTITY"
    codesign --force --sign "$IDENTITY" \
        --entitlements MeetingNotes.entitlements \
        --identifier app.local.meetingnotes \
        --options runtime \
        "$BUNDLE" 2>&1 | sed 's/^/    /'
else
    echo "==> Signing (ad-hoc)"
    codesign --force --sign - \
        --entitlements MeetingNotes.entitlements \
        --identifier app.local.meetingnotes \
        --options runtime \
        "$BUNDLE" 2>&1 | sed 's/^/    /' || {
            echo "    note: hardened runtime unavailable, signing without it"
            codesign --force --sign - --entitlements MeetingNotes.entitlements \
                --identifier app.local.meetingnotes "$BUNDLE"
        }
    echo "    warning: ad-hoc signature -- macOS will ask for Microphone and"
    echo "    Screen Recording permission again after every rebuild."
    echo "    See 'Stopping the permission prompts' in the README."
fi

codesign --verify --verbose=1 "$BUNDLE" 2>&1 | sed 's/^/    /'

if [ "${1:-}" = "--install" ]; then
    echo "==> Installing to /Applications"
    # Quit a running copy first, or the replace will fail.
    osascript -e 'tell application "Meeting Notes" to quit' >/dev/null 2>&1 || true
    pkill -f "Meeting Notes.app/Contents/MacOS/MeetingNotes" >/dev/null 2>&1 || true
    sleep 1
    rm -rf "/Applications/${APP_NAME}.app"
    cp -R "$BUNDLE" "/Applications/${APP_NAME}.app"
    echo ""
    echo "Installed: /Applications/${APP_NAME}.app"
    echo "Open it with:  open \"/Applications/${APP_NAME}.app\""
else
    echo ""
    echo "Built: ${BUNDLE}"
    echo "Run it with:    open \"${BUNDLE}\""
    echo "Install it with: ./build.sh --install"
fi
