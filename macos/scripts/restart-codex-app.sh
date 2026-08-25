#!/bin/zsh
set -euo pipefail

sleep 2
/usr/bin/osascript -e 'tell application "ChatGPT" to quit' >/dev/null 2>&1 || true
sleep 2
/usr/bin/open -a "/Applications/ChatGPT.app"
