#!/usr/bin/env bash
# Render art/og.html to site/img/og.png (1200×630 link-preview image) with a headless Chromium browser.
set -euo pipefail
cd "$(dirname "$0")"
BROWSER="${BROWSER:-}"
for b in "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
         "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser" \
         "/Applications/Chromium.app/Contents/MacOS/Chromium" \
         "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge"; do
  [ -z "$BROWSER" ] && [ -x "$b" ] && BROWSER="$b"
done
[ -n "$BROWSER" ] || { echo "No Chromium-based browser found; set BROWSER=/path/to/browser" >&2; exit 1; }
"$BROWSER" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=1 \
  --window-size=1200,630 --virtual-time-budget=6000 \
  --screenshot="$PWD/../site/img/og.png" "file://$PWD/og.html" 2>/dev/null
echo "Wrote site/img/og.png"
