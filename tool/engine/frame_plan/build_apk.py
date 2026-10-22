"""Build an isolated arm64 Profile or dev Release APK with the frame-plan engine."""
import argparse
import hashlib
import json
import os
import subprocess
import zipfile
from pathlib import Path

ENGINE_REVISION = "af7e796e161ae0bb1ff0758c71a7105418bd9ded"


def sha256(path):
    with path.open("rb") as handle:
        return hashlib.file_digest(handle, "sha256").hexdigest()


def validate_source_identity(identity, *, target, mode, package, apk_hash,
                             ticker_hash, dart_defines):
    if (identity["target"] != target or identity["mode"] != mode or
            identity["package"] != package or identity["engineRevision"] != ENGINE_REVISION or
            identity["apkSha256"] != apk_hash or identity["tickerSha256"] != ticker_hash or
            identity.get("contentComposition") is not True or
            identity.get("dartDefines") != dart_defines):
        raise ValueError("Source APK identity differs from the requested build configuration")


def restore_workspace_state(backup):
    for path, content in backup.items():
        if content is None:
            path.unlink(missing_ok=True)
        else:
            path.write_bytes(content)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--flutter-sdk", type=Path, required=True)
    parser.add_argument("--engine-library", type=Path, required=True)
    parser.add_argument("--android-sdk", type=Path, required=True)
    parser.add_argument("--mode", choices=("profile", "dev-release"), default="profile")
    parser.add_argument("--target", default="lib/main.dart")
    parser.add_argument("--dart-define", action="append", default=[])
    parser.add_argument("--skip-build", action="store_true")
    parser.add_argument("--source-apk", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if args.skip_build != (args.source_apk is not None):
        parser.error("--skip-build and --source-apk must be used together")
    if any(value.split("=", 1)[0] == "PILIAURORA_CONTENT_COMPOSITION"
           for value in args.dart_define):
        parser.error("PILIAURORA_CONTENT_COMPOSITION is set by this frame-plan builder")
    repo = Path(__file__).resolve().parents[3]
    sdk = args.flutter_sdk.resolve()
    mode = "release" if args.mode == "dev-release" else "profile"
    package = f"io.github.wallpap.piliaurora.{'dev' if mode == 'release' else 'profile'}"
    default_output = ("build/android-test/PiliAurora-dev-arm64-v8a-release.apk"
                      if mode == "release" else
                      "build/android-frame-plan/PiliAurora-frame-plan-arm64-profile.apk")
    output = (repo / (args.output or default_output)).resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    pinned_engine = (sdk / "bin/internal/engine.version").read_text().strip()
    if pinned_engine != ENGINE_REVISION:
        raise ValueError(f"SDK engine mismatch: {pinned_engine}")
    if sdk == (repo / ".fvm/flutter_sdk").resolve():
        raise ValueError("Use an isolated SDK checkout")
    flutter = sdk / "bin/flutter.bat"
    log_path = output.with_suffix(".build.log")
    manifest_path = output.with_suffix(".json")
    env = {**os.environ, "FLUTTER_ROOT": str(sdk),
           "PATH": str(sdk / "bin") + os.pathsep + os.environ["PATH"],
           "JAVA_OPTS": os.environ.get("JAVA_OPTS", "") + " --enable-native-access=ALL-UNNAMED",
           "PILIAURORA_TEST_RELEASE": "true" if mode == "release" else "false",
           "TEMP": str(repo / ".gradle-tmp"), "TMP": str(repo / ".gradle-tmp")}
    (repo / ".gradle-tmp").mkdir(exist_ok=True)
    tracked_state = [repo / "android/local.properties", repo / ".dart_tool/package_config.json"]
    backup = {path: path.read_bytes() if path.exists() else None for path in tracked_state}
    source = (repo / args.source_apk).resolve() if args.source_apk else (
        repo / f"build/app/outputs/flutter-apk/app-{mode}.apk")
    if args.source_apk:
        identity = json.loads(source.with_suffix(".json").read_text(encoding="utf-8"))
        validate_source_identity(
            identity, target=args.target, mode=mode, package=package,
            apk_hash=sha256(source),
            ticker_hash=sha256(repo / "third_party/canvas_danmaku/lib/frame_rate_ticker.dart"),
            dart_defines=args.dart_define)
    library = args.engine_library.resolve()
    if not library.is_file():
        raise FileNotFoundError(library)
    gn_args = library.parent.parent / "args.gn"
    if gn_args.is_file() and f'flutter_runtime_mode = "{mode}"' not in gn_args.read_text():
        raise ValueError(f"Engine runtime mode must be {mode}")
    with log_path.open("a" if args.skip_build else "w", encoding="utf-8") as log:
        def run(command):
            result = subprocess.run([str(arg) for arg in command], cwd=repo,
                                    env=env, stdout=log, stderr=subprocess.STDOUT)
            log.flush()
            if result.returncode:
                raise RuntimeError(f"{Path(command[0]).name} failed ({result.returncode}); see {log_path}")

        try:
            if not args.skip_build:
                run([flutter, "pub", "get", "--offline", "--enforce-lockfile"])
                run(["pwsh", "-NoProfile", "-File", "lib/scripts/patch.ps1", "android", "-SkipPubGet"])
                run([sdk / "bin/cache/dart-sdk/bin/dart.exe", "--packages=.dart_tool/package_config.json",
                     "tool/check_dependencies.dart"])
                run([flutter, "build", "apk", f"--{mode}", "--no-pub", "--target-platform=android-arm64",
                     f"--target={args.target}", "--dart-define=PILIAURORA_CONTENT_COMPOSITION=true",
                     *[f"--dart-define={value}" for value in args.dart_define]])
            engine_hash = sha256(library)
            intermediate = output.with_suffix(".unsigned.apk")
            with zipfile.ZipFile(source) as src, zipfile.ZipFile(intermediate, "w") as dst:
                for entry in src.infolist():
                    name = entry.filename
                    if name.startswith("META-INF/") or name == "lib/arm64-v8a/libflutter.so":
                        continue
                    if name.startswith("lib/") and not name.startswith("lib/arm64-v8a/"):
                        continue
                    if name.endswith(("/libpacing.so", "/wrap.sh")):
                        raise ValueError(f"Unexpected preload probe in input APK: {name}")
                    dst.writestr(entry, src.read(name))
                dst.write(library, "lib/arm64-v8a/libflutter.so", compress_type=zipfile.ZIP_DEFLATED)
            tools = args.android_sdk / "build-tools/37.0.0"
            aligned = output.with_suffix(".aligned.apk")
            run([tools / "zipalign.exe", "-f", "-P", "16", "4", intermediate, aligned])
            if mode == "release":
                run(["java", Path(__file__).with_name("ReleaseApkSigner.java"), repo,
                     tools / "lib/apksigner.jar", aligned, output])
            else:
                run([tools / "apksigner.bat", "sign", "--ks",
                     Path(os.environ["USERPROFILE"]) / ".android/debug.keystore",
                     "--ks-key-alias", "androiddebugkey", "--ks-pass", "pass:android",
                     "--key-pass", "pass:android", "--out", output, aligned])
            run(["java", "--enable-native-access=ALL-UNNAMED", "-jar",
                 tools / "lib/apksigner.jar", "verify", output])
            with zipfile.ZipFile(output) as apk:
                embedded_hash = hashlib.sha256(apk.read("lib/arm64-v8a/libflutter.so")).hexdigest()
                if embedded_hash != engine_hash:
                    raise ValueError("Packaged engine differs from the built library")
            manifest_path.write_text(json.dumps({
                "engineRevision": ENGINE_REVISION,
                "frameworkRevision": subprocess.check_output(
                    ["git", "rev-parse", "HEAD"], cwd=sdk, text=True).strip(),
                "engineLibrarySha256": engine_hash, "apkSha256": sha256(output),
                "target": args.target, "mode": mode, "abi": "arm64-v8a",
                "package": package, "customEngine": True,
                "contentComposition": True,
                "dartDefines": args.dart_define,
                "enginePatchSha256": sha256(Path(__file__).with_name("engine.patch")),
                "plannerSha256": sha256(Path(__file__).with_name("frame_presentation_plan.h")),
                "tickerSha256": sha256(repo / "third_party/canvas_danmaku/lib/frame_rate_ticker.dart"),
            }, indent=2) + "\n", encoding="utf-8")
        finally:
            restore_workspace_state(backup)
    print(output)
    print(manifest_path)


if __name__ == "__main__":
    main()
