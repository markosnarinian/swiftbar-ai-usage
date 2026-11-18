#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TEMP=$(mktemp -d)
trap 'rm -rf "$TEMP"' EXIT
export HOME="$TEMP/home"
PLUGINS="$TEMP/plugin directory"
bash "$ROOT/install.sh" "$PLUGINS"
test -x "$PLUGINS/usage.1m.sh"
test -x "$HOME/.local/share/swiftbar-usage/usage.sh"
printf 'SERVICES="claude"\n' > "$HOME/.config/swiftbar-usage/config"
mkdir -p "$HOME/.cache/swiftbar-usage"
printf 'preserve me' > "$HOME/.cache/swiftbar-usage/history.sqlite"
bash "$ROOT/install.sh" "$PLUGINS"
grep -qx 'SERVICES="claude"' "$HOME/.config/swiftbar-usage/config"
bash "$ROOT/uninstall.sh" "$PLUGINS"
test ! -e "$PLUGINS/usage.1m.sh"
test ! -e "$HOME/.local/share/swiftbar-usage/usage.sh"
grep -qx 'preserve me' "$HOME/.cache/swiftbar-usage/history.sqlite"
grep -qx 'SERVICES="claude"' "$HOME/.config/swiftbar-usage/config"
printf 'unrelated plugin' > "$PLUGINS/usage.1m.sh"
if bash "$ROOT/install.sh" "$PLUGINS"; then exit 1; fi
if bash "$ROOT/uninstall.sh" "$PLUGINS"; then exit 1; fi
grep -qx 'unrelated plugin' "$PLUGINS/usage.1m.sh"
echo 'PASS: installation, updates, removal, and preservation of user data'
