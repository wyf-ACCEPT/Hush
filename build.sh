#!/bin/zsh
# Build Hush.app (release) into ./build. Requires: Xcode CLT, `brew install mpv`.
set -euo pipefail
cd "${0:A:h}"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/Hush"

APP=build/Hush.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Hush"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/input.conf "$APP/Contents/Resources/input.conf"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Sign with a stable identity so privacy grants (e.g. access to Downloads) survive rebuilds;
# an ad-hoc signature changes on every build and macOS asks again. Put the SHA-1 of a
# codesigning certificate in .signing-identity (untracked) or HUSH_SIGN_IDENTITY.
IDENTITY="${HUSH_SIGN_IDENTITY:-$(cat .signing-identity 2>/dev/null || true)}"
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "Built $APP"

# Keep the installed copy current (it is the default video player). A running copy is quit
# gracefully first, so mpv still writes the resume position of whatever was playing.
if [[ -d /Applications/Hush.app ]]; then
    if pgrep -f "/Applications/Hush.app/Contents/MacOS/Hush" >/dev/null; then
        osascript -e 'tell application id "com.pland.hush" to quit' >/dev/null 2>&1 || true
        for _ in {1..50}; do
            pgrep -f "/Applications/Hush.app/Contents/MacOS/Hush" >/dev/null || break
            sleep 0.1
        done
    fi
    if pgrep -f "/Applications/Hush.app/Contents/MacOS/Hush" >/dev/null; then
        echo "Hush did not quit; /Applications/Hush.app was not updated"
    else
        rm -rf /Applications/Hush.app && ditto "$APP" /Applications/Hush.app
        LSR=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
        "$LSR" -f /Applications/Hush.app
        "$LSR" -u "$APP" 2>/dev/null || true   # keep Finder opens going to the installed copy
        echo "Updated /Applications/Hush.app"
    fi
fi
