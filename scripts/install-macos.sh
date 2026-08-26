#!/bin/bash
#
# Installs Duck Engine on this Mac.
#
# The engine is a small Node program, so this copies the built code somewhere
# stable, registers it with the browsers, and asks launchd to keep it running.
# No Electron and no 100MB binary download — the desktop window is a separate,
# optional piece.
#
# Everything lands under the user's own directories. Nothing needs sudo, and
# nothing is written outside the home folder.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$HOME/Library/Application Support/DuckDownloader/app"
BIN_DIR="$HOME/Library/Application Support/DuckDownloader/bin"
AGENT="$HOME/Library/LaunchAgents/com.duckdownloader.engine.plist"
HOST_NAME="com.duckdownloader.engine"

say() { printf '\033[1m%s\033[0m\n' "$*"; }
note() { printf '  %s\n' "$*"; }

# ---------------------------------------------------------------- node --

# launchd starts with a minimal PATH, so the interpreter has to be recorded as
# an absolute path now rather than looked up later.
NODE="$(command -v node || true)"
if [ -z "$NODE" ]; then
  for candidate in /opt/homebrew/bin/node /usr/local/bin/node "$HOME"/.nvm/versions/node/*/bin/node; do
    [ -x "$candidate" ] && NODE="$candidate" && break
  done
fi

if [ -z "$NODE" ]; then
  echo "Node is required and was not found. Install it, then run this again." >&2
  exit 1
fi

NODE_MAJOR="$("$NODE" -e 'process.stdout.write(process.versions.node.split(".")[0])')"
if [ "$NODE_MAJOR" -lt 20 ]; then
  echo "Node 20 or newer is required; found $("$NODE" -v)." >&2
  exit 1
fi

say "Duck Engine — installing for $(whoami)"
note "node $("$NODE" -v) at $NODE"

# --------------------------------------------------------------- build --

say "Building"
(cd "$REPO/engine" && "$NODE" node_modules/typescript/bin/tsc -p tsconfig.json)
(cd "$REPO/bridge" && "$NODE" node_modules/typescript/bin/tsc -p tsconfig.json)
note "engine and bridge compiled"

# -------------------------------------------------------------- install --

say "Installing"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR" "$BIN_DIR"
cp -R "$REPO/engine/dist" "$APP_DIR/engine-dist"
cp -R "$REPO/bridge/dist" "$APP_DIR/bridge-dist"
note "copied to $APP_DIR"

ENGINE_ENTRY="$APP_DIR/engine-dist/engine/src/index.js"
BRIDGE_ENTRY="$APP_DIR/bridge-dist/bridge/src/index.js"

# The bridge locates the engine by walking up looking for
# engine/dist/engine/src/index.js, so the installed layout has to match.
mkdir -p "$APP_DIR/engine/dist" "$APP_DIR/bridge/dist"
rm -rf "$APP_DIR/engine/dist" "$APP_DIR/bridge/dist"
mv "$APP_DIR/engine-dist" "$APP_DIR/engine/dist"
mv "$APP_DIR/bridge-dist" "$APP_DIR/bridge/dist"

ENGINE_ENTRY="$APP_DIR/engine/dist/engine/src/index.js"
BRIDGE_ENTRY="$APP_DIR/bridge/dist/bridge/src/index.js"

# --------------------------------------------------------------- bridge --

LAUNCHER="$BIN_DIR/duck-bridge"
cat > "$LAUNCHER" <<LAUNCH
#!/bin/sh
exec "$NODE" "$BRIDGE_ENTRY" "\$@"
LAUNCH
chmod 755 "$LAUNCHER"
note "bridge launcher at $LAUNCHER"

EXTENSION_ID="$(tr -d '[:space:]' < "$REPO/extension/keys/id.txt")"
note "authorising extension $EXTENSION_ID"

# Every Chromium browser reads its own directory; writing to all of them means
# the engine works whichever one is used.
for dir in \
  "$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts" \
  "$HOME/Library/Application Support/BraveSoftware/Brave-Browser/NativeMessagingHosts" \
  "$HOME/Library/Application Support/Microsoft Edge/NativeMessagingHosts" \
  "$HOME/Library/Application Support/Chromium/NativeMessagingHosts"; do
  mkdir -p "$dir"
  cat > "$dir/$HOST_NAME.json" <<JSON
{
  "name": "$HOST_NAME",
  "description": "Duck Engine bridge",
  "path": "$LAUNCHER",
  "type": "stdio",
  "allowed_origins": ["chrome-extension://$EXTENSION_ID/"]
}
JSON
done
note "registered with Chrome, Brave, Edge and Chromium"

# ------------------------------------------------------------ launchd --

say "Setting it to start at login"
mkdir -p "$HOME/Library/LaunchAgents"

# KeepAlive brings the engine back if it ever exits unexpectedly, so a queue
# left running overnight is still running in the morning.
cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$HOST_NAME</string>
  <key>ProgramArguments</key>
  <array>
    <string>$NODE</string>
    <string>$ENGINE_ENTRY</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>$HOME/Library/Logs/duck-engine.log</string>
  <key>StandardErrorPath</key>
  <string>$HOME/Library/Logs/duck-engine.log</string>
</dict>
</plist>
PLIST

launchctl bootout "gui/$(id -u)/$HOST_NAME" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$AGENT"
note "launch agent installed"

sleep 2
if launchctl print "gui/$(id -u)/$HOST_NAME" >/dev/null 2>&1; then
  note "engine is running"
else
  echo "  the engine did not start — see ~/Library/Logs/duck-engine.log" >&2
fi

echo
say "Done"
echo
echo "  Load the extension:"
echo "    1. open brave://extensions (or chrome://extensions)"
echo "    2. turn on Developer mode"
echo "    3. Load unpacked -> $REPO/extension/dist/chrome-mv3"
echo
echo "  Downloads go to ~/Downloads/Duck Downloader"
echo "  Engine log:      ~/Library/Logs/duck-engine.log"
echo "  Uninstall:       $REPO/scripts/uninstall-macos.sh"
