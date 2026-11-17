#!/usr/bin/env python3
"""Run combined production graphics transactions against the real bundled CC0 pack.

Uses only synthetic preferences/saves in temporary fixtures. One Swift compiler
process, no app/device/game execution. --source-root locates an integrated checkout
when this test-only branch has not yet been merged with the services/pack.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

TEST_ROOT = Path(__file__).resolve().parents[2]
p = argparse.ArgumentParser(description=__doc__)
p.add_argument("--source-root", type=Path, default=TEST_ROOT)
p.add_argument("--receipt", type=Path)
a = p.parse_args()
source_root = a.source_root.resolve()
names = ["GraphicsProfile.swift", "ModernVisualAssets.swift", "GraphicsVisualModeCoordinator.swift"]
sources = [source_root / "apple/Sources/Services" / name for name in names]
test = TEST_ROOT / "apple/Tests/GraphicsVisualModeCoordinatorTests.swift"
pack = source_root / "modern-visuals/pack"
for path in [*sources, pack / "manifest.json"]:
    if not path.is_file():
        p.error("missing integrated production source/pack: " + str(path))
source_hashes = {path.relative_to(source_root).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest() for path in sources}
with tempfile.TemporaryDirectory(prefix="skyrim-graphics-visual-tests-") as temporary:
    binary = Path(temporary) / "graphics-visual-tests"
    command = ["swiftc", "-swift-version", "6", "-parse-as-library", "-j1",
               "-D", "GRAPHICS_COORDINATOR_HOST_TESTS", *map(str, sources), str(test), "-o", str(binary)]
    compiled = subprocess.run(command, text=True, capture_output=True)
    result = {"schema": 1, "scope": "production coordinator/profile/asset services and real CC0 pack; synthetic temporary user files; no app/device acceptance",
              "sourceSHA256": source_hashes,
              "testSHA256": hashlib.sha256(test.read_bytes()).hexdigest(),
              "packManifestSHA256": hashlib.sha256((pack / "manifest.json").read_bytes()).hexdigest(),
              "compileExit": compiled.returncode, "compileOutput": compiled.stdout + compiled.stderr}
    print(compiled.stdout + compiled.stderr, end="")
    code = compiled.returncode
    if code == 0:
        run = subprocess.run([str(binary), str(pack)], text=True, capture_output=True)
        result.update(runExit=run.returncode, output=run.stdout + run.stderr)
        print(run.stdout + run.stderr, end="")
        code = run.returncode
    unchanged = source_hashes == {path.relative_to(source_root).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest() for path in sources}
    result["sourcesUnchangedDuringCheck"] = unchanged
    if not unchanged:
        print("Production sources changed during checks; rerun on a stable checkout.")
        code = 1
    if a.receipt:
        a.receipt.parent.mkdir(parents=True, exist_ok=True)
        a.receipt.write_text(json.dumps(result, indent=2) + "\n")
    raise SystemExit(code)
