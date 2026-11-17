#!/usr/bin/env python3
"""Host checks + full native-launcher SDK typechecks; one compiler at a time."""
from pathlib import Path
import json
import subprocess
import time

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "graphics-profiles/build"
OUT.mkdir(exist_ok=True)
checks = []


def run(name, command):
    result = subprocess.run([str(item) for item in command], capture_output=True, text=True, timeout=300)
    output = result.stdout + result.stderr
    (OUT / (name + ".log")).write_text(output)
    ok = result.returncode == 0 and "error:" not in output
    checks.append({"check": name, "ok": ok, "returncode": result.returncode,
        "warning_count": output.count("warning:"), "command": [str(item) for item in command]})
    print(f"{'PASS' if ok else 'FAIL'} {name}", flush=True)
    if not ok:
        print(output)
        (OUT / "checks.json").write_text(json.dumps(checks, indent=2) + "\n")
        raise SystemExit(1)


run("host-compile", ["xcrun", "swiftc", "-swift-version", "6", "-strict-concurrency=complete", "-parse-as-library", "-j1",
    ROOT / "apple/Sources/Services/GraphicsProfile.swift", ROOT / "graphics-profiles/tests/main.swift", "-o", OUT / "profile-checks"])
run("host", [OUT / "profile-checks"])
run("migration-tool", ["xcrun", "swiftc", "-swift-version", "6", "-strict-concurrency=complete", "-parse-as-library", "-j1",
    ROOT / "apple/Sources/Services/GraphicsProfile.swift", ROOT / "graphics-profiles/tools/adopt-modern-baseline.swift", "-o", OUT / "adopt-modern-baseline"])
sdk_paths = {}
for sdk, target in [("iphoneos", "arm64-apple-ios17.0"), ("xros", "arm64-apple-xros26.5")]:
    sdk_paths[sdk] = subprocess.check_output(["xcrun", "--sdk", sdk, "--show-sdk-path"], text=True).strip()
    run(sdk, ["xcrun", "--sdk", sdk, "swiftc", "-typecheck", "-target", target, "-sdk", sdk_paths[sdk],
        "-swift-version", "6", "-strict-concurrency=complete", "-j1", "-D", "SKYRIM_NATIVE_RUNTIME", "-import-objc-header",
        ROOT / "apple/Sources/Native/SkyrimNativeBridge.h", "-I", ROOT / "apple/Sources/Native", *sorted((ROOT / "apple/Sources").rglob("*.swift"))])
(OUT / "checks.json").write_text(json.dumps({"utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    "scope": "host/SDK only; no device/build/install/game assets", "sdks": sdk_paths, "checks": checks}, indent=2) + "\n")
