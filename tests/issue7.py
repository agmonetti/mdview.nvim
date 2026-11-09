"""Regression test for Issue #7: Under-indented lazy continuation lines with code spans."""
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PREVIEW = ROOT / "build/mdview-preview"
CSS = ROOT / "styles/markdown.css"


def h(value):
    return str(value).encode().hex()


def run(args, *, stdin=None):
    result = subprocess.run(args, input=stdin, capture_output=True, text=True, timeout=20)
    assert result.returncode == 0, (args, result.stdout, result.stderr)
    return result.stdout


CASES = {
    "issue7_minimal": (
        b"2. **Title:**\n"
        b"   * `code1`: item 1\n"
        b"   * `code2`: item 2\n"
        b"   El wrapper simula `teams-for-linux`.\n",
        [(4, 21, "teams-for-linux")]
    ),
    "issue7_full": (
        b"2. **Uso de identidades de cliente predefinidas (Hardcoded Client IDs):**  \n"
        b"   * `88200948-af09-45a1-9c03-53cdcc75c183`: Client ID oficial de administracion (`getAccounts`).\n"
        b"   * `d7b530a4-7680-4c23-a8bf-c52c121d2e87`: Client ID de Microsoft Edge (`acquirePrtSsoCookie`).  \n"
        b"   El wrapper simula ser Microsoft Edge ante el broker; no interactua con identidad de `teams-for-linux`.\n",
        [(4, 88, "teams-for-linux")]
    ),
    "nested_lazy_bullet": (
        b"* a\n"
        b"  * b\n"
        b"  lazy continuation with `code`.\n",
        [(3, 26, "code")]
    )
}


def main():
    with tempfile.TemporaryDirectory(prefix="mdview-issue7-") as scratch:
        directory = Path(scratch)
        for name, (source, expected_anchors) in CASES.items():
            path = directory / f"{name}.md"
            path.write_bytes(source)
            req = f"LOAD 1 900 {h(path)} {h(path.parent)} {h(CSS)}\nQUIT\n"
            response = run([str(PREVIEW)], stdin=req)
            assert "READY 1" in response, f"{name} failed to become READY:\n{response}"
            assert "ERROR " not in response, f"{name} produced error:\n{response}"

            anchors = {}
            for line, first, last in [(int(m[0]), int(m[1]), int(m[2])) for m in
                                      [x.split()[1:4] for x in response.splitlines() if x.startswith("FRAG ")]]:
                anchors.setdefault(line, []).append((first, last))

            lines = source.splitlines()
            for line_no, exp_col, exp_sub in expected_anchors:
                physical_line = lines[line_no - 1].decode("utf-8")
                assert exp_sub in physical_line, f"{exp_sub} not found on line {line_no}"
                actual_idx = physical_line.find(exp_sub)
                line_anchors = anchors.get(line_no, [])
                matched = any(first <= actual_idx <= last for first, last in line_anchors)
                assert matched, (
                    f"{name}: expected anchor covering '{exp_sub}' on line {line_no} "
                    f"at col {actual_idx}, got anchors: {line_anchors}"
                )

    print("PASS: issue #7 lazy continuation line attribution regression")


if __name__ == "__main__":
    main()
