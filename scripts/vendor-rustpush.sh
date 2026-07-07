#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/vendor/rustpush"

ensure_submodule() {
  local name="$1"
  local url="$2"
  local path="$VENDOR/$name"
  if [[ ! -d "$path/.git" ]]; then
    echo "Cloning $name..."
    git clone "$url" "$path"
  fi
}

if [[ -d "$VENDOR/.git" ]]; then
  echo "Updating vendor/rustpush..."
  git -C "$VENDOR" pull --ff-only
else
  echo "Cloning OpenBubbles/rustpush..."
  git clone https://github.com/OpenBubbles/rustpush.git "$VENDOR"
fi

# rustpush .gitmodules uses git@ URLs; use HTTPS clones (SSH fails in many CI/dev shells).
ensure_submodule "apple-private-apis" "https://github.com/OpenBubbles/apple-private-apis.git"
ensure_submodule "open-absinthe" "https://github.com/OpenBubbles/OpenAbsinthe-Stub.git"

echo "Pinned rustpush: $(git -C "$VENDOR" rev-parse HEAD)"
echo "Pinned apple-private-apis: $(git -C "$VENDOR/apple-private-apis" rev-parse HEAD)"
echo "Pinned open-absinthe: $(git -C "$VENDOR/open-absinthe" rev-parse HEAD)"
