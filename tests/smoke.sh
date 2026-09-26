#!/usr/bin/env bash
# Offline orchestration smoke test with test doubles. NOT a native rendering test.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT
mkdir -p "$WORK/bin"
cat > "$WORK/bin/cmark-gfm" <<'STUB'
#!/usr/bin/env bash
printf '<h1>Rendered</h1>\n<p>Test text.</p>\n'
STUB
chmod +x "$WORK/bin/cmark-gfm"
PATH="$WORK/bin:$PATH" "$ROOT/scripts/md2png" --html-only "$ROOT/examples/demo.md" "$WORK/output.html" >/dev/null
grep -q '<h1>Rendered</h1>' "$WORK/output.html"
grep -q 'background-color: #0d1117' "$WORK/output.html"
grep -q '</html>' "$WORK/output.html"
if find "$ROOT/examples" -maxdepth 1 -name '.mdview-preview.*.html' | grep -q .; then
    echo 'Temporary file cleanup failed' >&2
    exit 1
fi
echo 'PASS: CLI → HTML/CSS → temporary file cleanup (mock cmark)'
