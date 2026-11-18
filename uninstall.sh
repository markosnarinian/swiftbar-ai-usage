#!/bin/bash
set -euo pipefail
PLUGINS=${1:-"$HOME/.swiftbar"}
if [[ -e $PLUGINS/usage.1m.sh ]]; then
  grep -Fq '.local/share/swiftbar-usage/usage.sh' "$PLUGINS/usage.1m.sh" || {
    echo 'Refusing to remove an unrelated usage.1m.sh plugin' >&2; exit 1;
  }
  rm "$PLUGINS/usage.1m.sh"
fi
rm -f "$HOME/.local/share/swiftbar-usage/usage.sh" "$HOME/.local/share/swiftbar-usage/normalize.jq"
printf 'Plugin removed. Configuration, history, credentials, and SwiftBar were left untouched.\n'
