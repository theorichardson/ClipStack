#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$ROOT/docs/images/sf"
SFSYM="${SFSYM:-sfsym}"

if ! command -v "$SFSYM" >/dev/null 2>&1; then
  if [[ -x /tmp/sfsym ]]; then
    SFSYM=/tmp/sfsym
  else
    echo "sfsym not found. Download from https://github.com/yapstudios/sfsym or: brew install yapstudios/tap/sfsym" >&2
    exit 1
  fi
fi

mkdir -p "$OUT_DIR"

symbols=(
  magnifyingglass
  link
  text.alignleft
  photo
  rectangle.dashed
  macwindow
  square.resize.down
  ellipsis
)

for symbol in "${symbols[@]}"; do
  slug="${symbol//./-}"
  "$SFSYM" export "$symbol" -f svg --weight regular --size 24 -o "$OUT_DIR/$slug.svg"
  echo "Exported $symbol -> $slug.svg"
done

python3 "$ROOT/scripts/build-sf-symbols-sprite.py"
