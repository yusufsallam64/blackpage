#!/bin/bash
# Builds and copies Blackpage.app into /Applications (overwrites an older copy of itself).
set -euo pipefail
cd "$(dirname "$0")"
./build.sh
osascript -e 'quit app "Blackpage"' 2>/dev/null || true
# wait for it to finish saving and exit before replacing the app
for _ in $(seq 1 120); do pgrep -xq Blackpage || break; sleep 0.5; done
if pgrep -xq Blackpage; then echo "Blackpage is still open; quit it and rerun"; exit 1; fi
ditto build/Blackpage.app /Applications/Blackpage.app
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/Blackpage.app
echo "installed /Applications/Blackpage.app"
