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

codesign --force --sign - "$APP"
echo "Built $APP"

# Keep the installed copy current (it is the default video player), unless it is running.
if [[ -d /Applications/Hush.app ]]; then
    if pgrep -f "/Applications/Hush.app/Contents/MacOS/Hush" >/dev/null; then
        echo "Hush is running; quit it and rerun to update /Applications/Hush.app"
    else
        rm -rf /Applications/Hush.app && ditto "$APP" /Applications/Hush.app
        LSR=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
        "$LSR" -f /Applications/Hush.app
        "$LSR" -u "$APP" 2>/dev/null || true   # keep Finder opens going to the installed copy
        echo "Updated /Applications/Hush.app"
    fi
fi
