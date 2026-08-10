#!/usr/bin/env bash
# sspc one-liner bootstrap:
#   curl -fsSL https://raw.githubusercontent.com/anibjoshi/sspc-demo/main/boot.sh | bash
# Prefer to read first? git clone https://github.com/anibjoshi/sspc-demo
set -euo pipefail
command -v git >/dev/null || { echo "git is required"; exit 1; }
dir="${SSPC_HOME:-$HOME/.sspc-demo}"
if [ -d "$dir/.git" ]; then
  git -C "$dir" pull -q --ff-only || true
else
  git clone -q --depth 1 https://github.com/anibjoshi/sspc-demo "$dir"
fi
echo "sspc demo in $dir"
exec "$dir/install.sh" "$@"
