#!/bin/sh
# Builds edgepad, installs it as a login agent, and writes default corner actions.
set -e
cd "$(dirname "$0")"
mkdir -p ~/.local/bin ~/.config/edgepad ~/Library/LaunchAgents
clang -fobjc-arc -O2 -framework Cocoa -framework ApplicationServices main.m -o ~/.local/bin/edgepad

# Line 1 = top-left tap, line 2 = top-right tap. Any shell command: open -a App, open URL, shortcuts run "Name".
[ -f ~/.config/edgepad/corners ] || printf '%s\n' \
  "osascript -e 'set volume output muted not (output muted of (get volume settings))'" \
  "open -a 'Mission Control'" > ~/.config/edgepad/corners

plist=~/Library/LaunchAgents/com.edgepad.plist
cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.edgepad</string>
  <key>ProgramArguments</key><array><string>$HOME/.local/bin/edgepad</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardErrorPath</key><string>/tmp/edgepad.log</string>
</dict></plist>
EOF
launchctl bootout "gui/$(id -u)" "$plist" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$plist"
echo "edgepad installed. Allow ~/.local/bin/edgepad in System Settings > Privacy & Security > Accessibility."
echo "Rebuilding changes the binary signature: remove and re-add it there after each reinstall."
