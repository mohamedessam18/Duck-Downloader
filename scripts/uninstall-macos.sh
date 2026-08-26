#!/bin/bash
#
# Removes Duck Engine from this Mac.
#
# Downloaded files and the job history are left alone — removing the program
# should never delete the user's data. The paths to clear those by hand are
# printed at the end.

set -uo pipefail

DATA_DIR="$HOME/Library/Application Support/DuckDownloader"
AGENT="$HOME/Library/LaunchAgents/com.duckdownloader.engine.plist"
HOST_NAME="com.duckdownloader.engine"

say() { printf '\033[1m%s\033[0m\n' "$*"; }
note() { printf '  %s\n' "$*"; }

say "Duck Engine — uninstalling"

launchctl bootout "gui/$(id -u)/$HOST_NAME" 2>/dev/null && note "stopped the launch agent" || note "launch agent was not running"
rm -f "$AGENT"

# The engine may also have been started directly by the bridge rather than by
# launchd, so make sure nothing is left holding the socket.
pkill -f "DuckDownloader/app/engine/dist/engine/src/index.js" 2>/dev/null && note "stopped a running engine" || true

for dir in \
  "$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts" \
  "$HOME/Library/Application Support/BraveSoftware/Brave-Browser/NativeMessagingHosts" \
  "$HOME/Library/Application Support/Microsoft Edge/NativeMessagingHosts" \
  "$HOME/Library/Application Support/Chromium/NativeMessagingHosts"; do
  rm -f "$dir/$HOST_NAME.json"
done
note "unregistered from the browsers"

rm -rf "$DATA_DIR/app" "$DATA_DIR/bin"
note "removed the installed program"

echo
say "Done"
echo
echo "  Kept, in case you want them:"
echo "    downloads      ~/Downloads/Duck Downloader"
echo "    job history    $DATA_DIR/jobs.json"
echo "    partial files  $DATA_DIR/partials"
echo "    settings       $DATA_DIR/settings.json"
echo
echo "  To remove those too:  rm -rf \"$DATA_DIR\""
echo "  Remember to remove the extension from your browser's extensions page."
