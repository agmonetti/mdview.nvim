#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="$ROOT/third_party/litehtml"
if [[ ! -f "$REPO/containers/cairo/render2png.cpp" ]]; then
    if [[ -e "$REPO" ]]; then
        echo "Directory $REPO exists but does not contain the litehtml renderer" >&2
        exit 1
    fi
    echo "Downloading litehtml v0.10 source for compilation only"
    git clone --depth 1 --branch v0.10 https://github.com/litehtml/litehtml.git "$REPO"
fi
cmake -S "$ROOT" -B "$ROOT/build" -DCMAKE_BUILD_TYPE=Release
cmake --build "$ROOT/build" --parallel 2
printf '\nBuilt: %s/build/mdview-render\n' "$ROOT"
