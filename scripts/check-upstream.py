"""Verify the pinned core and the explicitly accepted local patches."""
import hashlib
import json
from pathlib import Path

root = Path(__file__).resolve().parents[1] / "Collector/vendor"
base = json.loads((root / "UPSTREAM.json").read_text())
patch_path = root / "LOCAL-PATCHES.json"
patches = json.loads(patch_path.read_text())["files"] if patch_path.exists() else {}
expected = dict(base["sha256"])
for name, patch in patches.items():
    assert patch["upstreamSha256"] == expected.get(name), f"Wrong upstream base: {name}"
    expected[name] = patch["sha256"]
actual = {str(p.relative_to(root)) for p in (root / "tokens-core").rglob("*") if p.is_file()}
assert actual == set(expected), "Unexpected or missing core files"
for name, digest in expected.items():
    assert hashlib.sha256((root / name).read_bytes()).hexdigest() == digest, f"Unreviewed change: {name}"
print(f"PASS: {len(expected)} core files, {len(patches)} recorded local patch files")
