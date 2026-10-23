"""Compile the isolated Android arm64 engine and record native test provenance."""
from __future__ import annotations

import argparse
from pathlib import Path
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import engine_identity
import apply


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--checkout", type=Path, required=True)
    parser.add_argument("--flutter-sdk", type=Path, required=True)
    parser.add_argument("--mode", choices=["profile", "release"], default="profile")
    parser.add_argument("--jobs", type=int, default=8)
    parser.add_argument("--adb", default="adb")
    parser.add_argument("--device")
    parser.add_argument("--skip-tests", action="store_true")
    args = parser.parse_args()
    checkout, sdk = args.checkout.resolve(), args.flutter_sdk.resolve()
    engine_identity.validate_sdk(sdk)
    subprocess.run([sys.executable, Path(__file__).with_name("apply.py"), checkout,
                    "--framework-sdk", sdk], check=True)
    source = Path(__file__).resolve().parent
    if not engine_identity.patch_matches(
            apply.git(checkout, "diff", "--binary").stdout,
            (source / "engine.patch").read_text(encoding="utf-8")):
        raise ValueError("Engine checkout contains changes outside the registered patch")
    for name, destination in {
        "frame_presentation_plan.h": "flow/frame_presentation_plan.h",
        "frame_presentation_plan_unittests.cc": "shell/platform/android/frame_presentation_plan_unittests.cc",
    }.items():
        if (source / name).read_bytes() != (checkout / "engine/src/flutter" / destination).read_bytes():
            raise ValueError(f"Engine overlay differs: {name}")
    src = checkout / "engine/src"
    subprocess.run([src / "flutter/tools/gn", "--android", "--android-cpu", "arm64",
                    "--runtime-mode", args.mode, "--no-lto", "--stripped",
                    "--no-build-engine-artifacts"], cwd=src, check=True)
    output = src / "out" / f"android_{args.mode}_arm64"
    targets = ["libflutter.so"]
    if not args.skip_tests:
        targets.append("flutter_shell_native_unittests")
    subprocess.run(["ninja", "-C", output, "-j", str(args.jobs), *targets], cwd=src, check=True)
    if not args.skip_tests:
        adb = [args.adb, *(["-s", args.device] if args.device else [])]
        destination = "/data/local/tmp/piliaurora-frame-plan-tests"
        subprocess.run([*adb, "push", output / "flutter_shell_native_unittests", destination], check=True)
        subprocess.run([*adb, "shell", "chmod", "755", destination], check=True)
        subprocess.run([*adb, "shell", destination, "--gtest_filter=FramePresentationPlanTest.*"], check=True)
    library = output / "lib.stripped/libflutter.so"
    identity = engine_identity.create_identity(library, profile="androidFramePlan",
        mode=args.mode, sdk=sdk, native_tests_passed=not args.skip_tests)
    engine_identity.write_json(library.with_name("engine-identity.json"), identity)
    print(library)


if __name__ == "__main__":
    main()
