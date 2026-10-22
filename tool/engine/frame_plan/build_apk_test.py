"""Check APK reuse and workspace cleanup without invoking build or signing tools."""
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import build_apk


class BuildApkTest(unittest.TestCase):
    def validate(self, **changes):
        identity = {
            "profile": "androidFramePlan", "mode": "profile", "engineCommit": build_apk.ENGINE_REVISION,
            "application": {"target": "lib/main.dart", "package": "test.profile", "apkSha256": "apk",
                "tickerSha256": "ticker", "sourceSha256": "source", "dartDefines": ["PROBE=true"]},
        }
        for key, value in changes.items():
            if key in {"mode", "profile", "engineCommit"}:
                identity[key] = value
            else:
                identity["application"][key] = value
        identity["identityDigest"] = build_apk.engine_identity.identity_digest(identity)
        build_apk.validate_source_identity(
            identity, target="lib/main.dart", mode="profile", package="test.profile",
            apk_hash="apk", ticker_hash="ticker", dart_defines=["PROBE=true"],
            engine_digest=build_apk.engine_identity.identity_digest({
                "profile": "androidFramePlan", "mode": "profile", "engineCommit": build_apk.ENGINE_REVISION}), source_hash="source")

    def test_matching_source_can_be_reused(self):
        self.validate()

    def test_changed_build_configuration_refuses_reuse(self):
        for key, value in {
            "target": "probe.dart", "mode": "release", "package": "other",
            "engineCommit": "other", "apkSha256": "changed",
            "tickerSha256": "changed", "profile": "standard",
            "sourceSha256": "changed",
            "dartDefines": ["PROBE=false"],
        }.items():
            with self.subTest(field=key), self.assertRaises(ValueError):
                self.validate(**{key: value})

    def test_legacy_identity_without_defines_requires_rebuild(self):
        identity = {
            "target": "lib/main.dart", "mode": "profile", "package": "test.profile",
            "engineRevision": build_apk.ENGINE_REVISION, "apkSha256": "apk",
            "tickerSha256": "ticker", "profile": "androidFramePlan",
            "identityDigest": "engine", "sourceSha256": "source",
        }
        with self.assertRaises(ValueError):
            build_apk.validate_source_identity(
                identity, target="lib/main.dart", mode="profile", package="test.profile",
                apk_hash="apk", ticker_hash="ticker", dart_defines=[], engine_digest="engine", source_hash="source")

    def test_restore_reinstates_bytes_and_removes_new_files(self):
        with tempfile.TemporaryDirectory() as directory:
            original = Path(directory) / "existing.json"
            created = Path(directory) / "created.properties"
            absent = Path(directory) / "absent.json"
            original.write_bytes(b"changed")
            created.write_bytes(b"temporary")
            build_apk.restore_workspace_state({
                original: b"original\r\n", created: None, absent: None,
            })
            self.assertEqual(original.read_bytes(), b"original\r\n")
            self.assertFalse(created.exists())
            self.assertFalse(absent.exists())

    def test_composition_override_is_rejected_before_build(self):
        with patch("sys.argv", [
            "build_apk.py", "--flutter-sdk", "unused", "--engine-library", "unused",
            "--android-sdk", "unused",
            "--dart-define=PILIAURORA_CONTENT_COMPOSITION=false",
        ]), patch("sys.stderr"), self.assertRaises(SystemExit) as error:
            build_apk.main()
        self.assertEqual(error.exception.code, 2)


if __name__ == "__main__":
    unittest.main()
