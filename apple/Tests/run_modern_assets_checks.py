#!/usr/bin/env python3
"""One compiler job at a time; temporary fixtures only, no app/device/game.

--pack optionally verifies and round-trips the real immutable bundled pack.
Without it the host tests generate DDS fixtures, so no game assets are needed.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import time

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "apple/Sources/Services/ModernVisualAssets.swift"
TEST = ROOT / "apple/Tests/ModernVisualAssetsTests.swift"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pack", type=Path)
    parser.add_argument("--receipt", type=Path, default=ROOT / "apple/build/modern-assets-checks/receipt.json")
    args = parser.parse_args()
    args.receipt.parent.mkdir(parents=True, exist_ok=True)
    binary = args.receipt.parent / "modern-assets-test-asan"
    records = []

    def run(name, command):
        start = time.monotonic()
        try:
            p = subprocess.run(list(map(str, command)), cwd=ROOT, text=True, capture_output=True, timeout=180)
            output = p.stdout + p.stderr
            ok = p.returncode == 0 and not any(s in output for s in ("ERROR: AddressSanitizer", "runtime error:"))
            record = {"name": name, "ok": ok, "rc": p.returncode,
                      "seconds": round(time.monotonic()-start, 3), "tail": output.strip().splitlines()[-5:]}
        except subprocess.TimeoutExpired:
            record = {"name": name, "ok": False, "rc": 124, "seconds": 180, "tail": ["timed out; killed"]}
        records.append(record)
        print(f"{'PASS' if record['ok'] else 'FAIL'} {name}: " + " | ".join(record["tail"]), flush=True)
        return record["ok"]

    if run("Swift 6 ASan host compile", ["xcrun", "swiftc", "-swift-version", "6", "-j1", "-O", "-sanitize=address",
                                         "-parse-as-library", SOURCE, TEST, "-o", binary]):
        run("host transaction + process crash tests", [binary] + (["--pack", args.pack] if args.pack else []))
    for sdk, target in (("iphoneos", "arm64-apple-ios18.0"), ("xros", "arm64-apple-xros26.5")):
        sdk_path = subprocess.check_output(["xcrun", "--sdk", sdk, "--show-sdk-path"], text=True).strip()
        run(sdk + " Swift 6 typecheck", ["xcrun", "--sdk", sdk, "swiftc", "-swift-version", "6", "-j1", "-typecheck",
                                         "-target", target, "-sdk", sdk_path, SOURCE])
    manifest = args.pack / "manifest.json" if args.pack else None
    receipt = {"schema": 1, "scope": "host fixtures + optional read-only CC0 bundled pack + SDK typecheck; no app/device/game",
               "head": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
               "source_sha256": {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in (SOURCE, TEST)},
               "pack_manifest_sha256": hashlib.sha256(manifest.read_bytes()).hexdigest() if manifest else None,
               "results": records, "passed": sum(r["ok"] for r in records), "failed": sum(not r["ok"] for r in records)}
    args.receipt.write_text(json.dumps(receipt, indent=2) + "\n")
    print(f"{receipt['passed']} passed, {receipt['failed']} failed; {args.receipt}")
    return int(bool(receipt["failed"]))


if __name__ == "__main__":
    raise SystemExit(main())
