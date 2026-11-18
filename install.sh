#!/bin/bash
set -euo pipefail
umask 077
ROOT=$(cd "$(dirname "$0")" && pwd)
PLUGINS=${1:-"$HOME/.swiftbar"}
[[ $(uname -s) == Darwin ]] || { echo 'macOS is required' >&2; exit 1; }
for command in jq curl sqlite3; do
  command -v "$command" >/dev/null || { echo "Missing dependency: $command" >&2; exit 1; }
done
if [[ -e $PLUGINS/usage.1m.sh ]] && ! grep -Fq '.local/share/swiftbar-usage/usage.sh' "$PLUGINS/usage.1m.sh"; then
  echo 'Refusing to overwrite an unrelated usage.1m.sh plugin' >&2
  exit 1
fi
mkdir -p "$PLUGINS" "$HOME/.local/share/swiftbar-usage" "$HOME/.config/swiftbar-usage"
install -m 755 "$ROOT/plugin/usage.sh" "$HOME/.local/share/swiftbar-usage/usage.sh"
install -m 644 "$ROOT/plugin/normalize.jq" "$HOME/.local/share/swiftbar-usage/normalize.jq"
if [[ ! -e $HOME/.config/swiftbar-usage/config ]]; then
  printf 'SERVICES="codex claude amp"\n' > "$HOME/.config/swiftbar-usage/config"
fi
install -m 755 "$ROOT/plugin/usage.1m.sh" "$PLUGINS/usage.1m.sh"
printf 'Installed into %s\nRequires the patched SwiftBar build; stock SwiftBar is not supported.\nExisting configuration and history were preserved.\n' "$PLUGINS"
